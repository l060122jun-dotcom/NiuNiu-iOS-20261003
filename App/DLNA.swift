import SwiftUI
import Foundation
import Network
import Combine

struct DLNADevice: Identifiable, Hashable {
    let id: String // UPnP UDN, not the friendly name.
    let friendlyName: String
    let location: URL
    let serviceType: String
    let controlURL: URL
}

enum DLNAError: LocalizedError {
    case message(String)
    case http(Int)
    case fault(code: String, description: String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .http(let status): return "设备返回 HTTP \(status)，操作未确认成功。"
        case .fault(let code, let description):
            return "设备拒绝操作（UPnP \(code)）：\(description)"
        }
    }
}

private enum DLNAXML {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name))
    }

    static func parse(_ data: Data, delegate: XMLParserDelegate) throws {
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw DLNAError.message("设备 XML 为空或超出 1 MB 限制。")
        }
        // UPnP requires no DTD. Reject declarations as well as disabling external entities.
        guard let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw DLNAError.message("设备 XML 编码不支持，或包含不允许的实体声明。")
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw DLNAError.message("设备 XML 无法解析：\(parser.parserError?.localizedDescription ?? "格式错误")")
        }
    }

    static func time(_ seconds: Double) -> String {
        let value = Int(min(max(seconds.isFinite ? seconds : 0, 0), 359_999))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }

    static func seconds(_ value: String?) -> Double? {
        guard let value = value else { return nil }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3, parts.allSatisfy({ $0.isFinite && $0 >= 0 }),
              parts[1] < 60, parts[2] < 60 else { return nil }
        let seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        return seconds.isFinite ? seconds : nil
    }

    static func metadata(url: URL, title: String) -> String {
        let mime: String
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": mime = "video/mp4"
        case "m3u8": mime = "application/vnd.apple.mpegurl"
        case "mpd": mime = "application/dash+xml"
        case "ts": mime = "video/mp2t"
        case "mkv": mime = "video/x-matroska"
        case "webm": mime = "video/webm"
        case "mov": mime = "video/quicktime"
        default: mime = "video/*"
        }
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>\(escape(title))</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:\(mime):*">\(escape(url.absoluteString))</res></item></DIDL-Lite>
        """
    }
}

/// Discovery descriptions may refer to nested devices. Match services to their owning device.
private final class DLNADescriptionParser: NSObject, XMLParserDelegate {
    struct Service {
        var type = ""
        var control = ""
    }
    struct Device {
        var name = ""
        var udn = ""
        var services: [Service] = []
    }
    private var stack: [String] = []
    private var text: [String] = []
    private var owners: [Int] = []
    private var service: Service?
    private(set) var devices: [Device] = []
    private(set) var urlBase = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let name = DLNAXML.localName(elementName)
        stack.append(name)
        text.append("")
        if name == "device" {
            devices.append(Device())
            owners.append(devices.count - 1)
        }
        if name == "service" { service = Service() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !text.isEmpty { text[text.count - 1] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = DLNAXML.localName(elementName)
        let value = (text.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.dropLast().last
        if name == "URLBase", parent == "root" { urlBase = value }
        if let owner = owners.last {
            if parent == "device" {
                if name == "friendlyName" { devices[owner].name = value }
                if name == "UDN" { devices[owner].udn = value }
            }
            if parent == "service" {
                if name == "serviceType" { service?.type = value }
                if name == "controlURL" { service?.control = value }
            }
            if name == "service", let service = service { devices[owner].services.append(service) }
        }
        if name == "service" { service = nil }
        if name == "device" { _ = owners.popLast() }
        _ = stack.popLast()
    }
}

private final class DLNASOAPParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var text: [String] = []
    private(set) var values: [String: String] = [:]
    private(set) var fault = false
    private(set) var responses = Set<String>()

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let name = DLNAXML.localName(elementName)
        if name == "Fault" { fault = true }
        if stack.last == "Body" { responses.insert(name) }
        stack.append(name)
        text.append("")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !text.isEmpty { text[text.count - 1] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = (text.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        values[DLNAXML.localName(elementName)] = value
        _ = stack.popLast()
    }
}

/// Only local numeric addresses and .local names are accepted as SSDP device endpoints.
/// Device XML cannot direct SOAP requests to unrelated Internet hosts.
private enum DLNAEndpoint {
    static func isLocalDeviceURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let rawHost = url.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".local") { return true }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { Int($0) }
        if components.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
        }
        return host.hasPrefix("fe80:") || host.hasPrefix("fc") && host.contains(":")
            || host.hasPrefix("fd") && host.contains(":")
    }

    static func sameHost(_ a: URL, _ b: URL) -> Bool {
        a.host?.lowercased() == b.host?.lowercased()
    }
}

private final class DLNAHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // A redirect is not a SOAP success; do not send controls or credentials to another endpoint.
        completionHandler(nil)
    }
}

private actor DLNAClient {
    private let delegate = DLNAHTTPDelegate()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self.delegate, delegateQueue: nil)
    }()

    func describe(_ location: URL) async throws -> [DLNADevice] {
        guard DLNAEndpoint.isLocalDeviceURL(location) else {
            throw DLNAError.message("忽略非局域网设备描述地址。")
        }
        let (data, response) = try await session.data(from: location)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw DLNAError.message("设备没有返回 HTTP 响应。") }
        guard (200...299).contains(response.statusCode) else { throw DLNAError.http(response.statusCode) }
        let parser = DLNADescriptionParser()
        try DLNAXML.parse(data, delegate: parser)
        let base: URL
        if parser.urlBase.isEmpty {
            base = location
        } else {
            guard let proposed = URL(string: parser.urlBase, relativeTo: location)?.absoluteURL,
                  DLNAEndpoint.isLocalDeviceURL(proposed), DLNAEndpoint.sameHost(proposed, location) else {
                throw DLNAError.message("设备 URLBase 指向其他主机，已拒绝。")
            }
            base = proposed
        }
        return parser.devices.compactMap { device in
            guard !device.udn.isEmpty,
                  let service = device.services.first(where: {
                      let parts = $0.type.split(separator: ":", omittingEmptySubsequences: false)
                      return $0.type.hasPrefix("urn:schemas-upnp-org:service:AVTransport:")
                          && parts.count == 5 && (Int(parts.last ?? "") ?? 0) > 0
                  }), !service.control.isEmpty,
                  let control = URL(string: service.control, relativeTo: base)?.absoluteURL,
                  DLNAEndpoint.isLocalDeviceURL(control), DLNAEndpoint.sameHost(control, location) else { return nil }
            return DLNADevice(id: device.udn, friendlyName: device.name.isEmpty ? "未命名 DLNA 设备" : device.name,
                              location: location, serviceType: service.type, controlURL: control)
        }
    }

    func action(_ action: String, device: DLNADevice,
                arguments: [(String, String)] = []) async throws -> [String: String] {
        guard DLNAEndpoint.isLocalDeviceURL(device.controlURL),
              DLNAEndpoint.sameHost(device.controlURL, device.location) else {
            throw DLNAError.message("控制地址不是已发现的局域网设备。")
        }
        let fields = ([("InstanceID", "0")] + arguments).map {
            "<\($0.0)>\(DLNAXML.escape($0.1))</\($0.0)>"
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(DLNAXML.escape(device.serviceType))">\(fields)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: device.controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(device.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(xml.utf8)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw DLNAError.message("设备没有返回 HTTP 响应。") }
        let parser = DLNASOAPParser()
        do {
            try DLNAXML.parse(data, delegate: parser)
        } catch {
            if !(200...299).contains(response.statusCode) { throw DLNAError.http(response.statusCode) }
            throw error
        }
        // Many renderers return SOAP Fault with HTTP 500; some incorrectly return HTTP 200.
        if parser.fault {
            throw DLNAError.fault(code: parser.values["errorCode"] ?? parser.values["faultcode"] ?? "未知",
                                  description: parser.values["errorDescription"] ?? parser.values["faultstring"] ?? "无错误说明")
        }
        guard (200...299).contains(response.statusCode) else { throw DLNAError.http(response.statusCode) }
        guard parser.responses.contains(action + "Response") else {
            throw DLNAError.message("设备未返回 \(action)Response，不能确认操作成功。")
        }
        return parser.values
    }
}

/// Network work runs on one queue. No sockets are opened before the user calls search().
/// The listener shares the outgoing UDP port so unicast SSDP replies can be accepted.
private final class DLNADiscovery {
    private let queue = DispatchQueue(label: "app.niuniu.dlna.ssdp")
    private var listener: NWListener?
    private var sender: NWConnection?
    private var incoming: [NWConnection] = []
    private var deadline: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var running = false
    private let onLocation: (URL) -> Void
    private let onFinish: (String?) -> Void

    init(onLocation: @escaping (URL) -> Void, onFinish: @escaping (String?) -> Void) {
        self.onLocation = onLocation
        self.onFinish = onFinish
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            do {
                let parameters = NWParameters.udp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredInterfaceType = .wifi
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self = self, self.running, self.incoming.count < 64 else { connection.cancel(); return }
                    self.incoming.append(connection)
                    connection.start(queue: self.queue)
                    self.receive(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self = self, self.running else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener?.port, self.sender == nil { self.openSender(port: port) }
                    case .failed(let error): self.finish("SSDP 无法启动：\(error.localizedDescription)")
                    default: break
                    }
                }
                listener.start(queue: queue)
                let deadline = DispatchWorkItem { [weak self] in self?.finish(nil) }
                self.deadline = deadline
                queue.asyncAfter(deadline: .now() + 10, execute: deadline)
            } catch { finish("SSDP 无法启动：\(error.localizedDescription)") }
        }
    }

    // Keep this instance alive until cancellation executes, even if Store releases it immediately.
    func stop() { queue.async { [self] in cancel() } }

    private func openSender(port: NWEndpoint.Port) {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .wifi
        parameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: port)
        let connection = NWConnection(host: "239.255.255.250", port: 1900, using: parameters)
        sender = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection, self.running else { return }
            switch state {
            case .ready:
                self.send(connection)
                self.receive(connection)
                let retry = DispatchWorkItem { [weak self, weak connection] in
                    guard let self = self, let connection = connection, self.running else { return }
                    self.send(connection)
                }
                self.retry = retry
                self.queue.asyncAfter(deadline: .now() + 1.5, execute: retry)
            case .failed(let error): self.finish("SSDP 组播发送失败：\(error.localizedDescription)")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func send(_ connection: NWConnection) {
        for target in ["urn:schemas-upnp-org:device:MediaRenderer:1", "urn:schemas-upnp-org:service:AVTransport:1"] {
            let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
            connection.send(content: Data(message.utf8), completion: .contentProcessed { [weak self] error in
                if let error = error, let self = self, self.running {
                    self.finish("SSDP 发送失败：\(error.localizedDescription)")
                }
            })
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self = self, let connection = connection, self.running else { return }
            if let data = data, data.count <= 65_536, let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: "\r\n")
                if let status = lines.first, status.uppercased().hasPrefix("HTTP/1.1 200") {
                    for line in lines.dropFirst() {
                        if line.isEmpty { break }
                        guard let colon = line.firstIndex(of: ":"),
                              line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
                        let address = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                        if let location = URL(string: address), DLNAEndpoint.isLocalDeviceURL(location) { self.onLocation(location) }
                        break
                    }
                }
            }
            if error == nil { self.receive(connection) }
            else { connection.cancel() }
        }
    }

    private func finish(_ error: String?) {
        guard running else { return }
        cancel()
        onFinish(error)
    }

    private func cancel() {
        running = false
        deadline?.cancel()
        retry?.cancel()
        deadline = nil
        retry = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        sender?.stateUpdateHandler = nil
        sender?.cancel()
        incoming.forEach { $0.cancel() }
        listener = nil
        sender = nil
        incoming = []
    }
}

@MainActor
final class DLNAStore: ObservableObject {
    static let shared = DLNAStore()
    @Published private(set) var devices: [DLNADevice] = []
    @Published private(set) var searching = false
    @Published private(set) var selectedDevice: DLNADevice?
    @Published var error: String?
    @Published private(set) var busy = false
    @Published private(set) var isCasting = false
    @Published private(set) var transportState = "UNKNOWN"
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var mediaTitle = ""
    @Published private(set) var activeMediaURL: URL?
    @Published private(set) var mediaAccessRevoked = false
    private let client = DLNAClient()
    private var discovery: DLNADiscovery?
    private var searchID = UUID()
    private var seenLocations = Set<URL>()
    private var descriptions: [URL: Task<Void, Never>] = [:]
    private var mediaProxy: DLNAMediaProxy?
    private var castID = UUID()

    private init() {}

    /// Explicit user action only. Do not invoke from application launch or onAppear.
    func search() {
        stopSearch()
        error = nil
        searching = true
        devices = selectedDevice.map { [$0] } ?? []
        let token = searchID
        let discovery = DLNADiscovery(onLocation: { [weak self] location in
            Task { @MainActor in self?.found(location, token: token) }
        }, onFinish: { [weak self] message in
            Task { @MainActor in
                guard let self = self, self.searchID == token else { return }
                self.searching = false
                self.discovery = nil
                if let message = message { self.error = message }
                else if self.devices.isEmpty {
                    self.error = "未发现可控制的 DLNA 设备。请检查同一 Wi-Fi、局域网权限与电视的 DLNA 开关，再点重试。"
                }
                // Description requests already in flight can finish; they are bounded by HTTP timeouts.
            }
        })
        self.discovery = discovery
        discovery.start()
    }

    func stopSearch() {
        searchID = UUID()
        discovery?.stop()
        discovery = nil
        descriptions.values.forEach { $0.cancel() }
        descriptions = [:]
        seenLocations = []
        searching = false
    }

    private func found(_ location: URL, token: UUID) {
        guard token == searchID, searching, seenLocations.count < 48,
              seenLocations.insert(location).inserted else { return }
        descriptions[location] = Task { [weak self] in
            guard let self = self else { return }
            defer { if self.searchID == token { self.descriptions[location] = nil } }
            do {
                let results = try await self.client.describe(location)
                guard !Task.isCancelled, self.searchID == token else { return }
                for device in results {
                    if let index = self.devices.firstIndex(where: { $0.id == device.id }) { self.devices[index] = device }
                    else { self.devices.append(device) }
                }
                self.devices.sort { $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending }
                if !results.isEmpty { self.error = nil }
            } catch is CancellationError {
            } catch {
                guard self.searchID == token, !Task.isCancelled else { return }
                self.error = "设备描述获取失败：\(error.localizedDescription)"
            }
        }
    }

    func select(_ device: DLNADevice) {
        guard !busy else { error = "请等待当前设备操作完成。"; return }
        guard !isCasting || selectedDevice?.id == device.id else {
            error = "请先成功停止当前投屏，再选择其他设备。"
            return
        }
        selectedDevice = device
        error = nil
    }

    /// Each explicit cast gets its own LAN capability and upstream request-header scope.
    func cast(url: URL, title: String, headers: [String: String] = [:]) async throws {
        try begin()
        defer { busy = false }
        var candidate: DLNAMediaProxy?
        var accepted = false
        do {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                   let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                throw DLNAError.message("DLNA 仅支持不含内嵌用户名密码的 HTTP(S) 媒体地址；本地文件不可用。")
            }
            let device = try requireDevice()
            // Revocation is immediate on replacement, even if the new SOAP operation fails.
            if mediaProxy != nil || isCasting {
                mediaAccessRevoked = true
                activeMediaURL = nil
                // Keep isCasting so status polling can query the actual remote state.
                transportState = "UNKNOWN"
            }
            mediaProxy?.stop()
            mediaProxy = nil
            castID = UUID()
            let token = castID
            let proxy = try DLNAMediaProxy(url: url, headers: headers) { [weak self] message in
                Task { @MainActor in
                    guard let self = self, self.castID == token else { return }
                    self.error = message
                }
            }
            candidate = proxy
            let rendererURL = try await proxy.start()
            try Task.checkCancellation()
            _ = try await client.action("SetAVTransportURI", device: device,
                                         arguments: [("CurrentURI", rendererURL.absoluteString),
                                                     ("CurrentURIMetaData", DLNAXML.metadata(url: rendererURL, title: title))])
            mediaProxy = proxy
            accepted = true
            // URI acceptance is not playback success. If Play fails, retain controls for the loaded URI.
            isCasting = true
            mediaAccessRevoked = false
            transportState = "URI_SET"
            activeMediaURL = url
            mediaTitle = title
            position = 0
            duration = 0
            _ = try await client.action("Play", device: device, arguments: [("Speed", "1")])
            transportState = "PLAYING"
        } catch {
            if !accepted { candidate?.stop() }
            if Task.isCancelled {
                mediaProxy?.stop()
                mediaProxy = nil
                castID = UUID()
                if isCasting {
                    mediaAccessRevoked = true
                    activeMediaURL = nil
                    transportState = "UNKNOWN"
                }
                self.error = "投屏操作已取消，媒体代理已关闭；设备是否已接收命令需重新查询。"
            } else {
                self.error = mediaAccessRevoked
                    ? "媒体访问已撤销，远端状态需重新查询。\(error.localizedDescription)"
                    : error.localizedDescription
            }
            throw error
        }
    }

    func play() async throws { try await control("Play", arguments: [("Speed", "1")], state: "PLAYING") }
    func pause() async throws { try await control("Pause", state: "PAUSED_PLAYBACK") }
    func stop() async throws {
        // Always revoke media access, including a failed/cancelled remote Stop.
        // The renderer state is only marked stopped after SOAP confirms success.
        guard !busy else { throw DLNAError.message("设备操作进行中，请稍后重试。") }
        mediaProxy?.stop()
        mediaProxy = nil
        castID = UUID()
        mediaAccessRevoked = true
        activeMediaURL = nil
        transportState = "UNKNOWN"
        try await control("Stop", state: "STOPPED")
        isCasting = false
        mediaAccessRevoked = false
        activeMediaURL = nil
        position = 0
        duration = 0
    }

    func seek(to seconds: Double) async throws {
        try begin()
        defer { busy = false }
        do {
            guard seconds.isFinite, seconds >= 0, seconds <= 359_999 else {
                throw DLNAError.message("跳转时间必须在 0 至 99:59:59 之间。")
            }
            let device = try requireDevice()
            let target = duration > 0 ? min(seconds, duration) : seconds
            _ = try await client.action("Seek", device: device,
                                        arguments: [("Unit", "REL_TIME"), ("Target", DLNAXML.time(target))])
            position = target
        } catch { self.error = error.localizedDescription; throw error }
    }

    /// Poll only while the user is viewing an active casting session; no device discovery here.
    func refreshStatus() async {
        guard isCasting, !busy, let device = selectedDevice else { return }
        busy = true
        defer { busy = false }
        do {
            let transport = try await client.action("GetTransportInfo", device: device)
            if let state = transport["CurrentTransportState"], !state.isEmpty { transportState = state }
            else { throw DLNAError.message("GetTransportInfo 缺少设备播放状态。") }
            if let status = transport["CurrentTransportStatus"], status != "OK" {
                throw DLNAError.message("设备播放异常：\(status)")
            }
            let info = try await client.action("GetPositionInfo", device: device)
            duration = DLNAXML.seconds(info["TrackDuration"]) ?? 0
            position = DLNAXML.seconds(info["RelTime"]) ?? 0
        } catch is CancellationError {
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func begin() throws {
        guard !busy else { throw DLNAError.message("设备操作进行中，请稍后重试。") }
        busy = true
        error = nil
    }

    private func requireDevice() throws -> DLNADevice {
        guard let device = selectedDevice else { throw DLNAError.message("请先选择 DLNA 设备。") }
        return device
    }

    private func control(_ action: String, arguments: [(String, String)] = [], state: String) async throws {
        try begin()
        defer { busy = false }
        do {
            let device = try requireDevice()
            _ = try await client.action(action, device: device, arguments: arguments)
            transportState = state
        } catch { self.error = error.localizedDescription; throw error }
    }
}

@MainActor
struct DLNADeviceView: View {
    let mediaURL: URL
    let title: String
    let headers: [String: String]
    @ObservedObject private var store = DLNAStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingHelp = false
    @State private var choosingDevice = false
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var exiting = false
    @State private var uiBusy = false

    init(mediaURL: URL, title: String, headers: [String: String] = [:]) {
        self.mediaURL = mediaURL
        self.title = title
        self.headers = headers
    }

    var body: some View {
        List {
            if let error = store.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityLabel("投屏错误：\(error)")
                }
            }
            if !headers.isEmpty {
                Section {
                    Text("本次投屏通过手机 Wi-Fi 媒体代理转发。自定义请求头仅用于原始媒体源，不发送给电视或跨源引用。请保持 App 前台运行。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if store.isCasting && !choosingDevice { controlSection }
            else { deviceSection }
            Section {
                Button { showingHelp = true } label: { Label("投屏帮助与限制", systemImage: "questionmark.circle") }
                Text("真实 DLNA / UPnP，不使用 AirPlay。只有点击搜索/刷新才发送发现请求。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(store.isCasting && !choosingDevice ? "投屏控制" : "选择投屏设备")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("返回") { store.stopSearch(); dismiss() }
                    .disabled(uiBusy)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(store.searching ? "停止搜索" : "刷新") {
                    if store.searching { store.stopSearch() }
                    else { store.search() }
                }.disabled(uiBusy)
            }
        }
        .sheet(isPresented: $showingHelp) { helpView }
        .confirmationDialog("退出投屏会向当前设备发送 Stop。只有设备确认成功后才退出。", isPresented: $exiting, titleVisibility: .visible) {
            Button("停止并退出投屏", role: .destructive) {
                perform { try await store.stop(); store.stopSearch(); dismiss() }
            }
            Button("取消", role: .cancel) {}
        }
        .task {
            // Returning to the page may observe an existing session, but never starts a search.
            while !Task.isCancelled {
                if store.isCasting && !uiBusy && !scrubbing { await store.refreshStatus() }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
            }
        }
        .onDisappear { store.stopSearch() } // Back does not implicitly stop remote playback.
    }

    private var deviceSection: some View {
        Section {
            if store.searching { HStack { ProgressView(); Text("正在发现 DLNA 设备…") } }
            if store.devices.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("暂无可用设备", systemImage: "tv")
                    Text("让手机与电视连接同一 Wi-Fi，并开启电视的 DLNA/媒体渲染功能。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(store.searching ? "搜索中" : "搜索 / 重试") { store.search() }
                        .disabled(store.searching || uiBusy)
                }.padding(.vertical, 8)
            }
            ForEach(store.devices) { device in
                Button {
                    perform {
                        if store.isCasting && store.selectedDevice?.id != device.id { try await store.stop() }
                        store.select(device)
                        guard store.selectedDevice?.id == device.id else {
                            throw DLNAError.message("设备选择失败，请重试。")
                        }
                        try await store.cast(url: mediaURL, title: title, headers: headers)
                        store.stopSearch()
                        choosingDevice = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "tv")
                        VStack(alignment: .leading) {
                            Text(device.friendlyName)
                            Text(device.controlURL.host ?? "局域网设备")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.selectedDevice?.id == device.id { Image(systemName: "checkmark.circle.fill") }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.disabled(uiBusy)
            }
            if choosingDevice && store.isCasting {
                Button("返回当前投屏控制") { choosingDevice = false }
            }
        } header: { Text("点击设备开始投屏") }
        footer: { Text("换设备先停止原设备，停止失败时不会向新设备投屏。电视通过同一 Wi-Fi 访问手机媒体代理，必须支持该格式；请保持 App 前台运行。") }
    }

    private var controlSection: some View {
        Section {
            Label(store.selectedDevice?.friendlyName ?? "DLNA 设备", systemImage: "tv.fill")
            Text(store.mediaTitle).font(.headline)
            Text(stateLabel).font(.subheadline).foregroundStyle(.secondary)
            Slider(value: Binding(get: { scrubbing ? scrubPosition : min(store.position, max(store.duration, 1)) },
                                  set: { scrubPosition = $0 }),
                   in: 0...max(store.duration, 1), onEditingChanged: { editing in
                if editing { scrubPosition = min(store.position, store.duration); scrubbing = true }
                else {
                    let target = scrubPosition
                    perform { try await store.seek(to: target) }
                    scrubbing = false
                }
            })
            .frame(minHeight: 44)
            .disabled(store.duration <= 0 || uiBusy)
            .accessibilityLabel("投屏播放进度")
            HStack {
                Text(DLNAXML.time(scrubbing ? scrubPosition : store.position))
                Spacer()
                Text(store.duration > 0 ? DLNAXML.time(store.duration) : "时长未知 / 直播")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button {
                    perform {
                        if store.transportState == "PLAYING" { try await store.pause() }
                        else { try await store.play() }
                    }
                } label: {
                    Label(store.transportState == "PLAYING" ? "暂停" : "播放",
                          systemImage: store.transportState == "PLAYING" ? "pause.fill" : "play.fill")
                }
                Button("停止") { perform { try await store.stop() } }
                if uiBusy || store.busy { ProgressView() }
            }.disabled(uiBusy).buttonStyle(.bordered)
            Button("换设备") { choosingDevice = true }
                .disabled(uiBusy)
            Button("退出投屏", role: .destructive) { exiting = true }
                .disabled(uiBusy)
        } header: { Text("投屏控制") }
        footer: { Text("返回只关闭此页面，电视可继续播放；退出投屏会发送 Stop。暂停、跳转及媒体格式支持由电视决定。") }
    }

    private var stateLabel: String {
        if store.mediaAccessRevoked {
            return store.transportState == "UNKNOWN"
                ? "媒体访问已撤销；远端状态未知，等待查询"
                : "媒体访问已撤销；远端查询状态：\(store.transportState)"
        }
        switch store.transportState {
        case "PLAYING": return "设备已接受播放命令"
        case "PAUSED_PLAYBACK": return "已暂停"
        case "STOPPED": return "已停止"
        case "TRANSITIONING": return "设备正在加载"
        case "URI_SET": return "媒体地址已设置，尚未确认播放成功"
        case "NO_MEDIA_PRESENT": return "设备没有可播放媒体"
        default: return "设备状态：\(store.transportState)"
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !uiBusy else { return }
        uiBusy = true
        Task { @MainActor in
            defer { uiBusy = false }
            // A status poll may be finishing when the user taps. Wait rather than discard the tap.
            while store.busy {
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
            }
            do { try await operation() }
            catch is CancellationError {}
            catch { store.error = error.localizedDescription }
        }
    }

    private var helpView: some View {
        NavigationStack {
            List {
                Section("发现设备") {
                    Text("手机与电视须处于同一 Wi-Fi。关闭 AP/客户端隔离；部分访客网络、VPN 或路由器会屏蔽 SSDP 组播。开启电视的 DLNA/UPnP MediaRenderer 功能，然后点搜索。")
                    Text("iOS 设置中允许此 App 访问本地网络。实际签名还需要 Apple 批准的 multicast entitlement；缺少权限可能完全发现不到设备。")
                }
                Section("媒体限制") {
                    Text("仅显式开始投屏时建立 Wi-Fi HTTP 媒体代理。电视只取得本次随机能力地址；Cookie、Referer、Authorization 等请求头仅用于原始媒体源，不转给电视或跨源资源。停止或换视频会关闭旧代理和上游任务。")
                    Text("支持 HLS 主清单、子清单、分片、KEY、MAP 的引用重写；普通 AES-128 密钥按原有授权读取，不解密或绕过 DRM / SAMPLE-AES。跨源重定向被拒绝。本地 HTTP 回环媒体服务可由手机转发；本地文件、DASH 引用重写、验证码和转码不支持。某些电视不支持 HLS、直播、编解码器或 Seek。")
                    Text("需可用 Wi-Fi IPv4 和局域网权限。手机必须保持同一 Wi-Fi、App 前台运行；iOS 后台挂起、AP 隔离或电视格式限制可能中断播放。能力 URL 在本次投屏期间相当于媒体访问凭证，请勿分享。")
                }
                Section("控制与隐私") {
                    Text("搜索仅由点击触发，约 10 秒后关闭 UDP；返回时取消搜索。没有后台扫描、广告 SDK 或 AirPlay 替代逻辑。")
                    Text("返回不停止电视或代理；停止/退出会先撤销媒体代理再发送 Stop。Stop 失败仍显示真实错误，不会假称电视已停止；继续播放需重新投屏。")
                }
            }
            .navigationTitle("DLNA 投屏帮助")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { showingHelp = false } } }
        }
    }
}
