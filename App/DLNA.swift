import Foundation
import Network
import Darwin
import SwiftUI

// DLNA/UPnP (SSDP + SOAP AVTransport) implemented for the iOS port.
// AirPlay is explicitly NOT used as a substitute: the Android original casts via
// DLNA, so this module performs real SSDP discovery and real AVTransport control.

struct DLNADevice: Identifiable, Hashable {
    var id: String
    var name: String
    var location: URL
    var controlURL: URL
}

struct DLNAStatus: Equatable {
    var state: String = ""
    var positionSeconds: Double = 0
    var durationSeconds: Double = 0
}

@MainActor
final class DLNAStore: ObservableObject {
    static let shared = DLNAStore()

    @Published private(set) var devices: [DLNADevice] = []
    @Published private(set) var searching = false
    @Published private(set) var selected: DLNADevice?
    @Published private(set) var casting = false
    @Published private(set) var status = DLNAStatus()
    @Published var error: String?

    private var searchQueue: DispatchQueue?
    private var positionTimer: Timer?
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    // MARK: Discovery

    func search() {
        guard !searching else { return }
        error = nil
        devices = []
        searching = true
        let queue = DispatchQueue(label: "dlna.ssdp")
        searchQueue = queue
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.performSSDP()
            Task { @MainActor in
                self.searching = false
                self.devices = found
                if found.isEmpty {
                    self.error = "未发现可用设备。请确认电视与本机连接同一 Wi-Fi，并已开启 DLNA/投屏。"
                }
            }
        }
    }

    func stopSearch() {
        searching = false
    }

    /// Sends an SSDP M-SEARCH multicast probe and collects unicast replies.
    private nonisolated func performSSDP() -> [DLNADevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { return [] }

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let message = "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 3\r\n" +
            "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &target.sin_addr)
        let payload = Array(message.utf8)
        _ = payload.withUnsafeBytes { buffer in
            withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var locations = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let read = recv(fd, &buffer, buffer.count, 0)
            guard read > 0, let text = String(bytes: buffer[0..<read], encoding: .utf8) else { continue }
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    locations.insert(value)
                }
            }
        }

        var results: [DLNADevice] = []
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var pending = locations.count
        if pending == 0 { return [] }
        for value in locations {
            guard let url = URL(string: value) else { pending -= 1; continue }
            fetchDescription(url) { device in
                lock.lock()
                if let device { results.append(device) }
                pending -= 1
                if pending == 0 { semaphore.signal() }
                lock.unlock()
            }
        }
        _ = semaphore.wait(timeout: .now() + 8)
        return results.sorted { $0.name < $1.name }
    }

    private nonisolated func fetchDescription(_ location: URL, completion: @escaping (DLNADevice?) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        URLSession(configuration: configuration).dataTask(with: location) { data, _, _ in
            guard let data else { completion(nil); return }
            let parser = DLNADescriptionParser(base: location)
            completion(parser.parse(data))
        }.resume()
    }

    func select(_ device: DLNADevice) {
        selected = device
        error = nil
    }

    // MARK: Casting

    func play(url: URL, title: String, headers: [String: String] = [:]) async throws {
        guard let device = selected else { throw DLNAError.noDevice }
        if !headers.isEmpty {
            // U+2011 note: a signed URL / matching Referer is required by many CDNs.
            // We surface this rather than silently sending an unauthenticated request.
            error = "该媒体需要请求头校验，DLNA 设备可能无法直接播放；若失败请改用可公开访问的线路。"
        }
        let metadata = didl(title: title, url: url.absoluteString)
        try await soap(device, action: "SetAVTransportURI",
                        body: "<InstanceID>0</InstanceID><CurrentURI>\(escape(url.absoluteString))</CurrentURI><CurrentURIMetaData>\(escape(metadata))</CurrentURIMetaData>")
        try await soap(device, action: "Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
        casting = true
        startPositionTimer()
    }

    func pause() async throws {
        guard let device = selected else { throw DLNAError.noDevice }
        try await soap(device, action: "Pause", body: "<InstanceID>0</InstanceID>")
    }

    func resume() async throws {
        guard let device = selected else { throw DLNAError.noDevice }
        try await soap(device, action: "Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    func stop() async throws {
        guard let device = selected else { throw DLNAError.noDevice }
        try await soap(device, action: "Stop", body: "<InstanceID>0</InstanceID>")
        casting = false
        positionTimer?.invalidate()
    }

    func seek(seconds: Double) async throws {
        guard let device = selected else { throw DLNAError.noDevice }
        let stamp = String(format: "%02d:%02d:%02d", Int(seconds) / 3600, (Int(seconds) % 3600) / 60, Int(seconds) % 60)
        try await soap(device, action: "Seek",
                        body: "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(stamp)</Target>")
    }

    func clearSelection() {
        selected = nil
        casting = false
        status = DLNAStatus()
        positionTimer?.invalidate()
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshStatus() }
        }
    }

    private func refreshStatus() async {
        guard let device = selected else { return }
        do {
            let info = try await soap(device, action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>", returnsValue: true)
            status.positionSeconds = Self.parseTime(Self.tag(info, "RelTime"))
            status.durationSeconds = Self.parseTime(Self.tag(info, "TrackDuration"))
            let transport = try await soap(device, action: "GetTransportInfo", body: "<InstanceID>0</InstanceID>", returnsValue: true)
            status.state = Self.tag(transport, "CurrentTransportState")
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: SOAP

    @discardableResult
    private func soap(_ device: DLNADevice, action: String, body: String, returnsValue: Bool = false) async throws -> String {
        var request = URLRequest(url: device.controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPAction")
        let envelope = "<?xml version=\"1.0\"?>" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
            "<s:Body><u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(body)</u:\(action)></s:Body></s:Envelope>"
        request.httpBody = Data(envelope.utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DLNAError.badResponse }
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(http.statusCode), !text.contains("UPnPError") else {
            throw DLNAError.soap(Self.tag(text, "errorDescription").isEmpty ? "设备拒绝该操作（HTTP \(http.statusCode)）" : Self.tag(text, "errorDescription"))
        }
        return returnsValue ? text : ""
    }

    private nonisolated static func tag(_ xml: String, _ name: String) -> String {
        guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { return "" }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private nonisolated static func parseTime(_ value: String) -> Double {
        let parts = value.split(separator: ":").map { Double($0) ?? 0 }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private nonisolated func didl(title: String, url: String) -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">" +
            "<item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>\(escape(title))</dc:title>" +
            "<upnp:class>object.item.videoItem</upnp:class>" +
            "<res protocolInfo=\"http-get:*:video/*:*\">\(escape(url))</res></item></DIDL-Lite>"
    }

    private nonisolated func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum DLNAError: LocalizedError {
    case noDevice, badResponse, soap(String)
    var errorDescription: String? {
        switch self {
        case .noDevice: return "请先选择一台投屏设备"
        case .badResponse: return "投屏设备返回了无效响应"
        case .soap(let message): return message
        }
    }
}

private final class DLNADescriptionParser: NSObject, XMLParserDelegate {
    private let base: URL
    private var friendly = ""
    private var udn = ""
    private var serviceType = ""
    private var controlURLText = ""
    private var currentElement = ""
    private var buffer = ""
    private var inService = false
    private var sawAVTransport = false

    init(base: URL) { self.base = base }

    func parse(_ data: Data) -> DLNADevice? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        guard !friendly.isEmpty else { return nil }
        let control = sawAVTransport && !controlURLText.isEmpty ? controlURLText : ""
        let url = URL(string: control, relativeTo: base)?.absoluteURL ?? base
        return DLNADevice(id: udn.isEmpty ? friendly : udn, name: friendly, location: base, controlURL: url)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        buffer = ""
        if elementName == "service" { inService = true; serviceType = ""; controlURLText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "friendlyName": if friendly.isEmpty { friendly = value }
        case "UDN": if udn.isEmpty { udn = value }
        case "serviceType": serviceType = value
        case "controlURL": controlURLText = value
        case "service":
            if serviceType.contains("AVTransport"), !controlURLText.isEmpty { sawAVTransport = true }
            inService = false
        default: break
        }
        buffer = ""
        currentElement = ""
    }
}

struct DLNADeviceView: View {
    let mediaURL: URL
    let title: String
    let headers: [String: String]
    @ObservedObject private var store = DLNAStore.shared
    @State private var castingError: String?

    var body: some View {
        List {
            if let error = store.error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("重新搜索") { store.search() }
                }
            }
            Section("可用设备") {
                if store.devices.isEmpty {
                    Text(store.searching ? "正在搜索同一局域网设备…" : "尚未发现设备")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.devices) { device in
                    Button {
                        store.select(device)
                        Task { await cast() }
                    } label: {
                        HStack {
                            Image(systemName: "tv")
                            Text(device.name)
                            Spacer()
                            if store.selected?.id == device.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            if store.casting {
                Section("投屏控制") {
                    HStack {
                        Text(store.status.state.isEmpty ? "已连接" : store.status.state)
                        Spacer()
                        Text(timeText(store.status.positionSeconds))
                    }
                    HStack {
                        Button("暂停") { Task { try? await store.pause() } }
                        Button("继续") { Task { try? await store.resume() } }
                        Button("停止", role: .destructive) { Task { try? await store.stop() } }
                    }
                    Slider(value: Binding(
                        get: { store.status.positionSeconds },
                        set: { value in Task { try? await store.seek(seconds: value) } }
                    ), in: 0...max(1, store.status.durationSeconds))
                    Button("更换设备") { store.clearSelection(); store.search() }
                }
            }
            if let castingError { Text(castingError).foregroundStyle(.red) }
            Section("说明") {
                Text("需与电视处于同一 Wi-Fi，且电视支持 DLNA/UPnP 投屏。部分需要请求头校验的媒体可能无法直接投屏。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("投屏")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { store.search() } } }
        .onAppear { if store.devices.isEmpty { store.search() } }
        .onDisappear { store.stopSearch() }
    }

    private func cast() async {
        do { try await store.play(url: mediaURL, title: title, headers: headers); castingError = nil }
        catch { castingError = error.localizedDescription }
    }

    private func timeText(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
