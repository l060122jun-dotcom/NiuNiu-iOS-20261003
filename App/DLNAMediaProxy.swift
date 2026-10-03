import Foundation
import Network
import Darwin

/// A cast-scoped capability server. All mutable server state belongs to queue.
/// No URL is accepted from a renderer; it can only request opaque registered IDs.
final class DLNAMediaProxy {
    private let queue = DispatchQueue(label: "app.niuniu.dlna.media")
    private let source: URL
    private let headers: [String: String]
    private let token = UUID().uuidString + UUID().uuidString
    private let onError: (String) -> Void
    private var listener: NWListener?
    private var base: URL?
    private var urls: [String: URL] = [:]
    private var ids: [URL: String] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private var startup: CheckedContinuation<URL, Error>?

    init(url: URL, headers: [String: String], onError: @escaping (String) -> Void) throws {
        guard Self.valid(url) else { throw DLNAError.message("媒体代理仅接受不含用户名密码的 HTTP(S) 地址。") }
        let forbidden = Set(["host", "connection", "content-length", "transfer-encoding", "range", "accept-encoding", "proxy-authorization", "proxy-connection", "upgrade", "te", "trailer"])
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.allSatisfy({ Self.headerToken($0) }),
                  !value.contains("\r"), !value.contains("\n"), !forbidden.contains(name.lowercased()) else {
                throw DLNAError.message("媒体请求头包含非法字段或代理不支持的传输控制字段。")
            }
        }
        source = url
        self.headers = headers
        self.onError = onError
    }

    private static func headerToken(_ c: UInt8) -> Bool {
        (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c)
            || Array("!#$%&'*+-.^_`|~".utf8).contains(c)
    }

    private static func valid(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil
    }

    fileprivate static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))"
    }

    /// en0 is iOS's actual Wi-Fi interface; never substitute cellular/VPN/loopback.
    private static func wifiIPv4() throws -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { throw DLNAError.message("无法读取 Wi-Fi 接口地址。") }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let entry = item.pointee
            if String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: buffer)
                    if ip != "0.0.0.0", !ip.hasPrefix("127.") { return ip }
                }
            }
            cursor = entry.ifa_next
        }
        throw DLNAError.message("当前 Wi-Fi 没有可用 IPv4 地址，不能生成电视可访问的投屏代理地址。")
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !stopped, listener == nil else { continuation.resume(throwing: CancellationError()); return }
                    startup = continuation
                    do {
                        let ip = try Self.wifiIPv4()
                        let parameters = NWParameters.tcp
                        parameters.requiredInterfaceType = .wifi
                        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: .any)
                        let server = try NWListener(using: parameters, on: .any)
                        listener = server
                        server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        server.stateUpdateHandler = { [weak self] state in
                            guard let self = self, !self.stopped else { return }
                            switch state {
                            case .ready:
                                guard let port = server.port, let base = URL(string: "http://\(ip):\(port.rawValue)") else {
                                    self.failStart(DLNAError.message("媒体代理未取得监听端口。")); return
                                }
                                self.base = base
                                do {
                                    let url = try self.register(self.source)
                                    self.startup?.resume(returning: url)
                                    self.startup = nil
                                } catch { self.failStart(error) }
                            case .failed(let error):
                                if self.startup != nil { self.failStart(error) }
                                else { self.onError("媒体代理监听失败：\(error.localizedDescription)"); self.cancel() }
                            default: break
                            }
                        }
                        server.start(queue: queue)
                        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                            guard let self = self, self.startup != nil else { return }
                            self.failStart(DLNAError.message("媒体代理启动超时，请检查 Wi-Fi 和局域网权限。"))
                        }
                    } catch { failStart(error) }
                }
            }
        }, onCancel: { self.stop() })
    }

    func stop() { queue.async { [self] in cancel() } }

    private func failStart(_ error: Error) {
        startup?.resume(throwing: error)
        startup = nil
        cancel()
    }

    private func cancel() {
        stopped = true
        startup?.resume(throwing: CancellationError())
        startup = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        tasks.values.forEach { $0.cancel() }
        connections.values.forEach { $0.cancel() }
        tasks.removeAll()
        connections.removeAll()
        urls.removeAll()
        ids.removeAll()
    }

    private func register(_ url: URL) throws -> URL {
        guard !stopped, Self.valid(url), let base = base else { throw DLNAError.message("HLS 引用不是允许的 HTTP(S) 资源。") }
        if let id = ids[url] { return base.appendingPathComponent(token).appendingPathComponent(id) }
        guard urls.count < 16_384 else { throw DLNAError.message("本次 HLS 引用数量超出限制，请重新投屏。") }
        // Retain extension for renderers that infer format from path.
        let ext = url.pathExtension.lowercased()
        let suffix = !ext.isEmpty && ext.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) ? "." + ext : ""
        let id = UUID().uuidString + suffix
        ids[url] = id
        urls[id] = url
        return base.appendingPathComponent(token).appendingPathComponent(id)
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(id) }
            if case .cancelled = state { self?.finish(id) }
        }
        connection.start(queue: queue)
        receive(connection, id: id, buffer: Data())
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.connections[id] != nil, self.tasks[id] == nil else { return }
            self.finish(id)
        }
    }

    private func finish(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        let connection = connections.removeValue(forKey: id)
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self = self, !self.stopped, self.connections[id] != nil else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            guard buffer.count <= 16_384 else { self.finish(id); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == buffer.count, let text = String(data: buffer, encoding: .utf8) else { self.finish(id); return }
                self.handle(text, connection: connection, id: id)
            } else if complete || error != nil { self.finish(id) }
            else { self.receive(connection, id: id, buffer: buffer) }
        }
    }

    private func handle(_ text: String, connection: NWConnection, id: UUID) {
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, ["GET", "HEAD"].contains(String(parts[0])),
              ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])) else { reject(connection, id: id, status: 405); return }
        let path = String(parts[1]).components(separatedBy: "/")
        guard path.count == 3, path[0].isEmpty, path[1] == token, let url = urls[path[2]] else {
            reject(connection, id: id, status: 404); return
        }
        var range: String?
        var names = Set<String>()
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { reject(connection, id: id, status: 400); return }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard names.insert(name).inserted, name.utf8.allSatisfy({ Self.headerToken($0) }),
                  name != "transfer-encoding", name != "content-length" || value == "0" else {
                reject(connection, id: id, status: 400); return
            }
            if name == "range" {
                guard value.range(of: "^bytes=([0-9]+-[0-9]*|-[0-9]+)$", options: .regularExpression) != nil else {
                    reject(connection, id: id, status: 416); return
                }
                range = value
            }
        }
        let method = String(parts[0])
        tasks[id] = Task { [self] in
            await serve(url: url, method: method, range: range, connection: connection)
            queue.async { [self] in finish(id) }
        }
    }

    private func reject(_ connection: NWConnection, id: UUID, status: Int) {
        connection.send(content: Data("HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in
            self?.finish(id)
        })
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let deadline = DispatchWorkItem { connection.cancel() }
            queue.asyncAfter(deadline: .now() + 30, execute: deadline)
            connection.send(content: data, completion: .contentProcessed { error in
                deadline.cancel()
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func serve(url: URL, method: String, range: String?, connection: NWConnection) async {
        let delegate = DLNAMediaStreamDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        await withTaskCancellationHandler(operation: {
        var sent = false
        do {
            var request = URLRequest(url: url)
            request.httpMethod = method
            if Self.origin(url) == Self.origin(source) {
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let likelyHLS = url.pathExtension.lowercased() == "m3u8"
            if !likelyHLS, let range = range { request.setValue(range, forHTTPHeaderField: "Range") }
            let (chunks, response) = try await delegate.open(session: session, request: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw DLNAError.message("媒体上游没有返回 HTTP 响应。") }
            if (300...399).contains(response.statusCode) { throw DLNAError.message("媒体重定向到未经授权的主机或协议，已拒绝。") }
            let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
            if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
                throw DLNAError.message("媒体上游忽略 identity 编码要求，不能安全转发其 Range 与长度。")
            }
            let hls = likelyHLS || mime.contains("mpegurl")
            if !(200...299).contains(response.statusCode) {
                onError("媒体上游返回 HTTP \(response.statusCode)。")
            }
            if hls, method == "GET", (200...299).contains(response.statusCode) {
                guard response.statusCode == 200 else { throw DLNAError.message("HLS 清单必须返回完整 HTTP 200 响应。") }
                var data = Data()
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    guard data.count + chunk.count <= 1_048_576 else { throw DLNAError.message("HLS 清单超出 1 MB 限制。") }
                    data.append(chunk)
                    delegate.consumeChunk()
                }
                let rewritten = try await rewrite(data, relativeTo: response.url ?? url)
                try await send(Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(rewritten.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8), to: connection)
                sent = true
                try await send(rewritten, to: connection)
                return
            }
            var head = "HTTP/1.1 \(response.statusCode) Upstream\r\nConnection: close\r\nCache-Control: no-store\r\n"
            for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
                // HEAD playlists advertise transformed type but not an upstream byte length.
                if hls && ["Content-Length", "Content-Range", "Accept-Ranges"].contains(name) { continue }
                if let value = response.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") {
                    head += "\(name): \(value)\r\n"
                }
            }
            head += "\r\n"
            try await send(Data(head.utf8), to: connection)
            sent = true
            if method == "HEAD" { return }
            // URLSession is suspended for each callback; resume only after TCP drains it.
            for try await chunk in chunks {
                try Task.checkCancellation()
                var offset = 0
                while offset < chunk.count {
                    let end = min(offset + 32_768, chunk.count)
                    try await send(chunk.subdata(in: offset..<end), to: connection)
                    offset = end
                }
                delegate.consumeChunk()
            }
        } catch {
            if !Task.isCancelled {
                // Do not expose upstream URL/query/header values in renderer responses or UI.
                let message = (error as? DLNAError)?.localizedDescription ?? "媒体代理传输失败（网络错误 \((error as NSError).code)）。"
                onError(message)
                if !sent { try? await send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection) }
            }
        }
        }, onCancel: { delegate.cancelTransfer(); session.invalidateAndCancel() })
    }

    private func rewrite(_ data: Data, relativeTo baseURL: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !stopped, let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
                        throw DLNAError.message("HLS 清单无效或代理已停止。")
                    }
                    let uri = try NSRegularExpression(pattern: "URI=\"([^\"]*)\"")
                    var output: [String] = []
                    for original in text.components(separatedBy: .newlines) {
                        var line = original.trimmingCharacters(in: .whitespaces)
                        if line.hasPrefix("#EXT-X-DEFINE:") || line.hasPrefix("#EXT-X-CONTENT-STEERING:") {
                            throw DLNAError.message("此 HLS 使用变量或内容引导，当前受限代理不支持。")
                        }
                        if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                            let attrs = line.components(separatedBy: ",")
                            guard attrs.contains(where: { $0.hasSuffix("METHOD=NONE") || $0.hasSuffix("METHOD=AES-128") }),
                                  !line.contains("KEYFORMAT=") || line.contains("KEYFORMAT=\"identity\"") else {
                                throw DLNAError.message("此 HLS 使用 DRM / SAMPLE-AES 或不支持的密钥格式，代理不会绕过授权。")
                            }
                        }
                        if !line.isEmpty && !line.hasPrefix("#") {
                            guard let resource = URL(string: line, relativeTo: baseURL)?.absoluteURL else { throw DLNAError.message("HLS 资源引用无效。") }
                            line = try register(resource).absoluteString
                        } else if line.hasPrefix("#EXT") {
                            let matches = uri.matches(in: line, range: NSRange(line.startIndex..., in: line))
                            for match in matches.reversed() {
                                guard let valueRange = Range(match.range(at: 1), in: line),
                                      let resource = URL(string: String(line[valueRange]), relativeTo: baseURL)?.absoluteURL else {
                                    throw DLNAError.message("HLS URI 属性无效。")
                                }
                                let replacement = try register(resource).absoluteString
                                line.replaceSubrange(valueRange, with: replacement)
                            }
                            if line.contains("URI=") && matches.isEmpty { throw DLNAError.message("HLS URI 属性编码不支持。") }
                        }
                        output.append(line)
                    }
                    continuation.resume(returning: Data(output.joined(separator: "\n").utf8))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// URLSession's normal trust evaluation remains enabled. Redirect credentials never
/// travel to a new origin; unknown redirects fail rather than becoming an open proxy.
private class DLNAMediaRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private var redirects = 0 // URLSession's serial delegate operation queue.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 10, let old = response.url, let next = request.url,
              next.user == nil, next.password == nil,
              DLNAMediaProxy.origin(old) == DLNAMediaProxy.origin(next),
              task.countOfBytesReceived < 1_048_576 else { completionHandler(nil); return }
        var safe = request
        // Every accepted hop has exactly the previous origin, hence also the
        // original request origin. Reapply only that task's scoped headers.
        if let original = task.originalRequest {
            safe.allHTTPHeaderFields = original.allHTTPHeaderFields
            safe.httpMethod = original.httpMethod
        }
        completionHandler(safe)
    }
}

/// Bounded backpressure instead of accumulating a complete movie or an unbounded
/// AsyncBytes buffer. Each URLSession callback is <=256 KiB; at most two callbacks
/// are queued (512 KiB). Overflow fails explicitly rather than silently dropping data.
private final class DLNAMediaStreamDelegate: DLNAMediaRedirectDelegate, URLSessionDataDelegate {
    private let lock = NSLock()
    private var responseWaiter: CheckedContinuation<(AsyncThrowingStream<Data, Error>, URLResponse), Error>?
    private var producer: AsyncThrowingStream<Data, Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Error>?
    private var dataTask: URLSessionDataTask?
    private var cancelled = false

    func open(session: URLSession, request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(2)) { self.producer = $0 }
                responseWaiter = continuation
                let task = session.dataTask(with: request)
                dataTask = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = dataTask
        let waiter = responseWaiter
        responseWaiter = nil
        let producer = self.producer
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
        producer?.finish(throwing: CancellationError())
        task?.cancel()
    }

    func cancelTransfer() { cancel() }

    func consumeChunk() {
        lock.lock()
        let task = cancelled ? nil : dataTask
        lock.unlock()
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let waiter = responseWaiter
        responseWaiter = nil
        let stream = self.stream
        let cancelled = self.cancelled
        lock.unlock()
        completionHandler(cancelled ? .cancel : .allow)
        if let waiter = waiter, let stream = stream {
            if cancelled { waiter.resume(throwing: CancellationError()) }
            else { waiter.resume(returning: (stream, response)) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= 262_144 else {
            producer?.finish(throwing: DLNAError.message("媒体上游数据块超出 256 KiB 缓冲限制。"))
            dataTask.cancel()
            return
        }
        dataTask.suspend()
        if let result = producer?.yield(data), case .dropped = result {
            producer?.finish(throwing: DLNAError.message("媒体代理缓冲已满，已取消上游传输。"))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let waiter = responseWaiter
        responseWaiter = nil
        lock.unlock()
        if let error = error { producer?.finish(throwing: error); waiter?.resume(throwing: error) }
        else {
            producer?.finish()
            waiter?.resume(throwing: DLNAError.message("媒体请求结束但没有 HTTP 响应。"))
        }
    }
}
