import Foundation
import Security
import Network

enum SpecialSourceError: LocalizedError {
    case configuration(String), response(String), verification, advertisingGate, authorization
    case mediaScope, unsupportedMedia(String), proxy(String), keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .configuration(let message): return "特殊源配置无效：\(message)"
        case .response(let message): return "特殊源服务器拒绝请求：\(message)"
        case .verification: return "该特殊源要求真实验证码/风控验证，请使用源站官方验证流程；不会绕过验证"
        case .advertisingGate: return "该特殊源需要真实广告授权，当前不会发送广告请求或伪造广告完成"
        case .authorization: return "河马源缺少已授权 token；原协议初始化使用广告入口，当前不会自动调用"
        case .mediaScope: return "媒体地址超出当前源域名或媒体目录，已拒绝代理"
        case .unsupportedMedia(let message): return "该媒体无法安全播放：\(message)"
        case .proxy(let message): return "本地媒体代理失败：\(message)"
        case .keychain(let status): return "特殊源凭据存储失败（\(status)）"
        }
    }
}

/// Called only after APIClient's content approval and an explicit user play action.
enum SpecialResolvePurpose: Equatable { case playback, download }

@MainActor
final class SpecialSourceResolver {
    static let shared = SpecialSourceResolver()
    private var activeProxy: SpecialHLSProxy?
    private var initialization: [String: (id: UUID, task: Task<String, Error>)] = [:]
    private var contextGeneration: UInt64 = 0
    private var playbackGeneration: UInt64 = 0
    private var namespaceGenerations: [String: UInt64] = [:]
    private var downloadProxies: [URL: SpecialHLSProxy] = [:]
    private var pendingDownloads = 0
    private let maximumDownloads = 4
    private var hemaClock: [String: Int64] = [:]
    private let transport = SpecialTransport()

    private func check(_ context: UInt64, namespace: String, generation: UInt64) throws {
        try Task.checkCancellation()
        guard context == contextGeneration, generation == namespaceGenerations[namespace, default: 0] else { throw CancellationError() }
    }

    /// Account/mode/domain changes retire all credentials-in-flight and owned media sessions.
    func invalidateContext() {
        contextGeneration &+= 1
        playbackGeneration &+= 1
        initialization.values.forEach { $0.task.cancel() }
        initialization.removeAll()
        hemaClock.removeAll()
        activeProxy?.stop(); activeProxy = nil
        downloadProxies.values.forEach { $0.stop() }; downloadProxies.removeAll()
    }

    func cacheStatus(source: String, config: [String: Any]) throws -> String {
        let settings = try SpecialSettings(source: source, config: config)
        let credentials = SpecialCredentials(namespace: settings.namespace)
        let hasToken = !(try credentials.get("token") ?? "").isEmpty
        return hasToken ? "已缓存授权" : "未缓存"
    }

    func clearCache(source: String, config: [String: Any]) throws {
        let settings = try SpecialSettings(source: source, config: config)
        namespaceGenerations[settings.namespace, default: 0] &+= 1
        initialization[settings.namespace]?.task.cancel()
        initialization.removeValue(forKey: settings.namespace)
        hemaClock.removeValue(forKey: settings.namespace)
        let credentials = SpecialCredentials(namespace: settings.namespace)
        try credentials.remove("token")
        try credentials.remove("device")
    }

    func resolve(episode: Episode, source: String, config: [String: Any], purpose: SpecialResolvePurpose = .playback) async throws -> ResolvedVideo {
        try Task.checkCancellation()
        let settings = try SpecialSettings(source: source, config: config)
        let context = contextGeneration
        let generation = namespaceGenerations[settings.namespace, default: 0]
        if purpose == .playback { playbackGeneration &+= 1 }
        let playback = playbackGeneration
        if purpose == .download {
            while downloadProxies.count + pendingDownloads >= maximumDownloads {
                try Task.checkCancellation()
                try check(context, namespace: settings.namespace, generation: generation)
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            pendingDownloads += 1
        }
        defer { if purpose == .download { pendingDownloads -= 1 } }
        func checkOperation() throws {
            try check(context, namespace: settings.namespace, generation: generation)
            guard purpose != .playback || playback == playbackGeneration else { throw CancellationError() }
        }
        try checkOperation()
        let parts = episode.url.components(separatedBy: "@")
        guard parts.count >= 2, parts.count <= 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let vodID = Int(parts[0]), let collection = Int(parts[1]) else {
            throw SpecialSourceError.configuration("剧集标识须为 vod_id@collection 或 vod_id@collection@id")
        }
        let credentials = SpecialCredentials(namespace: settings.namespace)
        let device: String
        if let saved = try credentials.get("device"), !saved.isEmpty { device = saved }
        else {
            device = String(Crypto.md5(UUID().uuidString + String(Self.milliseconds())).dropFirst(8).prefix(16))
            try credentials.set(device, key: "device")
        }
        let token = try await obtainToken(settings, device: device, credentials: credentials)
        try checkOperation()
        let timestamp = Self.milliseconds()
        var fields = ["vod_id": String(vodID)]
        if !settings.hema {
            fields.merge(["sig": "", "nc_token": "", "code": "", "phone": "", "session_id": "", "cur_time": String(timestamp)]) { _, new in new }
        }
        let list = try await request(settings.listURL, fields: fields, settings: settings, device: device, token: token)
        try checkOperation()
        let rows = list[settings.hema ? "map_list" : "vod_collection"] as? [[String: Any]] ?? []
        let targetID = parts.count == 3 ? Int(parts[2]) : nil
        guard let row = rows.first(where: {
            targetID != nil ? Int($0.text("id")) == targetID : Int($0.text("collection")) == collection
        }), !row.text("id").isEmpty else { throw SpecialSourceError.response("找不到请求的剧集，未猜测或枚举其他影片") }
        if settings.hema {
            fields = ["xz": "0", "vod_map_id": row.text("id"), "vod_id": String(vodID), "collection": row.text("collection")]
        } else {
            guard !row.text("vod_id").isEmpty, !row.text("vod_token").isEmpty, !row.text("cur_time").isEmpty else {
                throw SpecialSourceError.response("剧集授权字段不完整")
            }
            fields = ["collection_id": row.text("id"), "vod_id": row.text("vod_id"), "vod_token": row.text("vod_token"),
                      "cur_time": row.text("cur_time"), "sig": "", "nc_token": "", "code": "", "phone": "", "session_id": ""]
        }
        let detail = try await request(settings.detailURL, fields: fields, settings: settings, device: device, token: token)
        try checkOperation()
        guard let original = URL(string: detail.text("vod_url")), ["http", "https"].contains(original.scheme?.lowercased() ?? ""),
              let ckData = Data(base64Encoded: detail.text("ck"), options: .ignoreUnknownCharacters),
              let ck = String(data: ckData, encoding: .utf8), !ck.isEmpty else {
            throw SpecialSourceError.response("缺少合法 vod_url / ck 授权")
        }
        let proxy = try SpecialHLSProxy(original: original, ck: ck, settings: settings)
        do {
            let local = try await proxy.start()
            try checkOperation()
            if purpose == .playback {
                let previous = activeProxy
                activeProxy = proxy
                previous?.stop()
            } else { downloadProxies[local] = proxy }
            return ResolvedVideo(url: local)
        } catch { proxy.stop(); throw error }
    }

    /// Player may call this on dismissal; the next successful resolve also replaces the old proxy.
    func stop() { playbackGeneration &+= 1; activeProxy?.stop(); activeProxy = nil }

    /// A download owns its returned URL until completion/failure/cancellation.
    /// The caller must release it in defer; the bounded pool never evicts a playing proxy.
    func releaseDownload(url: URL) { downloadProxies.removeValue(forKey: url)?.stop() }

    private func obtainToken(_ settings: SpecialSettings, device: String, credentials: SpecialCredentials) async throws -> String {
        let context = contextGeneration
        let generation = namespaceGenerations[settings.namespace, default: 0]
        try check(context, namespace: settings.namespace, generation: generation)
        if let token = try credentials.get("token"), !token.isEmpty { return token }
        // Optional runtime token must be supplied by the caller's legitimate authorization flow.
        if !settings.authorizedToken.isEmpty {
            try credentials.set(settings.authorizedToken, key: "token")
            return settings.authorizedToken
        }
        guard !settings.hema else { throw SpecialSourceError.authorization }
        if let pending = initialization[settings.namespace] {
            let token = try await pending.task.value
            try check(context, namespace: settings.namespace, generation: generation)
            return token
        }
        let id = UUID()
        let task = Task { @MainActor in
            guard let url = settings.tokenURL else { throw SpecialSourceError.configuration("缺少 tokenUrl") }
            let result = try await self.request(url, fields: ["invited_by": "", "is_install": "1"], settings: settings, device: device, token: "")
            try self.check(context, namespace: settings.namespace, generation: generation)
            guard let user = result["user_info"] as? [String: Any], !user.text("token").isEmpty else {
                throw SpecialSourceError.response("token 初始化未返回 user_info.token")
            }
            let token = user.text("token")
            try credentials.set(token, key: "token")
            return token
        }
        initialization[settings.namespace] = (id, task)
        defer { if initialization[settings.namespace]?.id == id { initialization[settings.namespace] = nil } }
        // Waiter cancellation does not cancel a shared authorization task; cache clear/context
        // invalidation does. Every waiter independently rejects its cancelled/stale result.
        let token = try await task.value
        try check(context, namespace: settings.namespace, generation: generation)
        return token
    }

    private func request(_ url: URL, fields: [String: String], settings: SpecialSettings, device: String, token: String) async throws -> [String: Any] {
        let context = contextGeneration
        let generation = namespaceGenerations[settings.namespace, default: 0]
        try check(context, namespace: settings.namespace, generation: generation)
        guard !settings.adEndpoints.contains(SpecialSettings.endpointIdentity(url)) else { throw SpecialSourceError.advertisingGate }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var headers = settings.headers
        let now = Self.milliseconds()
        if settings.hema {
            if hemaClock[settings.namespace] == nil { hemaClock[settings.namespace] = now - Int64.random(in: 5000...5999) }
            headers.merge(["Device-Id": device, "token": token, "Cur-Time": String(hemaClock[settings.namespace]!),
                           "timestamp": String(now), "Mob-Mfr": "apple", "Mob-Model": "iPhone"]) { _, new in new }
        } else {
            headers.merge(["log-header": "I am the log request header.", "app_id": "muxingshipin", "channel_code": "mxsp_sp01",
                           "cur_time": String(now), "device_id": device, "mob_mfr": "apple", "mobmodel": "iPhone",
                           "package_name": "com.hfgr.zhongde.mx", "sys_platform": "2", "sysrelease": ProcessInfo.processInfo.operatingSystemVersionString,
                           "version": "31100", "sign": Crypto.md5(settings.salt + device + String(now)), "token": token]) { _, new in new }
        }
        // Source-supplied headers have original protocol precedence, except transport-managed fields.
        headers.merge(settings.headers) { _, new in new }
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        for (key, value) in headers where !["host", "content-length", "connection"].contains(key.lowercased()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            Crypto.androidURIEncode($0.key) + "=" + Crypto.androidURIEncode($0.value)
        }.joined(separator: "&").utf8)
        let (data, response) = try await transport.session.data(for: request)
        try check(context, namespace: settings.namespace, generation: generation)
        guard let http = response as? HTTPURLResponse else { throw SpecialSourceError.response("无 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else { throw SpecialSourceError.response("HTTP \(http.statusCode)，未重试或重新生成权益") }
        guard data.count <= 8 * 1024 * 1024 else { throw SpecialSourceError.response("响应超过大小限制") }
        let decoded: Data
        if settings.hema {
            guard let wrapper = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let encrypted = Data(base64Encoded: wrapper.text("data"), options: .ignoreUnknownCharacters) else {
                throw SpecialSourceError.response("3DES 响应缺少 data")
            }
            decoded = try Crypto.tripleDESDecrypt(encrypted, key: Data(settings.key.prefix(24)), iv: settings.iv)
        } else if (try? JSONSerialization.jsonObject(with: data)) != nil { decoded = data }
        else {
            guard let string = String(data: data, encoding: .utf8), let encrypted = Data(base64Encoded: string, options: .ignoreUnknownCharacters) else {
                throw SpecialSourceError.response("AES 响应不是 Base64")
            }
            decoded = try Crypto.aesCBCDecrypt(encrypted, key: settings.key, iv: settings.iv)
        }
        guard let envelope = try JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { throw SpecialSourceError.response("响应不是对象") }
        try Self.checkGate(envelope)
        guard Int(envelope.text("code")) == 10000 else {
            throw SpecialSourceError.response(envelope.text("message").isEmpty ? "业务 code \(envelope.text("code"))" : envelope.text("message"))
        }
        guard let result = envelope["result"] as? [String: Any] else { throw SpecialSourceError.response("响应缺少 result") }
        try Self.checkGate(result)
        return result
    }

    private static func checkGate(_ data: [String: Any]) throws {
        if ["check_url", "check_page_url", "verification_url"].contains(where: { !data.text($0).isEmpty }) { throw SpecialSourceError.verification }
        if ["need_ad", "ad_required", "require_ad"].contains(where: { ["1", "true"].contains(data.text($0).lowercased()) }) {
            throw SpecialSourceError.advertisingGate
        }
        let message = data.text("message").lowercased()
        if ["验证码", "风控", "captcha", "verify"].contains(where: message.contains) { throw SpecialSourceError.verification }
        if ["广告", "advert", "watch ad"].contains(where: message.contains) { throw SpecialSourceError.advertisingGate }
    }
    private static func milliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

private struct SpecialSettings {
    let hema: Bool
    let namespace: String
    let key: Data
    let iv: Data
    let salt: String
    let listURL: URL
    let detailURL: URL
    let tokenURL: URL?
    let replacement: URL
    let signingSalt: String
    let authorizedToken: String
    let headers: [String: String]
    let playerHeaders: [String: String]
    let adEndpoints: Set<String>

    init(source: String, config: [String: Any]) throws {
        let name: String
        switch source { case "xm3u8": name = "src1"; case "xiaocao": name = "src7"; case "hema": name = "src2"
        default: throw SpecialSourceError.configuration("未知特殊源") }
        guard let values = config[name] as? [String: Any], (Int(values.text("enable")) ?? 0) > 0 else {
            throw SpecialSourceError.configuration("\(name) 未启用")
        }
        func endpoint(_ name: String) throws -> URL {
            guard let url = URL(string: values.text(name)), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else {
                throw SpecialSourceError.configuration("\(name) 不是合法 HTTP URL")
            }
            return url
        }
        hema = source == "hema"
        listURL = try endpoint("listUrl"); detailURL = try endpoint("detailUrl")
        tokenURL = values.text("tokenUrl").isEmpty ? nil : try endpoint("tokenUrl")
        replacement = try endpoint("replaceDomain")
        guard replacement.path.isEmpty || replacement.path == "/", replacement.query == nil else {
            throw SpecialSourceError.configuration("replaceDomain 须为源站 origin")
        }
        key = Data(values.text("key").utf8); iv = Data(values.text("iv").utf8)
        guard (hema ? key.count >= 24 : [16, 24, 32].contains(key.count)), iv.count == (hema ? 8 : 16) else {
            throw SpecialSourceError.configuration("运行时 key / iv 长度无效")
        }
        salt = values.text("salt"); signingSalt = values.text("replaceEncryptDomain")
        guard !signingSalt.isEmpty, hema || !salt.isEmpty else { throw SpecialSourceError.configuration("缺少签名盐") }
        namespace = source + "." + Crypto.md5(listURL.absoluteString)
        authorizedToken = values.text("authorizedToken")
        func headerMap(_ name: String) -> [String: String] {
            if let map = values[name] as? [String: String] { return map }
            var result: [String: String] = [:]
            for item in values[name] as? [[String: Any]] ?? [] where !item.text("key").isEmpty { result[item.text("key")] = item.text("value") }
            return result
        }
        headers = headerMap("headers"); playerHeaders = headerMap("playerHeaders")
        adEndpoints = Set([values.text("adUrl"), values.text("adsUrl")].compactMap(URL.init(string:)).map(Self.endpointIdentity))
    }
    static func endpointIdentity(_ url: URL) -> String {
        var components = URLComponents(url: url.standardized, resolvingAgainstBaseURL: false)
        components?.query = nil; components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
}

private struct SpecialCredentials {
    let namespace: String
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "NiuNiu.SpecialSources",
         kSecAttrAccount as String: namespace + "." + key]
    }
    func get(_ key: String) throws -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SpecialSourceError.keychain(status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
    func set(_ value: String, key: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(key).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SpecialSourceError.keychain(status) }
    }
    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SpecialSourceError.keychain(status) }
    }
}

/// No cross-host credential forwarding. A redirect needs a new approved source configuration.
private final class SpecialTransport: NSObject, URLSessionTaskDelegate {
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
private final class SpecialHLSProxy {
    private let settings: SpecialSettings
    private let ck: String
    private let root: URL
    private let directory: String
    private let capability = UUID().uuidString
    private let transport = SpecialTransport()
    private var listener: NWListener?
    private var port: UInt16?
    private var resources: [String: URL] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var readiness: CheckedContinuation<URL, Error>?
    private var stopped = false

    init(original: URL, ck: String, settings: SpecialSettings) throws {
        self.settings = settings; self.ck = ck
        guard let path = URLComponents(url: original, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              path.split(separator: "/").count > 1,
              let root = URL(string: path, relativeTo: settings.replacement)?.absoluteURL else { throw SpecialSourceError.mediaScope }
        self.root = root
        directory = root.deletingLastPathComponent().path + "/"
        // ck is an authorization query, never an upstream URL or arbitrary HTTP headers.
        guard !ck.contains("\r"), !ck.contains("\n"), !ck.contains("#") else { throw SpecialSourceError.mediaScope }
    }

    func start() async throws -> URL {
        try Task.checkCancellation()
        guard !stopped, listener == nil else { throw CancellationError() }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let local: URL
        do {
            local = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    guard !stopped, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    readiness = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in
                            guard let self = self, !self.stopped, self.readiness != nil else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port else { self.finishStart(.failure(SpecialSourceError.proxy("端口不可用"))); return }
                                self.port = port.rawValue
                                do { let url = try self.register(self.root); self.finishStart(.success(url)) }
                                catch { self.finishStart(.failure(error)) }
                            case .failed(let error): self.finishStart(.failure(error))
                            case .cancelled: self.finishStart(.failure(CancellationError()))
                            default: break
                            }
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in
                            guard let self = self, !self.stopped else { connection.cancel(); return }
                            self.accept(connection)
                        }
                    }
                    listener.start(queue: DispatchQueue(label: "NiuNiu.SpecialHLS"))
                }
            }, onCancel: {
                // All continuation ownership transitions run on MainActor. finishStart
                // clears ownership before resuming, so ready/failed/cancel cannot double resume.
                Task { @MainActor in self.stop() }
            })
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
        } catch { stop(); throw error }
        // Preflight the root before exposing it to AVPlayer so verification/DRM errors throw.
        do {
            var request = URLRequest(url: try signed(root))
            for (key, value) in settings.playerHeaders where !["host", "content-length", "connection"].contains(key.lowercased()) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (body, response) = try await transport.session.data(for: request)
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  body.count <= 2 * 1024 * 1024, let playlist = String(data: body, encoding: .utf8),
                  playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
                throw SpecialSourceError.unsupportedMedia("HLS 初始化被拒绝或格式无效，需重新授权/验证")
            }
            _ = try rewrite(playlist, base: root)
            return local
        } catch { stop(); throw error }
    }

    private func finishStart(_ result: Result<URL, Error>) {
        let pending = readiness; readiness = nil; pending?.resume(with: result)
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        finishStart(.failure(CancellationError()))
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        resources.removeAll()
        transport.session.invalidateAndCancel()
    }

    private func checked(_ url: URL) throws -> URL {
        let url = url.standardized
        guard url.scheme == settings.replacement.scheme, url.host == settings.replacement.host,
              url.port == settings.replacement.port, url.user == nil, url.password == nil,
              url.path.hasPrefix(directory), !url.path.contains("\\"), !url.path.contains("%"), url.fragment == nil else {
            throw SpecialSourceError.mediaScope
        }
        return url
    }
    private func register(_ url: URL) throws -> URL {
        let url = try checked(url)
        let id = Crypto.md5(url.absoluteString)
        guard let port = port, resources[id] != nil || resources.count < 20000 else { throw SpecialSourceError.proxy("媒体资源数量或端口无效") }
        resources[id] = url
        return URL(string: "http://127.0.0.1:\(port)/\(capability)/\(id)")!
    }
    private func signed(_ url: URL) throws -> URL {
        var components = URLComponents(url: try checked(url), resolvingAgainstBaseURL: false)!
        let time = String(Int64(Date().timeIntervalSince1970), radix: 16)
        let auth = URLComponents(string: "https://authorization.invalid/?" + ck)?.queryItems ?? []
        let existing = (components.queryItems ?? []).filter { !["wsSecret", "wsTime"].contains($0.name) }
        let names = Set(auth.map(\.name))
        components.queryItems = existing.filter { !names.contains($0.name) } + auth.filter { !["wsSecret", "wsTime"].contains($0.name) }
            + [URLQueryItem(name: "wsSecret", value: Crypto.md5(settings.signingSalt + url.path + time)), URLQueryItem(name: "wsTime", value: time)]
        guard let result = components.url else { throw SpecialSourceError.mediaScope }
        return result
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 24 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: DispatchQueue(label: "NiuNiu.SpecialHLS.connection"))
        receive(connection, id: id, buffer: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self = self, !self.stopped, self.connections[id] != nil else { connection.cancel(); return }
                var accumulated = buffer; accumulated.append(data ?? Data())
                if accumulated.count > 16384 { self.send(connection, id: id, status: 431, body: Data(), type: "text/plain"); return }
                if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.tasks[id] = Task { @MainActor in await self.serve(accumulated, connection: connection, id: id) }
                } else if complete || error != nil { connection.cancel(); self.connections[id] = nil }
                else { self.receive(connection, id: id, buffer: accumulated) }
            }
        }
    }
    private func serve(_ data: Data, connection: NWConnection, id: UUID) async {
        do {
            try Task.checkCancellation()
            guard !stopped, connections[id] != nil else { throw CancellationError() }
            guard let text = String(data: data, encoding: .utf8) else { throw SpecialSourceError.proxy("HTTP 请求编码无效") }
            let lines = text.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])), first[2] == "HTTP/1.1" else { throw SpecialSourceError.proxy("只接受 GET / HEAD") }
            let path = String(first[1]).split(separator: "/")
            guard path.count == 2, path[0] == Substring(capability), let target = resources[String(path[1])] else { throw SpecialSourceError.mediaScope }
            var request = URLRequest(url: try signed(target))
            request.httpMethod = String(first[0])
            for (key, value) in settings.playerHeaders where !["host", "content-length", "connection"].contains(key.lowercased()) { request.setValue(value, forHTTPHeaderField: key) }
            if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
                let value = String(range.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                guard value.range(of: "^bytes=[0-9]+-[0-9]*$", options: .regularExpression) != nil else { throw SpecialSourceError.proxy("Range 不受支持") }
                request.setValue(value, forHTTPHeaderField: "Range")
            }
            let (body, response) = try await transport.session.data(for: request)
            try Task.checkCancellation()
            guard !stopped, connections[id] != nil else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else { throw SpecialSourceError.response("媒体请求被拒绝；可能需要重新授权或验证") }
            guard body.count <= 32 * 1024 * 1024 else { throw SpecialSourceError.unsupportedMedia("单资源超过代理内存限制") }
            let playlist = String(data: body, encoding: .utf8)
            let isHLS = playlist?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") == true
            if target == root && !isHLS && request.httpMethod != "HEAD" { throw SpecialSourceError.unsupportedMedia("特殊源当前只支持 HLS") }
            let output = isHLS ? try rewrite(playlist!, base: target) : body
            var extra: [String: String] = [:]
            if !isHLS {
                for key in ["Content-Range", "Accept-Ranges"] { if let value = http.value(forHTTPHeaderField: key) { extra[key] = value } }
            }
            send(connection, id: id, status: http.statusCode, body: output,
                 type: isHLS ? "application/vnd.apple.mpegurl" : (http.mimeType ?? "application/octet-stream"),
                 head: request.httpMethod == "HEAD", extra: extra)
        } catch {
            guard !stopped, !Task.isCancelled, connections[id] != nil else { connection.cancel(); return }
            send(connection, id: id, status: 502, body: Data(error.localizedDescription.utf8), type: "text/plain; charset=utf-8")
        }
    }

    private func rewrite(_ playlist: String, base: URL) throws -> Data {
        var result: [String] = []
        let regex = try NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        for line in playlist.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            if line.hasPrefix("#EXT-X-SESSION-KEY:") || line.hasPrefix("#EXT-X-KEY:") {
                guard line.contains("METHOD=NONE") || (line.contains("METHOD=AES-128") && !line.contains("KEYFORMAT=")) else {
                    throw SpecialSourceError.unsupportedMedia("DRM / SAMPLE-AES / 非 identity KEYFORMAT；不绕过加密或权益")
                }
            }
            if line.hasPrefix("#") {
                var rewritten = line
                let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                for match in matches.reversed() {
                    guard let range = Range(match.range(at: 1), in: line), let url = URL(string: String(line[range]), relativeTo: base)?.absoluteURL else { throw SpecialSourceError.mediaScope }
                    let local = try register(url)
                    guard let current = Range(match.range(at: 1), in: rewritten) else { throw SpecialSourceError.mediaScope }
                    rewritten.replaceSubrange(current, with: local.absoluteString)
                }
                result.append(rewritten)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty { result.append(line) }
            else {
                guard let url = URL(string: line.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL else { throw SpecialSourceError.mediaScope }
                result.append(try register(url).absoluteString)
            }
        }
        return Data(result.joined(separator: "\n").utf8)
    }

    private func send(_ connection: NWConnection, id: UUID, status: Int, body: Data, type: String, head: Bool = false, extra: [String: String] = [:]) {
        let reason = status == 200 ? "OK" : (status == 206 ? "Partial Content" : "Bad Gateway")
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for (key, value) in extra where !value.contains("\r") && !value.contains("\n") { header += "\(key): \(value)\r\n" }
        var data = Data((header + "\r\n").utf8); if !head { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections[id] = nil; self?.tasks[id] = nil }
        })
    }
}
