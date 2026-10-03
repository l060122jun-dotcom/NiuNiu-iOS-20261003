import Foundation
import CryptoKit
import UIKit
import IJKMediaFramework

/// Deliberately ephemeral: a local proxy cannot be handed to an iOS background daemon.
final class ForegroundHLSDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }
    struct Resource: Sendable {
        let url: URL
        let name: String
        let range: Range<Int64>?
        let key: Bool
    }
    struct Entry: Codable { let name: String; let bytes: Int64; let sha256: String }
    struct Receipt: Codable { let version: Int; let files: [Entry] }
    private let origin: URL
    private let headers: [String: String]
    private let progress: (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var counts: [Int: (Int64, Int64)] = [:]
    private var reportsTotal = false
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 600
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(origin: URL, headers: [String: String], progress: @escaping (Int64, Int64?) -> Void) {
        self.origin = origin; self.headers = headers; self.progress = progress
    }
    func cancel() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // A proxy capability must never send source credentials to another endpoint.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) { /* async download owns the temporary file */ }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        counts[downloadTask.taskIdentifier] = (totalBytesWritten, totalBytesExpectedToWrite)
        let bytes = counts.values.reduce(Int64(0)) { $0 + $1.0 }
        let expected = reportsTotal && counts.values.allSatisfy { $0.1 > 0 }
            ? counts.values.reduce(Int64(0)) { $0 + $1.1 } : nil
        lock.unlock()
        progress(bytes, expected)
    }
    private func request(_ url: URL, range: Range<Int64>? = nil) throws -> URLRequest {
        guard url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw Failure("HLS 引用超出给定代理 host/port，已拒绝发送授权请求头。")
        }
        var request = URLRequest(url: url)
        for (key, value) in headers {
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }),
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  !["host", "content-length", "range"].contains(key.lowercased()) else {
                throw Failure("前台下载请求头无效或包含受保护字段。")
            }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let range = range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        return request
    }
    private func fetch(_ url: URL, range: Range<Int64>? = nil) async throws -> URL {
        try Task.checkCancellation()
        let (temporary, response) = try await session.download(for: request(url, range: range))
        do {
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == (range == nil ? 200 : 206) else {
                throw Failure("前台资源请求失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
            }
            let mime = response.mimeType?.lowercased() ?? ""
            guard !mime.contains("html"), !mime.contains("json"), !mime.contains("dash") else {
                throw Failure("源返回内容引导/JSON/DASH，而非可离线保存的媒体。")
            }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw Failure("源返回空资源。") }
            if let range = range {
                let contentRange = response.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard Int64(size) == range.upperBound - range.lowerBound,
                      contentRange.hasPrefix("bytes \(range.lowerBound)-\(range.upperBound - 1)/") else {
                    throw Failure("代理未正确返回请求的 BYTERANGE，未保存错误分片。")
                }
            }
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
    private func playlist(_ url: URL) async throws -> [String] {
        let temporary = try await fetch(url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4 * 1024 * 1024,
              let text = String(data: try Data(contentsOf: temporary), encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw Failure("源不是有效 HLS playlist（或超出 4MB 安全上限）；不支持 DASH/内容引导。")
        }
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func attributes(_ line: String) throws -> [String: String] {
        let body = String(line.dropFirst((line.firstIndex(of: ":").map { line.distance(from: line.startIndex, to: $0) } ?? line.count) + 1))
        let regex = try NSRegularExpression(pattern: "([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)")
        var result: [String: String] = [:]
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let keyRange = Range(match.range(at: 1), in: body), let valueRange = Range(match.range(at: 2), in: body) else { continue }
            let key = String(body[keyRange]); let value = String(body[valueRange])
            guard result[key] == nil else { throw Failure("HLS 存在重复属性。") }
            result[key] = value.hasPrefix("\"") ? String(value.dropFirst().dropLast()) : value
        }
        return result
    }
    private func resolve(_ value: String, base: URL) throws -> URL {
        guard !value.contains("{$"), let url = URL(string: value, relativeTo: base)?.absoluteURL else {
            throw Failure("不支持 HLS 变量或无效资源引用。")
        }
        _ = try request(url)
        return url
    }
    static func byteRange(_ value: String, previous: (URL, Int64)?, url: URL) throws -> Range<Int64> {
        let fields = value.split(separator: "@", omittingEmptySubsequences: false)
        guard fields.count <= 2, let length = Int64(fields[0]), length > 0 else { throw Failure("无效 BYTERANGE 长度。") }
        let offset: Int64?
        if fields.count == 2 { offset = Int64(fields[1]) }
        else { offset = previous?.0 == url ? previous?.1 : nil }
        guard let start = offset, start >= 0, start <= Int64.max - length else { throw Failure("BYTERANGE 缺少合法起点。") }
        return start..<(start + length)
    }

    func run(package: URL, hls: Bool) async throws -> URL {
        defer { session.invalidateAndCancel() }
        lock.lock(); reportsTotal = !hls; lock.unlock()
        // No reuse/overwrite: partial packages belong to one UUID task only.
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        guard hls else {
            let temp = try await fetch(origin)
            let destination = package.appendingPathComponent("video.mp4")
            try FileManager.default.moveItem(at: temp, to: destination)
            return destination
        }
        var base = origin
        var lines = try await playlist(base)
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            var variants: [(Int64, URL)] = []
            for i in lines.indices where lines[i].hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = try Self.attributes(lines[i])
                guard i + 1 < lines.count, !lines[i + 1].hasPrefix("#") else { throw Failure("master 缺少 variant URI。") }
                // Only muxed A/V variants; do not silently drop separate audio/subtitles.
                if attrs["AUDIO"] == nil && attrs["SUBTITLES"] == nil {
                    variants.append((Int64(attrs["BANDWIDTH"] ?? "") ?? Int64.max, try resolve(lines[i + 1], base: base)))
                }
            }
            guard !lines.contains(where: { $0.hasPrefix("#EXT-X-SESSION-KEY") || $0.hasPrefix("#EXT-X-CONTENT-STEERING") }),
                  !variants.isEmpty else { throw Failure("不支持 DRM/内容引导或独立音轨 master，未忽略音频。") }
            variants.sort { $0.0 < $1.0 }
            // Highest muxed bandwidth <= 4Mbps; otherwise lowest available.
            base = (variants.last(where: { $0.0 <= 4_000_000 }) ?? variants[0]).1
            lines = try await playlist(base)
        }
        guard lines.contains("#EXT-X-ENDLIST"), !lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else {
            throw Failure("仅支持有 ENDLIST 的点播 HLS；live/嵌套 master 不支持前台离线保存。")
        }
        var resources: [Resource] = []
        var rewritten: [String] = []
        var pendingRange: String?
        var previous: (URL, Int64)?
        var segmentCount = 0
        var encrypted = false
        var explicitIV = false
        func resource(_ value: String, rangeValue: String?, key: Bool) throws -> String {
            let url = try resolve(value, base: base)
            let range = try rangeValue.map { try Self.byteRange($0, previous: key ? nil : previous, url: url) }
            if let range = range, !key { previous = (url, range.upperBound) } else if !key { previous = nil }
            let name = String(format: "%06d", resources.count) + (key ? ".key" : ".ts")
            resources.append(Resource(url: url, name: name, range: range, key: key))
            guard resources.count <= 50_000 else { throw Failure("HLS 资源数超出安全上限。") }
            return name
        }
        for line in lines {
            if line.hasPrefix("#EXT-X-BYTERANGE:") { pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count)); continue }
            if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = try Self.attributes(line)
                if attrs["METHOD"] == "NONE" { encrypted = false; explicitIV = false; rewritten.append("#EXT-X-KEY:METHOD=NONE"); continue }
                guard attrs["METHOD"] == "AES-128", attrs["KEYFORMAT"] == nil || attrs["KEYFORMAT"] == "identity",
                      let uri = attrs["URI"] else { throw Failure("不支持 DRM/SAMPLE-AES 或非 identity 密钥。") }
                let name = try resource(uri, rangeValue: nil, key: true)
                encrypted = true; explicitIV = attrs["IV"] != nil
                var output = "#EXT-X-KEY:METHOD=AES-128,URI=\"\(name)\""
                if let iv = attrs["IV"] {
                    guard iv.hasPrefix("0x"), iv.count == 34, iv.dropFirst(2).allSatisfy({ $0.isHexDigit }) else { throw Failure("无效 AES-128 IV。") }
                    output += ",IV=\(iv)"
                }
                rewritten.append(output); continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                guard !encrypted || explicitIV else { throw Failure("加密 MAP 缺少明确 AES IV。") }
                let attrs = try Self.attributes(line)
                guard let uri = attrs["URI"] else { throw Failure("MAP 缺少 URI。") }
                let name = try resource(uri, rangeValue: attrs["BYTERANGE"], key: false)
                rewritten.append("#EXT-X-MAP:URI=\"\(name)\""); continue
            }
            if !line.hasPrefix("#") {
                rewritten.append(try resource(line, rangeValue: pendingRange, key: false))
                pendingRange = nil; segmentCount += 1; continue
            }
            guard !line.contains("URI="), !line.contains("{$"),
                  !["#EXT-X-CONTENT-STEERING", "#EXT-X-DEFINE", "#EXT-X-GAP", "#EXT-X-PART", "#EXT-X-PRELOAD-HINT", "#EXT-X-SESSION-KEY"].contains(where: { line.hasPrefix($0) }) else {
                throw Failure("playlist 含不支持的内容引导/低延迟/远程引用标签，未伪造完整离线包。")
            }
            let allowed = ["#EXTM3U", "#EXTINF:", "#EXT-X-VERSION:", "#EXT-X-TARGETDURATION:",
                           "#EXT-X-MEDIA-SEQUENCE:", "#EXT-X-DISCONTINUITY-SEQUENCE:",
                           "#EXT-X-DISCONTINUITY", "#EXT-X-ENDLIST", "#EXT-X-PLAYLIST-TYPE:",
                           "#EXT-X-PROGRAM-DATE-TIME:", "#EXT-X-INDEPENDENT-SEGMENTS"]
            if line.hasPrefix("#EXT"), !allowed.contains(where: { line.hasPrefix($0) }) {
                throw Failure("不支持的 HLS 扩展标签；为防丢失离线语义，已拒绝该源。")
            }
            rewritten.append(line)
        }
        guard segmentCount > 0, pendingRange == nil else { throw Failure("playlist 没有完整媒体分片。") }
        var entries: [Entry] = []
        // Bounded three-resource pipeline; no unbounded task allocation or media in RAM.
        try await withThrowingTaskGroup(of: Entry.self) { group in
            var next = 0
            func enqueue(_ resource: Resource) {
                group.addTask {
                    let temp = try await self.fetch(resource.url, range: resource.range)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    let entry = try Self.entry(temp, name: resource.name)
                    if resource.key && entry.bytes != 16 { throw Failure("AES-128 key 必须是 16 字节。") }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temp, to: package.appendingPathComponent(resource.name))
                    return entry
                }
            }
            while next < min(3, resources.count) { enqueue(resources[next]); next += 1 }
            while let entry = try await group.next() {
                entries.append(entry)
                // Until all resources are known/completed the true total size is unknown.
                progress(entries.reduce(0) { $0 + $1.bytes }, nil)
                if next < resources.count { enqueue(resources[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
        let local = package.appendingPathComponent("local.m3u8")
        try (rewritten.joined(separator: "\n") + "\n").write(to: local, atomically: true, encoding: .utf8)
        entries.append(try Self.entry(local, name: "local.m3u8"))
        try JSONEncoder().encode(Receipt(version: 1, files: entries)).write(to: package.appendingPathComponent("receipt.json"), options: .atomic)
        let bytes = entries.reduce(Int64(0)) { $0 + $1.bytes }
        progress(bytes, bytes)
        try Self.validate(local)
        return local
    }
    static func entry(_ url: URL, name: String) throws -> Entry {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(); var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk); bytes += Int64(chunk.count) }
        return Entry(name: name, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func safePackage(_ package: URL) -> Bool {
        let fm = FileManager.default
        guard package.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(package.lastPathComponent).standardizedFileURL.path == package.resolvingSymlinksInPath().standardizedFileURL.path,
              let values = try? package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let children = try? fm.contentsOfDirectory(at: package, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return children.allSatisfy {
            guard let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }
    static func validate(_ local: URL) throws {
        let package = local.deletingLastPathComponent()
        guard local.lastPathComponent == "local.m3u8", safePackage(package) else { throw Failure("离线包路径/文件类型不安全（禁止 symlink）。") }
        let receiptURL = package.appendingPathComponent("receipt.json")
        guard (try receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 16 * 1024 * 1024 else { throw Failure("离线包索引过大。") }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
        var names: Set<String> = []
        guard receipt.version == 1, !receipt.files.isEmpty, receipt.files.count <= 50_001 else { throw Failure("离线包索引无效。") }
        for expected in receipt.files {
            guard expected.name == URL(fileURLWithPath: expected.name).lastPathComponent,
                  !expected.name.contains("/"), !expected.name.contains("\\"), !expected.name.hasPrefix("."),
                  names.insert(expected.name).inserted else { throw Failure("离线包索引含非法/重复路径。") }
            let actual = try entry(package.appendingPathComponent(expected.name), name: expected.name)
            guard actual.bytes > 0, actual.bytes == expected.bytes, actual.sha256 == expected.sha256 else { throw Failure("离线包资源大小/SHA256 校验失败：\(expected.name)。") }
        }
        guard names.contains("local.m3u8") else { throw Failure("离线包缺少 playlist。") }
        let lines = try String(contentsOf: local, encoding: .utf8).components(separatedBy: .newlines)
        guard lines.first == "#EXTM3U", lines.contains("#EXT-X-ENDLIST") else { throw Failure("本地点播索引无效。") }
        for line in lines where !line.isEmpty {
            if !line.hasPrefix("#") { guard names.contains(line) else { throw Failure("本地 playlist 引用缺失或远程资源。") } }
            else if line.contains("URI=") {
                guard line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-MAP:"),
                      let uri = try attributes(line)["URI"], names.contains(uri) else { throw Failure("本地 playlist 属性引用不安全。") }
            }
        }
    }
}

/// A real FFmpeg/IJK prepare probe, separate from Apple's movpkg assetCache check.
final class ForegroundHLSProbe {
    private var player: IJKFFMoviePlayerController?
    private var renderer: IJKSampleBufferView?
    private var observers: [NSObjectProtocol] = []
    private var timeout: DispatchWorkItem?
    private var completion: ((String?) -> Void)?
    func check(_ url: URL, completion: @escaping (String?) -> Void) {
        self.completion = completion
        let options = IJKFFOptions.byDefault()!
        options.showHudView = false
        options.setFormatOptionValue("file,crypto,data", forKey: "protocol_whitelist")
        options.setFormatOptionValue("ALL", forKey: "allowed_extensions")
        let renderer = IJKSampleBufferView(frame: .zero)
        guard let player = IJKSampleBufferView.makePlayer(url: url, options: options, renderer: renderer) else { finish("IJK 无法创建本地 HLS 校验器。"); return }
        self.player = player; self.renderer = renderer
        player.shouldAutoplay = false; player.shouldShowHudView = false; player.setPauseInBackground(true)
        for name in [Notification.Name.IJKMPMediaPlaybackIsPreparedToPlayDidChange, .IJKMPMoviePlayerPlaybackDidFinish] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self = self else { return }
                    if note.name == .IJKMPMediaPlaybackIsPreparedToPlayDidChange { self.finish(nil) }
                    else { self.finish("IJK/FFmpeg 无法打开本地 HLS，未标记下载成功。") }
                }
            })
        }
        let work = DispatchWorkItem { [weak self] in self?.finish("IJK 本地 HLS 校验超时（20秒），未标记完成。") }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
        player.prepareToPlay()
    }
    func cancel() { finish("前台 HLS 校验已取消。") }
    private func finish(_ error: String?) {
        guard let completion = completion else { return }
        self.completion = nil
        timeout?.cancel(); timeout = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        player?.shutdown(); player = nil; renderer = nil
        completion(error)
    }
}
