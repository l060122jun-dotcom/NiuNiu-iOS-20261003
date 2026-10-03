import Foundation
import UIKit

extension VideoCategory {
    /// Android MainPageTypeExtendModel.isAdultOnly(): exact server metadata match.
    var adultOnly: Bool { filters["version"] == "adult" }

    /// UI-compatible constructor without adding stored properties to Models.swift.
    init(id: String, name: String, filters: [String: String]) {
        self.init(["type_id": id, "type_name": name, "type_extend": filters])
    }
}

enum APIError: LocalizedError {
    case invalidURL, http(Int), business(Int, String), invalidResponse, unsafeCategory
    case parserDisabled, parseFailed(String), configurationUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请求地址无效"
        case .http(let code): return "服务器请求失败（HTTP \(code)）；不会绕过访问验证"
        case .business(let code, let message): return message.isEmpty ? "业务请求失败（\(code)）" : message
        case .invalidResponse: return "服务器返回的数据结构无效"
        case .unsafeCategory: return "该内容所属分类在青少年模式下不可用"
        case .parserDisabled: return "该播放线路已被服务器停用"
        case .parseFailed(let stage): return "播放地址解析失败：\(stage)"
        case .configurationUnavailable: return "动态播放配置不可用，请稍后重试；不会使用内置密钥或绕过验证"
        }
    }
}

@MainActor
final class APIClient {
    static let shared = APIClient()
    private let defaults = UserDefaults.standard
    private let session: URLSession
    private var baseURL: URL
    private let deviceID: String
    private var token = ""
    private var contextRevision: UInt64 = 0

    private func checkContext(_ revision: UInt64) throws {
        try Task.checkCancellation()
        guard revision == contextRevision else { throw CancellationError() }
    }

    private func invalidateContext() {
        contextRevision &+= 1
        runtimeConfig = nil
        configLoadedAt = .distantPast
        categoryCache = nil
        adultCategories = []
        knownVideoCategories = [:]
        episodeCategories = [:]
        SpecialSourceResolver.shared.invalidateContext()
    }
    private var categoryCache: [VideoCategory]?
    private var adultCategories = Set<String>()
    private var knownVideoCategories: [String: String] = [:]
    private var episodeCategories: [String: Set<String>] = [:]
    private(set) var isTeenModeEnabled: Bool
    private var runtimeConfig: [String: Any]?
    private var configLoadedAt = Date.distantPast
    private let discoveries = ["https://nnal.oss-cn-beijing.aliyuncs.com/nn.php", "https://nn-1352193558.cos.ap-guangzhou.myqcloud.com/nn.php"]
    private let threeStepSources = ["pp": "src3", "madou": "src4", "douban": "src5", "juzi": "src6", "shanju": "src8", "ningmeng": "src9", "shizi": "src10", "paopao": "src11", "leidian": "src12"]

    private init() {
        let defaults = UserDefaults.standard
        isTeenModeEnabled = defaults.object(forKey: "api.teenMode") as? Bool ?? true
        let saved = defaults.string(forKey: "api.baseURL") ?? "https://nn.123xiangshang.com:35620/"
        baseURL = URL(string: saved) ?? URL(string: "https://nn.123xiangshang.com:35620/")!
        if let stored = defaults.string(forKey: "api.deviceUUID"), UUID(uuidString: stored) != nil {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: "api.deviceUUID")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func setToken(_ value: String) {
        token = value
        invalidateContext()
    }

    /// Source-equivalent mode state, without adding a UI control. Default is enabled.
    func setTeenMode(_ enabled: Bool) {
        guard isTeenModeEnabled != enabled else { return }
        isTeenModeEnabled = enabled
        defaults.set(enabled, forKey: "api.teenMode")
        invalidateContext()
    }

    private var protocolHeaders: [String: String] {
        ["p": "android", "pkg": "com.qingbian.jz", "v": "1.6.2", "y": isTeenModeEnabled ? "1" : "0", "d": deviceID,
         "t": token, "product": UIDevice.current.model, "os": UIDevice.current.systemVersion]
    }

    /// Public contract: status is validated internally; only the `data` member is returned.
    func request(path: String, params: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        var revision = contextRevision
        try checkContext(revision)
        let url = try makeURL(path: path, params: params)
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let envelope: [String: Any]
        do {
            envelope = try await businessRequest(url: url, method: method, body: data)
        } catch let error as URLError where method.uppercased() == "GET" && [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed].contains(error.code) {
            try checkContext(revision)
            // Never repeat mutations or switch domains in response to an access challenge/business error.
            revision = try await discoverDomain()
            // Only the discovery owner can retry in the newly committed domain context.
            try checkContext(revision)
            envelope = try await businessRequest(url: makeURL(path: path, params: params), method: method, body: data)
        }
        try checkContext(revision)
        return envelope["data"] ?? NSNull()
    }

    private func makeURL(path: String, params: [String: String]) throws -> URL {
        guard !path.contains("://"), let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidURL }
        let order = ["class", "order", "type_id", "area", "year", "state", "wd", "page"]
        let keys = params.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        if !keys.isEmpty {
            components.percentEncodedQuery = keys.map {
                Crypto.androidURIEncode($0) + "=" + Crypto.androidURIEncode(params[$0] ?? "")
            }.joined(separator: "&")
        }
        guard let result = components.url else { throw APIError.invalidURL }
        return result
    }

    private func businessRequest(url: URL, method: String, body: Data?) async throws -> [String: Any] {
        let revision = contextRevision
        let data = try await fetch(url, method: method, headers: protocolHeaders, body: body, contentType: body == nil ? nil : "application/json; charset=UTF-8")
        try checkContext(revision)
        let object = try decodeJSON(data, url: url)
        guard let envelope = object as? [String: Any], let status = integer(envelope["status"]) else { throw APIError.invalidResponse }
        guard status == 0 else { throw APIError.business(status, envelope.text("msg")) }
        return envelope
    }

    private func payload(_ path: String, _ params: [String: String] = [:]) async throws -> Any {
        try await request(path: path, params: params)
    }

    func categories() async throws -> [VideoCategory] {
        let revision = contextRevision
        try checkContext(revision)
        if let categoryCache = categoryCache { return categoryCache }
        guard let rows = try await payload("types") as? [[String: Any]] else { throw APIError.invalidResponse }
        try checkContext(revision)
        // Preserve every server row, name and ordering. Visibility is a separate mode policy.
        let catalog = rows.map { row in
            var row = row
            if let extend = row["type_extend"] as? [String: Any] {
                row["type_extend"] = extend.reduce(into: [String: String]()) { result, item in
                    result[item.key] = extend.text(item.key)
                }
            }
            return VideoCategory(row)
        }
        adultCategories = Set(catalog.filter(\.adultOnly).map(\.id))
        categoryCache = catalog
        return catalog
    }

    private func acceptsCategory(_ category: String?) -> Bool {
        guard isTeenModeEnabled, let category = category, !category.isEmpty else { return true }
        return !adultCategories.contains(category)
    }

    private func safeVideos(_ rows: [[String: Any]], contextCategory: String? = nil) -> [Video] {
        // No content/name whitelist. Missing or unknown classification is retained, like
        // the source; only explicit adult metadata is excluded when teen mode is enabled.
        rows.compactMap { row in
            var row = row
            let videoID = row.text("vod_id")
            let fallback = contextCategory.flatMap { $0.isEmpty ? nil : $0 } ?? knownVideoCategories[videoID]
            if row.text("type_id").isEmpty, let fallback = fallback { row["type_id"] = fallback }
            let category = row.text("type_id")
            let video = Video(row)
            if !category.isEmpty { knownVideoCategories[video.id] = category }
            for source in video.sources {
                for episode in source.episodes where !category.isEmpty {
                    episodeCategories[source.id + "|" + episode.id, default: []].insert(category)
                }
            }
            guard acceptsCategory(contextCategory), acceptsCategory(category) else { return nil }
            return video
        }
    }

    func recommendations() async throws -> [Recommendation] {
        let revision = contextRevision
        _ = try await categories()
        try checkContext(revision)
        guard let rows = try await payload("main") as? [[String: Any]] else { throw APIError.invalidResponse }
        try checkContext(revision)
        return rows.filter { acceptsCategory($0.text("type_id")) }.map {
            Recommendation(id: $0.text("type_id"), title: $0.text("title"), videos: safeVideos($0["list"] as? [[String: Any]] ?? [], contextCategory: $0.text("type_id")))
        }
    }

    private func listOrder(_ order: String) -> String {
        switch order {
        case "time", "最新", "": return "最新"
        case "hits", "最热": return "最热"
        case "score", "评分": return "评分"
        default: return "最新"
        }
    }

    func videos(category: String, page: Int = 1, filters: [String: String] = [:]) async throws -> [Video] {
        let revision = contextRevision
        _ = try await categories()
        try checkContext(revision)
        if !acceptsCategory(category) { return [] }
        let requestedOrder: String = filters["by"] ?? filters["order"] ?? "time"
        var params: [String: String] = [:]
        params["class"] = filters["class"] ?? ""
        params["order"] = listOrder(requestedOrder)
        params["type_id"] = category
        params["area"] = filters["area"] ?? ""
        params["year"] = filters["year"] ?? ""
        params["state"] = filters["state"] ?? ""
        params["wd"] = filters["wd"] ?? ""
        params["page"] = String(max(1, page))
        guard let rows = try await payload("list", params) as? [[String: Any]] else { throw APIError.invalidResponse }
        try checkContext(revision)
        return safeVideos(rows, contextCategory: category)
    }

    func search(query: String, category: String, page: Int = 1) async throws -> [Video] {
        // Empty type_id requests the source's global search: one request per page.
        try await videos(category: category, page: page, filters: ["wd": query])
    }

    func detail(id: String) async throws -> Video {
        let revision = contextRevision
        guard !id.isEmpty else { throw APIError.invalidResponse }
        _ = try await categories()
        try checkContext(revision)
        guard let row = try await payload("detail", ["vod_id": id]) as? [String: Any], row.text("vod_id") == id else { throw APIError.invalidResponse }
        try checkContext(revision)
        guard var video = safeVideos([row], contextCategory: knownVideoCategories[id]).first else { throw APIError.unsafeCategory }
        // Match VideoParser.filterVideoBeanSource: disabled/missing parser entries
        // must not be offered as selectable playback lines.
        let config = try await configuration()
        try checkContext(revision)
        video.sources.removeAll { !sourceEnabled($0.id, config: config) }
        return video
    }

    private func sourceEnabled(_ source: String, config: [String: Any]) -> Bool {
        let special = ["xm3u8": "src1", "hema": "src2", "xiaocao": "src7"]
        if let key = special[source] ?? threeStepSources[source] {
            guard let settings = config[key] as? [String: Any] else { return false }
            return (integer(settings["enable"]) ?? 0) != 0
        }
        guard let parser = (config["parser"] as? [[String: Any]] ?? []).first(where: { $0.text("player_id") == source }) else { return false }
        return (integer(parser["enable"]) ?? 1) == 1
    }

    func rank(category: String, order: String) async throws -> [Video] {
        let revision = contextRevision
        guard !category.isEmpty else { throw APIError.invalidResponse }
        _ = try await categories()
        try checkContext(revision)
        if !acceptsCategory(category) { return [] }
        guard let rows = try await payload("rank", ["type_id": category, "order": order]) as? [[String: Any]] else { throw APIError.invalidResponse }
        try checkContext(revision)
        return safeVideos(rows, contextCategory: category)
    }

    func suggest(keyword: String) async throws -> [String] {
        guard let values = try await payload("suggest", ["keyword": keyword]) as? [String] else { throw APIError.invalidResponse }
        return values
    }

    func related(id: String) async throws -> [Video] {
        let revision = contextRevision
        guard !id.isEmpty else { throw APIError.invalidResponse }
        _ = try await categories()
        try checkContext(revision)
        if !acceptsCategory(knownVideoCategories[id]) { return [] }
        guard let rows = try await payload("recommend", ["vod_id": id]) as? [[String: Any]] else { throw APIError.invalidResponse }
        try checkContext(revision)
        return safeVideos(rows)
    }

    /// No bundled fallback: sensitive configuration remains in memory and comes only from /config.
    func configuration() async throws -> [String: Any] {
        let revision = contextRevision
        try checkContext(revision)
        if let runtimeConfig = runtimeConfig, Date().timeIntervalSince(configLoadedAt) < 300 { return runtimeConfig }
        guard let result = try await payload("config") as? [String: Any] else { throw APIError.configurationUnavailable }
        try checkContext(revision)
        runtimeConfig = result
        configLoadedAt = Date()
        return result
    }

    func resolve(episode: Episode, source: String, purpose: SpecialResolvePurpose = .playback) async throws -> ResolvedVideo {
        let revision = contextRevision
        guard !episode.url.isEmpty else { throw APIError.parseFailed("原始地址为空") }
        _ = try await categories()
        try checkContext(revision)
        let contexts = episodeCategories[source + "|" + episode.id] ?? []
        if !contexts.isEmpty && !contexts.contains(where: { acceptsCategory($0) }) { throw APIError.unsafeCategory }
        let config = try await configuration()
        try checkContext(revision)
        if ["xm3u8", "hema", "xiaocao"].contains(source) {
            let result = try await SpecialSourceResolver.shared.resolve(episode: episode, source: source, config: config, purpose: purpose)
            try checkContext(revision)
            return result
        }
        if let configKey = threeStepSources[source] {
            guard let settings = config[configKey] as? [String: Any] else { throw APIError.configurationUnavailable }
            guard (integer(settings["enable"]) ?? 0) != 0 else { throw APIError.parserDisabled }
            let result = try await resolveThreeStep(original: episode.url, source: source, settings: settings)
            try checkContext(revision)
            return result
        }
        let parser = (config["parser"] as? [[String: Any]] ?? []).first { $0.text("player_id") == source }
        guard let parser = parser else { return try resolved(episode.url) }
        guard (integer(parser["enable"]) ?? 1) == 1 else { throw APIError.parserDisabled }
        let rules = parser.text("no_parse_rule").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if rules.contains(where: { episode.url.contains($0) }) {
            return try resolved(episode.url, headers: headerModels(parser["headers"]))
        }
        var lastError: Error = APIError.parseFailed("主备解析地址为空")
        for (urlKey, headerKey) in [("url", "headers"), ("url2", "headers2")] {
            let format = parser.text(urlKey)
            guard !format.isEmpty else { continue }
            do {
                // Java String.format passes the original URL verbatim, not form-encoded.
                let target = format.replacingOccurrences(of: "%s", with: episode.url)
                let url = try validatedURL(target)
                var headers = protocolHeaders
                headers.merge(headerModels(parser[headerKey])) { _, parserValue in parserValue }
                let data = try await fetch(url, headers: headers)
                try checkContext(revision)
                guard let object = try decodeJSON(data, url: url) as? [String: Any] else { throw APIError.invalidResponse }
                return try resolved(object.text("url"), headers: headerString(object.text("headers")))
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch let error as APIError {
                if case .http(let code) = error, (400..<500).contains(code) { throw error }
                lastError = error
            } catch { lastError = error }
        }
        throw lastError
    }

    private func resolveThreeStep(original: String, source: String, settings: [String: Any]) async throws -> ResolvedVideo {
        let revision = contextRevision
        try checkContext(revision)
        let first = settings.text("yUrl")
        guard !first.isEmpty else { throw APIError.configurationUnavailable }
        let firstModel = try await parserJSON(first + original)
        try checkContext(revision)
        if isForPlay(firstModel) { return try modelResolved(firstModel) }
        let binary = source == "ningmeng"
        let remote = try await remoteRequest(firstModel, binary: binary)
        try checkContext(revision)
        let second = settings.text("eUrl")
        guard !second.isEmpty else { return try defaultResolved(settings) }
        var fields: [String: Any]
        if binary {
            fields = ["nndata": remote.base64EncodedString(), "nnid": Data(original.utf8).base64EncodedString()]
        } else {
            guard let text = String(data: try Crypto.gunzipIfNeeded(remote), encoding: .utf8) else { throw Crypto.Failure.invalidUTF8 }
            guard let trimmed = clip(text, fore: settings.text("qSubstr"), tail: settings.text("hSubstr")) else { return try defaultResolved(settings) }
            fields = ["nndata": trimmed, "nnid": original]
        }
        let secondModel = try await parserJSON(second, body: base64JSON(fields))
        try checkContext(revision)
        if binary {
            if secondModel.text("url").isEmpty { return try defaultResolved(settings) }
            if isForPlay(secondModel) { return try modelResolved(secondModel) }
            let data = try await remoteRequest(secondModel, binary: true)
            try checkContext(revision)
            let encoded = data.base64EncodedString()
            return try await thirdStep(settings, fields: ["nndata": encoded, "nnid": Data(original.utf8).base64EncodedString(), "nndz": encoded])
        }
        guard secondModel.text("code") == "200" else { return try defaultResolved(settings) }
        var stepURL = secondModel.text("url")
        var content = stepURL
        if secondModel.text("type").lowercased() == "m3u8" {
            let headers = headerString(secondModel.text("headers"), lowercase: true)
            let data = try await fetch(validatedURL(stepURL), headers: headers)
            try checkContext(revision)
            guard let text = String(data: try Crypto.gunzipIfNeeded(data), encoding: .utf8) else { throw Crypto.Failure.invalidUTF8 }
            content = text
            if let line = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").first(where: { $0.contains(".m3u8") }) {
                // Mirrors Android's filename replacement, including preserving the original query.
                let noQuery = stepURL.components(separatedBy: "?")[0]
                let filename = (noQuery as NSString).lastPathComponent
                if !filename.isEmpty, let range = stepURL.range(of: filename) {
                    stepURL.replaceSubrange(range, with: line)
                    let child = try await fetch(validatedURL(stepURL), headers: headers)
                    try checkContext(revision)
                    guard let childText = String(data: try Crypto.gunzipIfNeeded(child), encoding: .utf8) else { throw Crypto.Failure.invalidUTF8 }
                    content = childText
                }
            }
        }
        return try await thirdStep(settings, fields: ["nndata": content, "nnid": original, "nndz": stepURL])
    }

    private func thirdStep(_ settings: [String: Any], fields: [String: Any]) async throws -> ResolvedVideo {
        let revision = contextRevision
        try checkContext(revision)
        let target = settings.text("sUrl")
        guard !target.isEmpty else { return try defaultResolved(settings) }
        let model = try await parserJSON(target, body: base64JSON(fields))
        try checkContext(revision)
        guard model.text("code") == "200" else { return try defaultResolved(settings) }
        return try modelResolved(model)
    }

    private func remoteRequest(_ model: [String: Any], binary: Bool) async throws -> Data {
        let get = model.text("get") == "1"
        var body: Data?
        if !get {
            if binary {
                let compact = model.text("body").components(separatedBy: .whitespacesAndNewlines).joined()
                guard let decoded = Data(base64Encoded: compact) else { throw Crypto.Failure.invalidBase64 }
                body = decoded
            } else { body = Data(model.text("body").utf8) }
        }
        return try await fetch(validatedURL(model.text("url")), method: get ? "GET" : "POST", headers: headerString(model.text("headers"), lowercase: true), body: body,
                               contentType: get ? nil : (binary ? "application/octet-stream" : "text/plain; charset=UTF-8"))
    }

    private func parserJSON(_ target: String, body: Data? = nil) async throws -> [String: Any] {
        let revision = contextRevision
        let url = try validatedURL(target)
        // g3.e/g3.f have no Android business headers and use the encoded query for their AES key.
        let data = try await fetch(url, method: body == nil ? "GET" : "POST", body: body, contentType: body == nil ? nil : "text/plain; charset=UTF-8")
        try checkContext(revision)
        guard let model = try decodeJSON(data, url: url, encodedQuery: true) as? [String: Any] else { throw APIError.invalidResponse }
        return model
    }

    private func base64JSON(_ fields: [String: Any]) throws -> Data {
        Data(try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]).base64EncodedString().utf8)
    }
    private func defaultResolved(_ settings: [String: Any]) throws -> ResolvedVideo { try resolved(settings.text("mMp4")) }
    private func modelResolved(_ model: [String: Any]) throws -> ResolvedVideo { try resolved(model.text("url"), headers: headerString(model.text("headers"), lowercase: true)) }
    private func isForPlay(_ model: [String: Any]) -> Bool { ["m3u8", "mp4"].contains(model.text("type").lowercased()) }
    private func resolved(_ target: String, headers: [String: String] = [:]) throws -> ResolvedVideo { ResolvedVideo(url: try validatedURL(target), headers: headers) }
    private func validatedURL(_ target: String) throws -> URL {
        guard let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil else { throw APIError.invalidURL }
        return url
    }
    private func clip(_ text: String, fore: String, tail: String) -> String? {
        if fore.isEmpty && tail.isEmpty { return text }
        guard !fore.isEmpty, !tail.isEmpty, let start = text.range(of: fore), let end = text.range(of: tail, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
    private func headerModels(_ value: Any?) -> [String: String] {
        var result: [String: String] = [:]
        for row in value as? [[String: Any]] ?? [] {
            let key = row.text("key")
            if !key.isEmpty { result[key] = row.text("value") }
        }
        return result
    }
    private func headerString(_ text: String, lowercase: Bool = false) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[lowercase ? key.lowercased() : key] = value
        }
        return result
    }

    private func decodeJSON(_ data: Data, url: URL, encodedQuery: Bool = false) throws -> Any {
        if let object = try? JSONSerialization.jsonObject(with: data) { return object }
        guard let text = String(data: data, encoding: .utf8) else { throw Crypto.Failure.invalidUTF8 }
        // Parent verified g3.c.d in smali: JSONObject succeeds => original JSON;
        // catch_0 => truncated/padded seed and AES; catch_1 => original raw response.
        // iOS throws a typed decode error for malformed ciphertext instead of returning garbage.
        return try JSONSerialization.jsonObject(with: Crypto.decryptBase64(text, key: Crypto.responseKey(for: url, encodedQuery: encodedQuery)))
    }

    private func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, contentType: String? = nil) async throws -> Data {
        let revision = contextRevision
        try checkContext(revision)
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.httpBody = body
        for (key, value) in headers {
            guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else { throw APIError.invalidResponse }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let contentType = contentType, request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try checkContext(revision)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw APIError.http(response.statusCode) }
        guard data.count <= 16 * 1024 * 1024 else { throw APIError.invalidResponse }
        return data
    }

    private func discoverDomain() async throws -> UInt64 {
        let revision = contextRevision
        try checkContext(revision)
        for discovery in discoveries {
            let plain: String
            do {
                let data = try await fetch(validatedURL(discovery), headers: protocolHeaders)
                try checkContext(revision)
                guard let text = String(data: data, encoding: .utf8) else { throw Crypto.Failure.invalidUTF8 }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("http") { plain = text }
                else {
                    let decoded = try Crypto.decryptBase64(text, key: Crypto.paddedSeed("@@bull!!!video$$"))
                    guard let value = String(data: decoded, encoding: .utf8) else { throw Crypto.Failure.invalidUTF8 }
                    plain = value
                }
            } catch let error as APIError {
                if case .http(let code) = error, (400..<500).contains(code) { throw error }
                continue
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { continue }
            for line in plain.components(separatedBy: .newlines) {
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: candidate), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil, let probe = URL(string: "tik", relativeTo: url)?.absoluteURL else { continue }
                do {
                    _ = try await businessRequest(url: probe, method: "GET", body: nil)
                    try checkContext(revision)
                    baseURL = url
                    defaults.set(url.absoluteString, forKey: "api.baseURL")
                    invalidateContext()
                    return contextRevision
                } catch let error as APIError {
                    if case .http(let code) = error, (400..<500).contains(code) { throw error }
                } catch is CancellationError { throw CancellationError() }
                catch let error as URLError where error.code == .cancelled { throw error }
                catch { continue }
            }
        }
        throw URLError(.cannotConnectToHost)
    }
}
