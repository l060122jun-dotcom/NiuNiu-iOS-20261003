import SwiftUI
import Combine
import UIKit

// All writes are user initiated; tolerate both the data and envelope client contracts.
@MainActor private enum SocialAPI {
    static func request(path: String, params: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        let accountToken = AccountStore.shared.token
        let result = try await APIClient.shared.request(path: path, params: params, method: method, body: body)
        guard accountToken == AccountStore.shared.token else { throw SocialError.message("账号已发生变化，请重新加载") }
        if let envelope = result as? [String: Any], envelope["status"] != nil, envelope["data"] != nil || envelope["msg"] != nil {
            guard SocialJSON.int(envelope["status"]) == 0 else { throw SocialError.message(SocialJSON.string(envelope["msg"])) }
            return envelope["data"] ?? NSNull()
        }
        return result
    }
}
private enum SocialError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

private enum SocialJSON {
    static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    static func int(_ value: Any?) -> Int { Int(string(value)) ?? 0 }
    static func flag(_ value: Any?) -> Bool {
        ["1", "true", "yes", "y"].contains(string(value).lowercased())
    }
    static func array(_ value: Any) throws -> [[String: Any]] {
        if let value = value as? [[String: Any]] { return value }
        throw SocialError.message("服务端列表格式异常，请重试")
    }
    static func validID(_ value: String) -> Bool { (Int64(value) ?? 0) > 0 }
    static func numberID(_ value: String) throws -> Int64 {
        guard let id = Int64(value), id > 0 else { throw SocialError.message("无有效服务端 ID，不能执行互动") }
        return id
    }
}

// Accept both dictionary and typed profile contracts without depending on account model names.
@MainActor private enum SocialIdentity {
    static var userID: String { findID(AccountStore.shared.profile, depth: 0) }
    static func findID(_ value: Any, depth: Int) -> String {
        guard depth < 4 else { return "" }
        if let dictionary = value as? [String: Any] {
            for key in ["user_id", "id", "userID", "userId"] {
                let id = SocialJSON.string(dictionary[key])
                if !id.isEmpty { return id }
            }
            for key in ["loginUser", "user", "profile"] {
                if let nested = dictionary[key] { let id = findID(nested, depth: depth + 1); if !id.isEmpty { return id } }
            }
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.first.map { findID($0.value, depth: depth + 1) } ?? "" }
        for child in mirror.children where ["id", "userID", "userId", "user_id"].contains(child.label ?? "") {
            let id = SocialJSON.string(child.value)
            if !id.isEmpty { return id }
        }
        return ""
    }
    static func requireLogin() throws {
        guard AccountStore.shared.isLoggedIn else { throw SocialError.message("请先登录后再操作") }
    }
}

private enum SocialSafety {
    // Conservative local display/send guard; it is not a replacement for server moderation.
    static func allowed(_ text: String) -> Bool {
        let normalized = plain(text).lowercased().replacingOccurrences(of: "[\\s\\p{Cf}]+", with: "", options: .regularExpression)
        let blocked = ["性交", "口交", "肛交", "阴茎", "阴道", "精液", "裸聊", "裸体", "色情", "约炮", "乱伦", "强奸", "淫荡", "做爱", "porn", "blowjob", "cumshot", "hardcore", "hentai", "nude", "xxx"]
        return !blocked.contains(where: normalized.contains)
    }
    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
    static func urls(_ html: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let url = match.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  allowed(url.absoluteString), seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }
}

private func socialColor(_ hex: String, fallback: Color = .primary) -> Color {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    if value.lowercased().hasPrefix("0x") { value = String(value.dropFirst(2)) }
    guard [6, 8].contains(value.count), let number = UInt64(value, radix: 16) else { return fallback }
    let alpha = value.count == 8 ? Double((number >> 24) & 255) / 255 : 1
    return Color(.sRGB, red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255, opacity: alpha)
}

private struct SocialComment: Identifiable {
    let id: String
    let userID: String
    let name: String
    let avatar: String
    let content: String
    let created: String
    let region: String
    let nicknameColor: String
    let level: String
    let levelBackground: String
    let levelForeground: String
    let vip: Bool
    var likeCount: Int
    var liked: Bool
    var replyCount: Int
    var previews: [SocialComment]
    init(_ data: [String: Any], depth: Int = 0) {
        id = SocialJSON.string(data["id"])
        userID = SocialJSON.string(data["user_id"])
        name = SocialJSON.string(data["user_nick_name"])
        avatar = SocialJSON.string(data["user_portrait"])
        content = SocialJSON.string(data["content"])
        created = SocialJSON.string(data["created_at"])
        region = SocialJSON.string(data["ip_region"])
        nicknameColor = SocialJSON.string(data["nickname_color"])
        level = SocialJSON.string(data["comment_level_name"])
        levelBackground = SocialJSON.string(data["level_bg_color"])
        levelForeground = SocialJSON.string(data["level_text_color"])
        vip = SocialJSON.flag(data["is_vip"])
        likeCount = max(0, SocialJSON.int(data["like_count"]))
        liked = SocialJSON.flag(data["is_liked"])
        replyCount = max(0, SocialJSON.int(data["sub_comment_count"]))
        let raw = (data["first_sub_comment"] as? [[String: Any]]) ?? (data["first_sub_comment"] as? [String: Any]).map { [$0] } ?? []
        previews = depth < 2 ? raw.map { SocialComment($0, depth: depth + 1) }.filter { SocialSafety.allowed($0.content) && SocialSafety.allowed($0.name) && SocialJSON.validID($0.id) } : []
    }
    @MainActor var mine: Bool { !userID.isEmpty && userID == SocialIdentity.userID && AccountStore.shared.isLoggedIn }
}

@MainActor private final class CommentsStore: ObservableObject {
    let videoID: String
    let rootID: String
    @Published var items: [SocialComment] = []
    @Published var order = 0
    @Published var loading = false
    @Published var writing = false
    @Published var error: String?
    @Published var notice: String?
    @Published var hasMore = true
    @Published var total: Int?
    @Published var maxLength = 100
    @Published var parent: SocialComment?
    @Published var parentDeleted = false
    @Published var official = ""
    @Published var officialAvatar = ""
    @Published var busyIDs = Set<String>()
    private var page = 1
    private var generation = 0
    init(videoID: String, parent: SocialComment? = nil) { self.videoID = videoID; self.rootID = parent?.id ?? "0"; self.parent = parent }

    func refresh() async {
        generation += 1
        loading = false
        page = 1
        hasMore = true
        await loadNext(refresh: true)
    }
    func loadNext(refresh: Bool = false) async {
        guard !loading, hasMore else { return }
        loading = true
        error = nil
        let revision = generation
        let requestedPage = page
        let requestedOrder = order
        do {
            _ = try SocialJSON.numberID(videoID)
            let data = try await SocialAPI.request(path: "comment", params: ["vod_id": videoID, "order_type": String(requestedOrder), "count": "20", "page": String(requestedPage), "reply_comment_id": rootID])
            let raw = try SocialJSON.array(data)
            guard revision == generation, !Task.isCancelled else { return }
            let decoded = raw.map { SocialComment($0) }.filter { SocialJSON.validID($0.id) && SocialSafety.allowed($0.content) && SocialSafety.allowed($0.name) }
            var seen = Set(refresh ? [] : items.map(\.id))
            let unique = decoded.filter { seen.insert($0.id).inserted }
            items = refresh ? unique : items + unique
            hasMore = raw.count >= 20
            page = requestedPage + 1
        } catch {
            if revision == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
        if revision == generation { loading = false }
    }
    func configure() async {
        do {
            if let config = try await SocialAPI.request(path: "config") as? [String: Any] {
                let limit = SocialJSON.int(config["comment_max_length"])
                if limit > 0 { maxLength = limit }
                let text = SocialJSON.string(config["default_video_comment"])
                if rootID == "0", SocialSafety.allowed(text) { official = text }
                officialAvatar = SocialJSON.string(config["default_avatar"])
            }
        } catch { notice = "官方提示加载失败，可下拉刷新重试" }
        guard rootID == "0" else { return }
        do { total = SocialJSON.int(try await SocialAPI.request(path: "commentcount", params: ["vod_id": videoID])) }
        catch { /* The primary list remains usable if its independent count fails. */ }
    }
    func send(_ text: String, target: SocialComment?, mention: String, rootOverride: String? = nil) async -> Bool {
        guard !writing else { return false }
        writing = true
        defer { writing = false }
        error = nil
        do {
            try SocialIdentity.requireLogin()
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let counted = !mention.isEmpty && text.hasPrefix(mention) ? String(text.dropFirst(mention.count)) : content
            guard !counted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SocialError.message("请输入评论内容") }
            guard counted.utf16.count <= maxLength else { throw SocialError.message("评论最多 \(maxLength) 字") }
            guard SocialSafety.allowed(content) else { throw SocialError.message("内容不适合展示，请修改后发送") }
            let replyID = rootOverride ?? (rootID != "0" ? rootID : target?.id ?? "0")
            let response = try await SocialAPI.request(path: "comment", method: "POST", body: ["vod_id": try SocialJSON.numberID(videoID), "content": content, "reply_comment_id": Int64(replyID) ?? 0])
            let confirmed = (response as? [String: Any]).map { SocialJSON.validID(SocialJSON.string($0["id"])) } ?? false
            notice = confirmed ? "评论已由服务端确认" : "请求已提交；评论以刷新后的服务端列表为准"
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func like(_ item: SocialComment) async {
        guard !busyIDs.contains(item.id) else { return }
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        do {
            try SocialIdentity.requireLogin()
            let result = try await SocialAPI.request(path: "comment/like", method: "POST", body: ["comment_id": try SocialJSON.numberID(item.id), "liked": item.liked ? 0 : 1])
            guard let data = result as? [String: Any], data["is_liked"] != nil, data["like_count"] != nil else { notice = "点赞已提交，状态以服务端回读为准"; await refresh(); return }
            let resultID = SocialJSON.string(data["comment_id"]).isEmpty ? SocialJSON.string(data["id"]) : SocialJSON.string(data["comment_id"])
            guard resultID.isEmpty || resultID == item.id else { throw SocialError.message("点赞响应 ID 不一致") }
            update(item.id, liked: SocialJSON.flag(data["is_liked"]), count: SocialJSON.int(data["like_count"]))
        } catch { self.error = error.localizedDescription }
    }
    func update(_ id: String, liked: Bool, count: Int) {
        if parent?.id == id { parent?.liked = liked; parent?.likeCount = max(0, count) }
        for index in items.indices {
            if items[index].id == id { items[index].liked = liked; items[index].likeCount = max(0, count) }
            for child in items[index].previews.indices where items[index].previews[child].id == id {
                items[index].previews[child].liked = liked; items[index].previews[child].likeCount = max(0, count)
            }
        }
    }
    func moderate(_ item: SocialComment) async {
        guard !busyIDs.contains(item.id) else { return }
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        do {
            try SocialIdentity.requireLogin()
            let id = try SocialJSON.numberID(item.id)
            if item.mine {
                _ = try await SocialAPI.request(path: "comment/personal", params: ["comment_id": String(id)], method: "DELETE")
                notice = "服务端已确认删除"
                if parent?.id == item.id { parentDeleted = true }
                await refresh()
            } else {
                _ = try await SocialAPI.request(path: "comment/report", method: "POST", body: ["comment_id": id])
                notice = "举报已提交"
            }
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor public struct CommentsView: View {
    let videoID: String
    public init(videoID: String) { self.videoID = videoID }
    public var body: some View { SocialCommentsScreen(videoID: videoID, parent: nil, changed: nil) }
}

private struct CommentComposeTarget: Identifiable {
    let id = UUID()
    let comment: SocialComment?
    let prefix: String
    var rootOverride: String? = nil
}

@MainActor private struct SocialCommentsScreen: View {
    @StateObject private var store: CommentsStore
    private var parent: SocialComment? { store.parent }
    private let changed: (() -> Void)?
    @State private var composer: CommentComposeTarget?
    @State private var detail: SocialComment?
    @State private var confirmation: SocialComment?
    @State private var showConfirmation = false
    @State private var showLogin = false
    @Environment(\.dismiss) private var dismiss
    init(videoID: String, parent: SocialComment?, changed: (() -> Void)?) {
        _store = StateObject(wrappedValue: CommentsStore(videoID: videoID, parent: parent))
        self.changed = changed
    }
    var body: some View {
        VStack(spacing: 0) {
            if parent == nil {
                Picker("评论排序", selection: $store.order) {
                    Text("最新").tag(0); Text("最热").tag(1); Text("最赞").tag(2)
                }.pickerStyle(.segmented).padding()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 1).id("comments-top")
            if let parent { commentRow(parent, isParent: true) }
                        if !store.official.isEmpty { officialCard }
                        if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                        if let error = store.error {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).font(.callout).foregroundStyle(.red)
                                Button("重试加载") { Task { if store.hasMore { await store.loadNext(refresh: store.items.isEmpty) } else { await store.refresh() } } }
                            }
                        }
                        ForEach(store.items) { commentRow($0) }
                        if store.loading { ProgressView().frame(maxWidth: .infinity) }
                        else if store.items.isEmpty && store.error == nil {
                            Label(parent == nil ? "暂无可展示评论，来聊聊观影感受吧" : "暂无可展示回复", systemImage: "text.bubble")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                        if !store.loading && store.hasMore && store.error == nil && !store.items.isEmpty {
                            Button("加载更多") { Task { await store.loadNext() } }.frame(maxWidth: .infinity)
                        }
                        if !store.hasMore && !store.items.isEmpty { Text("已加载全部评论").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                        HStack {
                            Button("刷新") { Task { await store.refresh(); await store.configure() } }
                            Spacer()
                            Button("回到顶部") { withAnimation { proxy.scrollTo("comments-top", anchor: .top) } }
                        }.font(.caption)
                    }.padding(.horizontal).padding(.bottom)
                }
                .refreshable { await store.refresh(); await store.configure() }
            }
            Button { beginCompose(nil, at: false) } label: {
                HStack { Image(systemName: "square.and.pencil"); Text("也来说一句吧…"); Spacer(); Text("发送").bold() }.padding()
            }.background(.thinMaterial)
        }
        .navigationTitle(parent == nil ? "评论\(store.total.map { "（\($0)）" } ?? "")" : "回复详情")
        .task { await store.refresh(); await store.configure() }
        .onChange(of: store.parentDeleted) { deleted in if deleted { changed?(); dismiss() } }
        .onChange(of: store.order) { _ in Task { await store.refresh() } }
        .sheet(item: $composer) { target in
            SocialCommentComposer(store: store, target: target) { changed?() }
        }
        .sheet(item: $detail) { item in
            NavigationStack {
                SocialCommentsScreen(videoID: store.videoID, parent: item) { Task { await store.refresh() } }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { detail = nil } } }
            }
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        .confirmationDialog(confirmation?.mine == true ? "删除后不可恢复，确定删除？" : "确定举报这条评论？", isPresented: $showConfirmation, titleVisibility: .visible) {
            if let item = confirmation {
                Button(item.mine ? "删除评论" : "举报违规评论", role: item.mine ? .destructive : nil) { Task { await store.moderate(item); changed?() } }
            }
            Button("取消", role: .cancel) { confirmation = nil; showConfirmation = false }
        }
    }
    private var officialCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("官方客服", systemImage: "checkmark.seal.fill").font(.subheadline.bold()).foregroundStyle(.tint)
            Text(SocialSafety.plain(store.official)).font(.callout)
            ForEach(SocialSafety.urls(store.official), id: \.absoluteString) { url in
                Link(destination: url) { Label(url.host ?? "官方链接", systemImage: "arrow.up.right.square") }.font(.callout)
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    private func beginCompose(_ item: SocialComment?, at: Bool) {
        guard AccountStore.shared.isLoggedIn else { showLogin = true; return }
        let automaticMention = parent != nil && item?.id != parent?.id
        let prefix = (at || automaticMention) && item != nil ? "@\(item!.name) " : ""
        composer = CommentComposeTarget(comment: item, prefix: prefix)
    }
    @ViewBuilder private func commentRow(_ item: SocialComment, isParent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                // Remote portraits are intentionally not displayed without image moderation.
                Image(systemName: "person.crop.circle.fill").font(.system(size: 32)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.name.isEmpty ? "用户" : item.name).font(.subheadline.bold()).foregroundStyle(socialColor(item.nicknameColor))
                        if item.vip { Text("VIP").font(.caption2.bold()).foregroundStyle(.orange) }
                        if !item.level.isEmpty && SocialSafety.allowed(item.level) {
                            Text(item.level).font(.caption2).foregroundStyle(socialColor(item.levelForeground, fallback: .white))
                                .padding(.horizontal, 5).padding(.vertical, 2).background(socialColor(item.levelBackground, fallback: .accentColor), in: RoundedRectangle(cornerRadius: 4))
                        }
                        if isParent { Text("原评论").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text([item.created, item.region].filter { !$0.isEmpty && SocialSafety.allowed($0) }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("回复") { beginCompose(item, at: false) }
                    Button("@回复") { beginCompose(item, at: true) }
                    Button(item.mine ? "删除" : "举报", role: item.mine ? .destructive : nil) {
                        guard AccountStore.shared.isLoggedIn else { showLogin = true; return }
                        confirmation = item; showConfirmation = true
                    }
                } label: { Image(systemName: "ellipsis").padding(8) }
            }
            Text(item.content).font(.body).textSelection(.enabled)
                .onTapGesture { beginCompose(item, at: false) }
                .contextMenu {
                    Button("回复") { beginCompose(item, at: false) }
                    Button("@回复") { beginCompose(item, at: true) }
                }
            HStack(spacing: 20) {
                Button { beginCompose(item, at: false) } label: { Label("回复", systemImage: "bubble.right") }
                if !isParent && parent == nil {
                    Button { detail = item } label: { Text("\(item.replyCount) 条回复 ›") }
                }
                Spacer()
                Button {
                    guard AccountStore.shared.isLoggedIn else { showLogin = true; return }
                    Task { await store.like(item) }
                } label: { Label(String(item.likeCount), systemImage: item.liked ? "hand.thumbsup.fill" : "hand.thumbsup") }
                .foregroundStyle(item.liked ? Color.accentColor : Color.secondary)
                .disabled(store.busyIDs.contains(item.id))
            }.font(.caption)
            if parent == nil && !item.previews.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.previews) { preview in
                        Button { detail = item } label: {
                            Text("\(preview.name)：\(preview.content)").font(.caption).multilineTextAlignment(.leading).foregroundStyle(.primary)
                        }
                        HStack {
                            Button("@\(preview.name) 回复") {
                                if AccountStore.shared.isLoggedIn {
                                    composer = CommentComposeTarget(comment: preview, prefix: "@\(preview.name) ", rootOverride: item.id)
                                } else { showLogin = true }
                            }
                            Spacer()
                            Button { if AccountStore.shared.isLoggedIn { Task { await store.like(preview) } } else { showLogin = true } } label: {
                                Label(String(preview.likeCount), systemImage: preview.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }.disabled(store.busyIDs.contains(preview.id))
                            Menu {
                                Button(preview.mine ? "删除" : "举报", role: preview.mine ? .destructive : nil) {
                                    guard AccountStore.shared.isLoggedIn else { showLogin = true; return }
                                    confirmation = preview; showConfirmation = true
                                }
                            } label: { Image(systemName: "ellipsis") }
                        }.font(.caption2)
                    }
                    Button("查看全部 \(item.replyCount) 条回复 ›") { detail = item }.font(.caption)
                }.padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
        }
    }
}

@MainActor private struct SocialCommentComposer: View {
    @ObservedObject var store: CommentsStore
    let target: CommentComposeTarget
    let changed: () -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    init(store: CommentsStore, target: CommentComposeTarget, changed: @escaping () -> Void) {
        self.store = store; self.target = target; self.changed = changed
        _text = State(initialValue: target.prefix)
    }
    private var count: Int { (text.hasPrefix(target.prefix) ? String(text.dropFirst(target.prefix.count)) : text).utf16.count }
    var body: some View {
        NavigationStack {
            Form {
                if let target = target.comment { Text("回复 \(target.name)").font(.subheadline).foregroundStyle(.secondary) }
                TextEditor(text: $text).frame(minHeight: 140)
                    Text("\(count)/\(store.maxLength) 字（@前缀不计入字数）").font(.caption).foregroundStyle(count > store.maxLength ? .red : .secondary)
                if let error = store.error { Text(error).foregroundStyle(.red) }
                Text("只展示适合公开讨论的内容；发布结果以服务端审核和回读为准。").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("发表评论")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.writing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.writing ? "发送中…" : "发送") {
                        Task { if await store.send(text, target: target.comment, mention: target.prefix, rootOverride: target.rootOverride) { changed(); dismiss() } }
                    }.disabled(store.writing || count == 0 || count > store.maxLength)
                }
            }
        }.interactiveDismissDisabled(store.writing)
    }
}

public struct DanmakuItem: Identifiable, Equatable {
    public let serverID: String
    public let sourceType: String
    public let userID: String
    public let content: String
    public let color: String
    public let type: String
    public let time: Double
    public fileprivate(set) var liked: Bool
    public fileprivate(set) var likeCount: Int
    public var id: String { sourceType + ":" + serverID }
    public var supportsActions: Bool { SocialJSON.validID(serverID) && !sourceType.isEmpty }
    @MainActor var mine: Bool { !userID.isEmpty && userID == SocialIdentity.userID && AccountStore.shared.isLoggedIn }
    init?(_ data: [String: Any]) {
        serverID = SocialJSON.string(data["id"])
        sourceType = SocialJSON.string(data["source_type"])
        userID = SocialJSON.string(data["user_id"])
        content = SocialJSON.string(data["content"])
        color = SocialJSON.string(data["color"])
        type = SocialJSON.string(data["type"])
        time = Double(SocialJSON.string(data["time"])) ?? -1
        liked = SocialJSON.flag(data["is_liked"])
        likeCount = max(0, SocialJSON.int(data["like_count"]))
        guard SocialJSON.validID(serverID), time.isFinite, time >= 0, !content.isEmpty, SocialSafety.allowed(content), ["right", "top", "bottom"].contains(type) else { return nil }
    }
}

@MainActor public final class DanmakuStore: ObservableObject {
    let videoID: String
    @Published public private(set) var items: [DanmakuItem] = []
    @Published public private(set) var playbackTime: Double = 0
    @Published public private(set) var episode = "0"
    @Published public private(set) var loading = false
    @Published public private(set) var writing = false
    @Published public private(set) var busyIDs = Set<String>()
    @Published public var error: String?
    @Published public var notice: String?
    @Published public var show: Bool { didSet { defaults.set(show, forKey: "social.danmaku.show") } }
    @Published public var font: Double { didSet { defaults.set(font, forKey: "social.danmaku.font") } }
    @Published public var speed: Double { didSet { defaults.set(speed, forKey: "social.danmaku.speed") } }
    @Published public var opacity: Double { didSet { defaults.set(opacity, forKey: "social.danmaku.opacity") } }
    @Published public var range: Double { didSet { defaults.set(range, forKey: "social.danmaku.range") } }
    @Published private(set) var maxLength = 30
    @Published private(set) var official = ""
    private let defaults = UserDefaults.standard
    private var revision = 0
    private var requestTask: Task<Void, Never>?
    private var configTask: Task<Void, Never>?
    private var coveredThrough: Double = -1
    private var exhausted = false
    private var lastFailure: Double?

    public init(videoID: String) {
        self.videoID = videoID
        let defaults = UserDefaults.standard
        show = defaults.object(forKey: "social.danmaku.show") as? Bool ?? true
        font = Self.setting(defaults, "font", fallback: 16, bounds: 10...25)
        speed = Self.setting(defaults, "speed", fallback: 1, bounds: 0.5...2)
        opacity = Self.setting(defaults, "opacity", fallback: 100, bounds: 10...100)
        range = Self.setting(defaults, "range", fallback: 50, bounds: 10...100)
        configTask = Task { [weak self] in await self?.configure() }
    }
    private static func setting(_ defaults: UserDefaults, _ key: String, fallback: Double, bounds: ClosedRange<Double>) -> Double {
        let value = defaults.object(forKey: "social.danmaku." + key) as? Double ?? fallback
        return value.isFinite ? min(bounds.upperBound, max(bounds.lowerBound, value)) : fallback
    }
    var duration: Double { 8 / min(2, max(0.5, speed)) }
    public var overlayItems: [DanmakuItem] { show ? items.filter { $0.time <= playbackTime && playbackTime - $0.time < duration } : [] }
    // Supply real player time frequently (50–100 ms). No wall-clock timer means pause/seek are exact.
    public func updatePlayback(episode: String, time: Double) {
        guard time.isFinite, time >= 0, time < 1_000_000_000, let index = Int(episode), index >= 0 else {
            error = "弹幕需要零基集数 episode_index 与有效播放时间"; return
        }
        let normalized = String(index)
        let switched = normalized != self.episode
        let seeked = time < playbackTime - 0.3 || time > playbackTime + 2
        if switched || seeked {
            revision += 1
            requestTask?.cancel()
            requestTask = nil
            loading = false
            coveredThrough = -1
            exhausted = false
            lastFailure = nil
            if switched { items = [] }
        }
        self.episode = normalized
        playbackTime = time
        guard show, !loading, !exhausted, time > coveredThrough else { return }
        if let lastFailure, Date().timeIntervalSince1970 - lastFailure < 5 { return }
        let start = coveredThrough < 0 ? max(0, Int(time - duration)) : Int(time)
        fetch(start: start, episode: normalized, replace: switched)
    }
    public func retry() {
        lastFailure = nil; exhausted = false
        requestTask?.cancel(); revision += 1; loading = false
        fetch(start: max(0, Int(playbackTime - duration)), episode: episode, replace: false)
    }
    public func stop() {
        revision += 1; requestTask?.cancel(); configTask?.cancel(); requestTask = nil; loading = false
    }
    private func configure() async {
        do {
            if let config = try await SocialAPI.request(path: "config") as? [String: Any] {
                let limit = SocialJSON.int(config["danmu_max_length"])
                if limit > 0 { maxLength = limit }
                let content = SocialJSON.string(config["default_video_newdanmu"])
                if SocialSafety.allowed(content) { official = content }
            }
        } catch { /* Config is optional; documented Android fallback is 30 UTF-16 units. */ }
    }
    private func fetch(start: Int, episode: String, replace: Bool) {
        loading = true
        let generation = revision
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try SocialJSON.numberID(videoID)
                let result = try await SocialAPI.request(path: "danmaku", params: ["vod_id": videoID, "episode_index": episode, "startTime": String(start)])
                let raw = try SocialJSON.array(result)
                guard generation == revision, self.episode == episode, !Task.isCancelled else { return }
                let parsed = raw.compactMap(DanmakuItem.init)
                var keyed = Dictionary(uniqueKeysWithValues: (replace ? [] : items).map { ($0.id, $0) })
                for item in parsed { keyed[item.id] = item }
                items = keyed.values.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
                // Follow Android's cursor contract: the server's last returned time controls the next fetch.
                let last = raw.compactMap { Double(SocialJSON.string($0["time"])) }.filter { $0.isFinite }.max()
                coveredThrough = last.map { max(Double(start) + 5, $0) } ?? Double(start) + 5
                exhausted = raw.isEmpty
                error = nil
                lastFailure = nil
                if items.count > 5000 { items = items.filter { abs($0.time - playbackTime) < 300 } }
            } catch {
                if generation == revision, !Task.isCancelled { self.error = error.localizedDescription; lastFailure = Date().timeIntervalSince1970 }
            }
            if generation == revision { loading = false; requestTask = nil }
        }
    }
    public func send(text: String, color: String, type: String, episode: String, time: Double) async -> Bool {
        guard !writing else { return false }
        writing = true
        defer { writing = false }
        do {
            try SocialIdentity.requireLogin()
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.utf16.count <= maxLength else { throw SocialError.message("弹幕须为 1–\(maxLength) 字") }
            guard SocialSafety.allowed(content) else { throw SocialError.message("内容不适合展示，请修改后发送") }
            guard let index = Int(episode), index >= 0, time.isFinite, time >= 0, time < 1_000_000_000, ["right", "top", "bottom"].contains(type) else { throw SocialError.message("集数、时间或弹幕类型无效") }
            guard Self.colors.contains(color.uppercased()) else { throw SocialError.message("请选择有效弹幕颜色") }
            var body: [String: Any] = ["vod_id": try SocialJSON.numberID(videoID), "episode_index": index, "type": type, "color": color.uppercased(), "content": content, "time": max(1, Int(time))]
            let userID = SocialIdentity.userID
            if !userID.isEmpty { body["user_id"] = userID }
            _ = try await SocialAPI.request(path: "danmaku", method: "POST", body: body)
            notice = "请求已提交；弹幕以服务端列表回读为准，审核期间可能暂不可见"
            // Deliberately never construct an item from the submitted text or a fabricated ID.
            if self.episode == String(index) { retry() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    public func like(_ item: DanmakuItem) async {
        guard !busyIDs.contains(item.id) else { return }
        busyIDs.insert(item.id); defer { busyIDs.remove(item.id) }
        do {
            try SocialIdentity.requireLogin()
            guard item.supportsActions else { throw SocialError.message("服务端未提供互动 ID/source_type") }
            let result = try await SocialAPI.request(path: "danmaku/like", method: "POST", body: ["danmu_id": try SocialJSON.numberID(item.serverID), "source_type": item.sourceType, "liked": item.liked ? 0 : 1])
            guard let data = result as? [String: Any], data["is_liked"] != nil, data["like_count"] != nil else { retry(); return }
            let returnedID = SocialJSON.string(data["danmu_id"]).isEmpty ? SocialJSON.string(data["id"]) : SocialJSON.string(data["danmu_id"])
            let returnedSource = SocialJSON.string(data["source_type"])
            guard (returnedID.isEmpty || returnedID == item.serverID), (returnedSource.isEmpty || returnedSource == item.sourceType) else { throw SocialError.message("点赞响应 ID/source_type 不一致") }
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].liked = SocialJSON.flag(data["is_liked"]); items[index].likeCount = max(0, SocialJSON.int(data["like_count"])) }
        } catch { self.error = error.localizedDescription }
    }
    public func delete(_ item: DanmakuItem) async {
        await moderate(item, delete: true)
    }
    public func report(_ item: DanmakuItem) async {
        await moderate(item, delete: false)
    }
    private func moderate(_ item: DanmakuItem, delete: Bool) async {
        guard !busyIDs.contains(item.id) else { return }
        busyIDs.insert(item.id); defer { busyIDs.remove(item.id) }
        do {
            try SocialIdentity.requireLogin()
            guard item.supportsActions else { throw SocialError.message("该弹幕暂无真实互动标识") }
            guard !delete || item.mine else { throw SocialError.message("只能删除本人的弹幕") }
            let id = try SocialJSON.numberID(item.serverID)
            if delete {
                _ = try await SocialAPI.request(path: "danmaku", params: ["danmu_id": String(id)], method: "DELETE")
                items.removeAll { $0.id == item.id }
                notice = "服务端已确认删除弹幕"
            } else {
                _ = try await SocialAPI.request(path: "danmaku/report", method: "POST", body: ["danmu_id": id])
                notice = "举报已提交"
            }
        } catch { self.error = error.localizedDescription }
    }
    func resetSettings() { show = true; font = 16; speed = 1; opacity = 100; range = 50 }
    static let colors = ["#FFFFFF", "#F2001D", "#FF6A00", "#F4B400", "#5CD600", "#48D1B7", "#35BCEB", "#1296F3", "#5B35F5", "#B821D9"]
    deinit { requestTask?.cancel(); configTask?.cancel() }
}

private struct DanmakuPlacement: Identifiable {
    let item: DanmakuItem
    let point: CGPoint
    var id: String { item.id }
}

@MainActor public struct DanmakuOverlay: View {
    @ObservedObject var store: DanmakuStore
    @State private var selected: DanmakuItem?
    @State private var confirm = false
    @State private var showLogin = false
    public init(store: DanmakuStore) { self.store = store }
    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if store.show {
                    ForEach(placements(size: geometry.size)) { placement in
                        Text(placement.item.content + (placement.item.likeCount > 0 ? " ♥\(placement.item.likeCount)" : ""))
                            .font(.system(size: CGFloat(min(25, max(10, store.font))), weight: .semibold))
                            .foregroundStyle(socialColor(placement.item.color, fallback: .white))
                            .shadow(color: .black, radius: 1, x: 1, y: 1)
                            .fixedSize().padding(.horizontal, 3)
                            .background(placement.item.mine ? Color.white.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                            .opacity(min(1, max(0.1, store.opacity / 100)))
                            .position(placement.point)
                            .onTapGesture { selected = placement.item }
                            .onLongPressGesture { selected = placement.item }
                            .accessibilityLabel("弹幕 \(placement.item.content)，点击互动")
                    }
                    if let error = store.error {
                        Button { store.retry() } label: { Label("弹幕加载失败，重试", systemImage: "arrow.clockwise").font(.caption2).padding(6).background(.ultraThinMaterial, in: Capsule()) }
                            .accessibilityHint(error).padding(6)
                    }
                }
                if let selected { hover(selected) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        .confirmationDialog(selected?.mine == true ? "删除后不可恢复，确定删除这条弹幕？" : "确定举报这条弹幕？", isPresented: $confirm, titleVisibility: .visible) {
            if let selected {
                Button(selected.mine ? "删除弹幕" : "举报违规弹幕", role: selected.mine ? .destructive : nil) {
                    Task { if selected.mine { await store.delete(selected) } else { await store.report(selected) }; self.selected = nil }
                }
            }
            Button("取消", role: .cancel) { confirm = false }
        }
        .onChange(of: store.episode) { _ in selected = nil }
        .onChange(of: store.show) { value in if !value { selected = nil } }
    }
    private func hover(_ captured: DanmakuItem) -> some View {
        let item = store.items.first(where: { $0.id == captured.id }) ?? captured
        return VStack(alignment: .leading, spacing: 10) {
            HStack { Text(item.content).font(.callout).lineLimit(3); Spacer(); Button { selected = nil } label: { Image(systemName: "xmark.circle.fill") } }
            HStack(spacing: 18) {
                if item.supportsActions {
                    Button {
                        guard AccountStore.shared.isLoggedIn else { showLogin = true; return }
                        Task { await store.like(item) }
                    } label: { Label("\(item.likeCount)", systemImage: item.liked ? "hand.thumbsup.fill" : "hand.thumbsup") }
                    Button(item.mine ? "删除" : "举报") {
                        guard AccountStore.shared.isLoggedIn else { showLogin = true; return }
                        confirm = true
                    }
                } else { Text("来源未提供互动标识，不能点赞或删除").font(.caption) }
            }.font(.caption).disabled(store.busyIDs.contains(item.id))
            if let error = store.error { Text(error).font(.caption2).foregroundStyle(.red) }
            if let notice = store.notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: 320).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(8)
    }
    private func placements(size: CGSize) -> [DanmakuPlacement] {
        guard size.width > 0, size.height > 0 else { return [] }
        let font = min(25, max(10, store.font))
        let lineHeight = CGFloat(font + 10)
        let usable = size.height * CGFloat(min(100, max(10, store.range)) / 100)
        let lanes = max(1, Int(usable / lineHeight))
        var lastByLane: [String: (start: Double, width: CGFloat, type: String)] = [:]
        var result: [DanmakuPlacement] = []
        let duration = store.duration
        // Reconstruct lane state from real timestamps on every seek; never schedule against wall time.
        let candidates = store.items.filter { $0.time <= store.playbackTime && store.playbackTime - $0.time < duration * 2 }
        let mixedBottom = candidates.contains { $0.type == "bottom" } && candidates.contains { $0.type != "bottom" }
        let laneCount = mixedBottom ? max(1, min(lanes, Int(size.height / (lineHeight * 2)))) : lanes
        for item in candidates {
            let text = item.content + (item.likeCount > 0 ? " ♥\(item.likeCount)" : "")
            let width = (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: CGFloat(font), weight: .semibold)]).width + 10
            var available: Int?
            for lane in 0..<laneCount {
                let key = (item.type == "bottom" ? "bottom" : "upper") + ":" + String(lane)
                guard let last = lastByLane[key] else { available = lane; break }
                let elapsed = item.time - last.start
                let clearing = item.type == "right" && last.type == "right" ? duration * Double((last.width + width + 18) / max(1, size.width + last.width)) : duration
                if elapsed >= clearing { available = lane; break }
            }
            guard let lane = available else { continue }
            lastByLane[(item.type == "bottom" ? "bottom" : "upper") + ":" + String(lane)] = (item.time, width, item.type)
            let elapsed = store.playbackTime - item.time
            guard elapsed < duration, result.count < 60 else { continue }
            let x = item.type == "right" ? size.width + width / 2 - CGFloat(elapsed / duration) * (size.width + width) : size.width / 2
            let y = item.type == "bottom" ? size.height - lineHeight * (CGFloat(lane) + 0.5) : lineHeight * (CGFloat(lane) + 0.5)
            result.append(DanmakuPlacement(item: item, point: CGPoint(x: x, y: y)))
        }
        return result
    }
}

@MainActor public struct DanmakuComposer: View {
    @ObservedObject var store: DanmakuStore
    let episode: String
    let time: Double
    @State private var text = ""
    @State private var color = "#FFFFFF"
    @State private var type = "right"
    @State private var login = false
    @State private var sent = false
    @Environment(\.dismiss) private var dismiss
    public init(store: DanmakuStore, episode: String, time: Double) { self.store = store; self.episode = episode; self.time = time }
    public var body: some View {
        NavigationStack {
            Form {
                Section("弹幕内容 · \(time.isFinite ? max(0, Int(min(time, 1_000_000_000))) : 0) 秒") {
                    TextField("聊聊这一刻的观影感受", text: $text, axis: .vertical).lineLimit(2...5)
                    Text("\(text.utf16.count)/\(store.maxLength) 字").font(.caption).foregroundStyle(text.utf16.count > store.maxLength ? .red : .secondary)
                }
                Section("位置") {
                    Picker("位置", selection: $type) { Text("滚动").tag("right"); Text("顶部").tag("top"); Text("底部").tag("bottom") }.pickerStyle(.segmented)
                }
                Section("颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
                        ForEach(DanmakuStore.colors, id: \.self) { value in
                            Button { color = value } label: {
                                Circle().fill(socialColor(value)).frame(width: 32, height: 32)
                                    .overlay(Circle().stroke(color == value ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: color == value ? 3 : 1))
                                    .overlay { if color == value { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(value == "#FFFFFF" ? .black : .white) } }
                            }.buttonStyle(.plain).accessibilityLabel("颜色 \(value)").accessibilityAddTraits(color == value ? .isSelected : [])
                        }
                    }.padding(.vertical, 6)
                    Text(text.isEmpty ? "弹幕预览" : (SocialSafety.allowed(text) ? text : "内容不适合公开展示")).foregroundStyle(socialColor(color)).padding().frame(maxWidth: .infinity).background(.black, in: RoundedRectangle(cornerRadius: 8))
                }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                if sent, let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                if !store.official.isEmpty {
                    Text(SocialSafety.plain(store.official)).font(.caption).foregroundStyle(.secondary)
                    ForEach(SocialSafety.urls(store.official), id: \.absoluteString) { url in
                        Link(url.host ?? "官方链接", destination: url).font(.caption)
                    }
                }
                Text("发送位置取打开编辑器时的播放时间；只有真实服务端 ID 的弹幕才可互动。").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("发送弹幕")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sent ? "完成" : "取消") { dismiss() }.disabled(store.writing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.writing ? "发送中…" : "发送") {
                        guard AccountStore.shared.isLoggedIn else { login = true; return }
                        Task { if await store.send(text: text, color: color, type: type, episode: episode, time: time) { text = ""; sent = true } }
                    }.disabled(store.writing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > store.maxLength)
                }
            }
        }.sheet(isPresented: $login) { LoginView() }.interactiveDismissDisabled(store.writing)
    }
}

@MainActor public struct DanmakuSettingsView: View {
    @ObservedObject var store: DanmakuStore
    public init(store: DanmakuStore) { self.store = store }
    public var body: some View {
        Form {
            Section { Toggle("显示弹幕", isOn: $store.show) }
            Section("显示样式（本机保存）") {
                setting("字号", value: $store.font, bounds: 10...25, step: 1, suffix: " pt")
                setting("速度", value: $store.speed, bounds: 0.5...2, step: 0.1, suffix: "×")
                setting("不透明度", value: $store.opacity, bounds: 10...100, step: 1, suffix: "%")
                setting("显示区域", value: $store.range, bounds: 10...100, step: 1, suffix: "%")
            }
            Section {
                Button("重新加载当前弹幕") { store.retry() }.disabled(store.loading)
                Button("恢复默认样式") { store.resetSettings() }
                if store.loading { ProgressView("加载中…") }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                Text("暂停时弹幕随播放时间冻结；拖动进度后按真实时间重新定位。过滤不适合公开展示的内容。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("弹幕设置")
    }
    private func setting(_ title: String, value: Binding<Double>, bounds: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: step < 1 ? "%.1f" : "%.0f", value.wrappedValue) + suffix).foregroundStyle(.secondary) }
            Slider(value: value, in: bounds, step: step).accessibilityLabel(title)
        }
    }
}
