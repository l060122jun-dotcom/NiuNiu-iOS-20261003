import SwiftUI
import Combine
import Security
import SafariServices
import UIKit

// Contracts below are taken from k3/a.java, h3/k0.java and the Android
// profile/tab/me screens. APIClient returns the data member, not an envelope.
private enum AccountFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

private enum AccountJSON {
    static func object(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw AccountFailure.message("服务器返回的数据格式不正确")
        }
        return object
    }
    static func list(_ value: Any) throws -> [[String: Any]] {
        guard let list = value as? [[String: Any]] else {
            throw AccountFailure.message("服务器返回的列表格式不正确")
        }
        return list
    }
    static func value(_ object: [String: Any], _ path: String) -> Any? {
        var current: Any = object
        for key in path.split(separator: ".") {
            guard let next = (current as? [String: Any])?[String(key)] else { return nil }
            current = next
        }
        return current
    }
    static func text(_ object: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let string = value(object, key) as? String, !string.isEmpty { return string }
            if let number = value(object, key) as? NSNumber { return number.stringValue }
        }
        return ""
    }
    static func integer(_ object: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let number = value(object, key) as? NSNumber { return number.intValue }
            if let string = value(object, key) as? String, let number = Int(string) { return number }
        }
        return nil
    }
    static func flag(_ object: [String: Any], _ key: String) -> Bool? {
        if let number = object[key] as? NSNumber { return number.boolValue }
        if let string = object[key] as? String {
            if ["true", "1"].contains(string.lowercased()) { return true }
            if ["false", "0"].contains(string.lowercased()) { return false }
        }
        return nil
    }
    static func time(_ raw: String) -> String {
        guard let timestamp = Double(raw), timestamp > 0 else { return raw }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }
    static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }
    static func richText(_ value: String) -> AttributedString {
        if value.contains("<"), let data = value.data(using: .utf8),
           let string = try? NSAttributedString(data: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            // Keep paragraphs and links; let SwiftUI use the user's readable theme/font.
            let clean = NSMutableAttributedString(attributedString: string)
            clean.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: clean.length))
            clean.removeAttribute(.font, range: NSRange(location: 0, length: clean.length))
            return AttributedString(clean)
        }
        return AttributedString(value)
    }
}

private enum AccountKeychain {
    private static let service = "niuniu.account.session"
    private static let account = "token"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw AccountFailure.message("无法读取 Keychain 登录凭据（\(status)）")
        }
        return token
    }
    static func write(_ token: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            attributes.forEach { request[$0.key] = $0.value }
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AccountFailure.message("无法保存 Keychain 登录凭据（\(status)），未保存本次登录")
        }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountFailure.message("无法删除 Keychain 登录凭据（\(status)）")
        }
    }
}

@MainActor
public final class AccountStore: ObservableObject {
    public static let shared = AccountStore()
    @Published public private(set) var token: String = ""
    @Published public private(set) var profile: [String: Any] = [:]
    @Published public private(set) var credentialError: String?
    public var isLoggedIn: Bool { !token.isEmpty }
    private init() {
        do { token = try AccountKeychain.read() }
        catch { credentialError = error.localizedDescription }
        APIClient.shared.setToken(token)
    }
    func requireLogin() throws {
        guard isLoggedIn else { throw AccountFailure.message("请先登录账号") }
    }
    func request(_ path: String, params: [String: String] = [:], method: String = "GET",
                 body: [String: Any]? = nil, authenticated: Bool = true) async throws -> Any {
        if authenticated { try requireLogin() }
        let session = token
        let result = try await APIClient.shared.request(path: path, params: params, method: method, body: body)
        if method.uppercased() == "GET" { try Task.checkCancellation() }
        guard session == token else { throw AccountFailure.message("账号已发生变化，请重新加载") }
        // Current APIClient returns an envelope; also support the agreed payload-only
        // contract without mistaking a business model's ordinary fields for an envelope.
        if let envelope = result as? [String: Any], envelope["status"] != nil,
           envelope["msg"] != nil || envelope["data"] != nil {
            guard AccountJSON.integer(envelope, "status") == 0 else {
                throw AccountFailure.message(AccountJSON.text(envelope, "msg").isEmpty ? "服务器拒绝此操作" : AccountJSON.text(envelope, "msg"))
            }
            return envelope["data"] ?? NSNull()
        }
        return result
    }
    func login(phone: String, password: String) async throws {
        try validatePassword(password)
        guard !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccountFailure.message("请输入手机号")
        }
        let value = try await request("login", params: ["u": phone, "p": Crypto.md5(password, uppercase: true)], authenticated: false)
        try acceptLogin(value)
    }
    func register(phone: String, password: String, question: String, answer: String, qq: String) async throws {
        try validatePassword(password)
        guard !phone.isEmpty, !question.isEmpty, !answer.isEmpty else {
            throw AccountFailure.message("请填写手机号、选择密保问题并输入答案")
        }
        let value = try await request("reg", method: "POST", body: ["user_phone": phone,
            "user_pwd": Crypto.md5(password, uppercase: true), "user_question": question,
            "user_answer": answer, "user_qq": qq], authenticated: false)
        try acceptLogin(value)
    }
    private func acceptLogin(_ value: Any) throws {
        let data = try AccountJSON.object(value)
        let newToken = AccountJSON.text(data, "token")
        guard !newToken.isEmpty else { throw AccountFailure.message("登录响应缺少 token，未保存登录") }
        try AccountKeychain.write(newToken)
        token = newToken
        profile = (data["user"] as? [String: Any]) ?? [String: Any]()
        credentialError = nil
        APIClient.shared.setToken(newToken)
    }
    public func refreshProfile() async throws {
        profile = try AccountJSON.object(await request("userinfo"))
    }
    public func logout() throws {
        try AccountKeychain.remove()
        token = ""
        profile = [:]
        credentialError = nil
        APIClient.shared.setToken("")
    }
    func updateProfile(_ changes: [String: String]) async throws {
        guard !changes.isEmpty else { throw AccountFailure.message("没有需要保存的修改") }
        _ = try await request("profile/update", method: "POST", body: changes)
        if changes["user_pwd"] != nil { try logout() }
        else {
            for key in ["user_portrait", "user_nick_name", "user_qq"] {
                if let value = changes[key] { profile[key] = value }
            }
        }
    }
    func updateQuestion(question: String, answer: String) async throws {
        guard !question.isEmpty, !answer.isEmpty else { throw AccountFailure.message("请选择密保问题并填写答案") }
        _ = try await request("userinfo", method: "POST", body: ["user_question": question, "user_answer": answer])
        profile["user_question"] = question
    }
    func cancelAccount(password: String) async throws {
        try validatePassword(password)
        _ = try await request("account/cancel", method: "POST", body: ["user_pwd": Crypto.md5(password, uppercase: true)])
        try logout()
    }
    func validatePassword(_ password: String) throws {
        guard password.count >= 6 else { throw AccountFailure.message("密码不能少于 6 位") }
    }
}

@MainActor
private final class AccountAction: ObservableObject {
    @Published var busy = false
    @Published var notice: String?
    /// Reads wait for the previous operation; cancelled tab/account tasks never take the lock.
    @discardableResult
    func read(_ action: () async throws -> Void) async -> Bool {
        do {
            while busy { try await Task.sleep(nanoseconds: 50_000_000) }
            try Task.checkCancellation()
        } catch { return false }
        return await run(action)
    }
    @discardableResult
    func run(success: String? = nil, _ action: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do { try await action(); if let success = success { notice = success }; return true }
        catch is CancellationError { return false }
        catch { notice = error.localizedDescription; return false }
    }
}

@MainActor
private struct AccountNotice: ViewModifier {
    @ObservedObject var action: AccountAction
    func body(content: Content) -> some View {
        content.disabled(action.busy)
            .overlay { if action.busy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .alert("账号服务", isPresented: Binding(get: { action.notice != nil }, set: { if !$0 { action.notice = nil } })) {
                Button("知道了", role: .cancel) { action.notice = nil }
            } message: { Text(action.notice ?? "") }
    }
}

private struct AccountPasswordField: View {
    let title: String
    @Binding var text: String
    @State private var visible = false
    var body: some View {
        HStack {
            Group {
                if visible { TextField(title, text: $text) }
                else { SecureField(title, text: $text) }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
            }.buttonStyle(.borderless).accessibilityLabel(visible ? "隐藏密码" : "显示密码")
        }
    }
}

private struct AccountAvatar: View {
    let url: String
    var size: CGFloat = 58
    var body: some View {
        AsyncImage(url: AccountJSON.webURL(url)) { image in image.resizable().scaledToFill() } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

@MainActor
public struct AccountCenterView: View {
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var action = AccountAction()
    @State private var confirmLogout = false
    public init() {}
    public var body: some View {
        List {
            Section {
                if account.isLoggedIn {
                    NavigationLink { AccountProfileView() } label: {
                        HStack(spacing: 16) {
                            AccountAvatar(url: AccountJSON.text(account.profile, "user_portrait"))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(AccountJSON.text(account.profile, "user_nick_name").isEmpty ? "我的账号" : AccountJSON.text(account.profile, "user_nick_name")).font(.title3.bold())
                                Text(AccountJSON.text(account.profile, "user_phone")).font(.caption).foregroundStyle(.secondary)
                                Text("账号资料与安全").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8)
                    }
                } else {
                    NavigationLink { LoginView() } label: { Label("登录 / 注册", systemImage: "person.crop.circle.badge.plus").font(.title3.bold()) }
                    Text("游客本地收藏与历史仍独立保留，登录不会覆盖它们。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = account.credentialError { Text(error).foregroundStyle(.red) }
            }
            Section("账号功能") {
                NavigationLink { MemberCenterView() } label: { Label("会员 · 卡密 · 积分商城", systemImage: "crown") }
                NavigationLink { AccountLibraryView() } label: { Label("账号收藏与云历史", systemImage: "cloud") }
                NavigationLink { MessagesView() } label: { Label("公告 / 消息 / 评论 / 通知", systemImage: "bell") }
                NavigationLink { FeedbackView() } label: { Label("反馈建议 / 求片 / 问题", systemImage: "bubble.left.and.text.bubble.right") }
            }
            if account.isLoggedIn {
                Section {
                    Button("刷新账号资料") { Task { await action.run { try await account.refreshProfile() } } }
                    Button("退出登录", role: .destructive) { confirmLogout = true }
                }.disabled(action.busy)
            }
            Section { Text("客户端不展示广告、不调用广告赚积分；会员与积分只显示服务器返回的真实状态。")
                .font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("账号中心")
        .modifier(AccountNotice(action: action))
        .confirmationDialog("退出此账号？本地游客资料不会删除。", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await action.run { try account.logout() } } }
        }
        .task(id: account.token) { if account.isLoggedIn { await action.read { try await account.refreshProfile() } } }
    }
}

@MainActor
public struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var action = AccountAction()
    @State private var registerMode = false
    @State private var phone = ""
    @State private var password = ""
    @State private var question = ""
    @State private var answer = ""
    @State private var qq = ""
    @State private var questions: [String] = []
    public init() {}
    public var body: some View {
        Form {
            Picker("方式", selection: $registerMode) {
                Text("登录").tag(false); Text("注册").tag(true)
            }.pickerStyle(.segmented)
            Section("手机号与密码") {
                TextField("手机号", text: $phone).keyboardType(.phonePad).textContentType(.username)
                AccountPasswordField(title: "密码（至少 6 位）", text: $password)
            }
            if registerMode {
                Section("注册密保") {
                    Picker("密保问题", selection: $question) {
                        Text("请选择").tag("")
                        ForEach(questions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("密保答案", text: $answer).autocorrectionDisabled()
                    TextField("QQ（可选）", text: $qq).keyboardType(.numberPad)
                    if questions.isEmpty {
                        Button("重新获取服务器密保问题") { Task { await loadQuestions() } }
                    }
                }
            }
            Section {
                Button(registerMode ? "注册并登录" : "登录") {
                    Task {
                        let done = await action.run {
                            if registerMode {
                                try await account.register(phone: phone, password: password, question: question, answer: answer, qq: qq)
                            } else { try await account.login(phone: phone, password: password) }
                        }
                        if done { password = ""; answer = ""; dismiss() }
                    }
                }.disabled(action.busy)
                NavigationLink("忘记密码") { AccountForgotPasswordView() }
            }
        }.navigationTitle(registerMode ? "注册" : "登录")
            .modifier(AccountNotice(action: action))
            .task { await loadQuestions() }
    }
    private func loadQuestions() async {
        await action.read {
            let data = try AccountJSON.object(await account.request("config", authenticated: false))
            questions = (data["question_list"] as? [String] ?? []).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if questions.isEmpty { throw AccountFailure.message("服务器没有提供密保问题，无法注册；请重试或反馈") }
        }
    }
}

@MainActor
private struct AccountForgotPasswordView: View {
    @StateObject private var action = AccountAction()
    @State private var phone = ""
    @State private var requestedPhone = ""
    @State private var question: String?
    @State private var answer = ""
    @State private var password = ""
    @State private var confirmReset = false
    var body: some View {
        Form {
            if let question = question {
                Section("第 2 步 · 回答密保并重置") {
                    LabeledContent("手机号", value: requestedPhone)
                    Text(question)
                    TextField("密保答案", text: $answer).autocorrectionDisabled()
                    AccountPasswordField(title: "新密码（至少 6 位）", text: $password)
                    Button("重置密码") { confirmReset = true }.disabled(action.busy)
                    Button("返回第 1 步") { self.question = nil; answer = ""; password = "" }
                }
            } else {
                Section("第 1 步 · 获取密保问题") {
                    TextField("手机号", text: $phone).keyboardType(.phonePad)
                    Button("下一步") {
                        Task { await action.run {
                            guard !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AccountFailure.message("请输入手机号") }
                            let data = try AccountJSON.object(await AccountStore.shared.request("forget", params: ["phone": phone], authenticated: false))
                            let value = AccountJSON.text(data, "user_question")
                            guard !value.isEmpty else { throw AccountFailure.message("账号未提供密保问题，无法继续") }
                            requestedPhone = phone; question = value
                        } }
                    }.disabled(action.busy)
                }
            }
        }.navigationTitle("找回密码").modifier(AccountNotice(action: action))
            .confirmationDialog("确认修改此账号的登录密码？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("确认重置", role: .destructive) {
                    Task { await action.run(success: "密码已重置，请使用新密码登录") {
                        try AccountStore.shared.validatePassword(password)
                        guard !answer.isEmpty else { throw AccountFailure.message("请输入密保答案") }
                        _ = try await AccountStore.shared.request("forget", method: "POST", body: ["user_phone": requestedPhone,
                            "user_answer": answer, "user_pwd": Crypto.md5(password, uppercase: true)], authenticated: false)
                        password = ""; answer = ""; question = nil
                    } }
                }
            }
    }
}

@MainActor
public struct AccountProfileView: View {
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var action = AccountAction()
    @State private var info: [String: Any]?
    @State private var nickname = ""
    @State private var qq = ""
    @State private var avatar = ""
    @State private var password = ""
    @State private var answer = ""
    @State private var cancelPassword = ""
    @State private var avatars: [String] = []
    @State private var showAvatars = false
    @State private var cancelStepOne = false
    @State private var cancelStepTwo = false
    @State private var confirmSave = false
    public init() {}
    public var body: some View {
        Form {
            if !account.isLoggedIn {
                NavigationLink("请先登录以管理账号资料") { LoginView() }
            } else {
                Section("账号") {
                    LabeledContent("手机号", value: AccountJSON.text(account.profile, "user_phone"))
                    LabeledContent("账号 ID", value: AccountJSON.text(account.profile, "user_id"))
                }
                Section("头像 / 昵称 / QQ") {
                    HStack { AccountAvatar(url: avatar); Spacer(); Button("从头像库选择") { Task { await loadAvatars() } } }
                        .disabled(!canEdit("avatar_modify") || action.busy)
                    TextField("昵称（最多 12 字）", text: $nickname).disabled(!canEdit("nickname_modify"))
                    TextField("QQ", text: $qq).keyboardType(.numberPad).disabled(!canEdit("qq_modify"))
                    if info == nil { Text("资料权限尚未获取，不能修改。请刷新重试。").foregroundStyle(.secondary) }
                    else if !canEdit("avatar_modify") || !canEdit("nickname_modify") || !canEdit("qq_modify") {
                        Text("灰色项目是服务器不允许修改的资料，并非本地解锁。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("账号安全") {
                    LabeledContent("当前密保", value: AccountJSON.text(account.profile, "user_question").isEmpty ? "未设置" : AccountJSON.text(account.profile, "user_question"))
                    NavigationLink("设置密保问题与答案") { AccountQuestionView() }
                    AccountPasswordField(title: "新密码（留空不修改）", text: $password)
                    SecureField("当前密保答案（修改密码时必填）", text: $answer)
                    Button("保存资料") { confirmSave = true }.disabled(info == nil || action.busy)
                }
                Section {
                    Button("刷新资料与修改权限") { Task { await load() } }.disabled(action.busy)
                }
                Section("永久注销") {
                    Text("注销会由服务器永久处理账号。需要输入当前密码并经过两次确认；游客本地记录不会自动删除。")
                        .font(.footnote).foregroundStyle(.secondary)
                    AccountPasswordField(title: "当前密码", text: $cancelPassword)
                    Button("注销账号", role: .destructive) { cancelStepOne = true }.disabled(action.busy)
                }
            }
        }.navigationTitle("账号资料").modifier(AccountNotice(action: action))
            .task(id: account.token) {
                info = nil; nickname = ""; qq = ""; avatar = ""; password = ""; answer = ""; cancelPassword = ""
                if account.isLoggedIn { await load() }
            }
            .sheet(isPresented: $showAvatars) {
                NavigationStack {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 18) {
                            ForEach(avatars, id: \.self) { url in
                                Button { avatar = url; showAvatars = false } label: {
                                    AccountAvatar(url: url).overlay { if avatar == url { Circle().stroke(.green, lineWidth: 3) } }
                                }.buttonStyle(.plain).accessibilityLabel("选择服务器头像")
                            }
                        }.padding()
                    }.navigationTitle("头像库").toolbar { Button("取消") { showAvatars = false } }
                }
            }
            .confirmationDialog("确认保存资料？修改密码后必须重新登录。", isPresented: $confirmSave, titleVisibility: .visible) {
                Button("确认保存") { Task { await save() } }
            }
            .confirmationDialog("确定申请永久注销账号？", isPresented: $cancelStepOne, titleVisibility: .visible) {
                Button("继续注销", role: .destructive) { cancelStepTwo = true }
            }
            .alert("最终确认：此操作不可恢复", isPresented: $cancelStepTwo) {
                Button("永久注销", role: .destructive) {
                    Task { await action.run(success: "服务器已完成注销，登录凭据已清除") {
                        try await account.cancelAccount(password: cancelPassword); cancelPassword = ""
                    } }
                }
                Button("保留账号", role: .cancel) { cancelPassword = "" }
            } message: { Text("只有服务器确认成功后才会退出账号。") }
    }
    private func canEdit(_ key: String) -> Bool { (AccountJSON.integer(info ?? [:], key) ?? 0) > 0 }
    private func load() async {
        await action.read {
            try await account.refreshProfile()
            info = nil
            let data = try AccountJSON.object(await account.request("profile/info"))
            info = data
            nickname = AccountJSON.text(data, "user_nick_name")
            if nickname.isEmpty { nickname = AccountJSON.text(account.profile, "user_nick_name") }
            qq = AccountJSON.text(data, "user_qq")
            if qq.isEmpty { qq = AccountJSON.text(account.profile, "user_qq") }
            avatar = AccountJSON.text(data, "user_portrait")
            if avatar.isEmpty { avatar = AccountJSON.text(account.profile, "user_portrait") }
        }
    }
    private func loadAvatars() async {
        await action.read {
            let data = try AccountJSON.object(await account.request("profile/avatar-urls"))
            avatars = (data["avatar_url_list"] as? [String] ?? []).reduce(into: [String]()) {
                if !$1.isEmpty && !$0.contains($1) { $0.append($1) }
            }
            guard !avatars.isEmpty else { throw AccountFailure.message("服务器没有提供头像资源") }
            showAvatars = true
        }
    }
    private func save() async {
        await action.run(success: password.isEmpty ? "资料修改成功" : "密码修改成功，请重新登录") {
            guard let info = info else { throw AccountFailure.message("请先刷新修改权限") }
            var changes: [String: String] = [:]
            let originalNick = AccountJSON.text(info, "user_nick_name").isEmpty ? AccountJSON.text(account.profile, "user_nick_name") : AccountJSON.text(info, "user_nick_name")
            let originalQQ = AccountJSON.text(info, "user_qq").isEmpty ? AccountJSON.text(account.profile, "user_qq") : AccountJSON.text(info, "user_qq")
            let originalAvatar = AccountJSON.text(info, "user_portrait").isEmpty ? AccountJSON.text(account.profile, "user_portrait") : AccountJSON.text(info, "user_portrait")
            let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if nick != originalNick {
                guard canEdit("nickname_modify") else { throw AccountFailure.message("服务器不允许修改昵称") }
                guard !nick.isEmpty, nick.count <= 12 else { throw AccountFailure.message("昵称须为 1–12 字") }
                changes["user_nick_name"] = nick
            }
            if qq != originalQQ {
                guard canEdit("qq_modify") else { throw AccountFailure.message("服务器不允许修改 QQ") }
                changes["user_qq"] = qq.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if avatar != originalAvatar {
                guard canEdit("avatar_modify"), avatars.contains(avatar) else { throw AccountFailure.message("当前头像不在服务器授权头像库中") }
                changes["user_portrait"] = avatar
            }
            if !password.isEmpty {
                let newPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
                try account.validatePassword(newPassword)
                let question = AccountJSON.text(account.profile, "user_question")
                guard !question.isEmpty, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AccountFailure.message("请先设置密保问题并输入当前密保答案")
                }
                changes["user_pwd"] = Crypto.md5(newPassword, uppercase: true)
                changes["user_question"] = question
                changes["user_answer"] = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try await account.updateProfile(changes)
            password = ""; answer = ""
            if account.isLoggedIn {
                // Apply only confirmed submitted fields; the next refresh rechecks server permissions.
                var updated = info
                changes.forEach { updated[$0.key] = $0.value }
                self.info = updated
            }
        }
    }
}

@MainActor
private struct AccountQuestionView: View {
    @StateObject private var action = AccountAction()
    @State private var questions: [String] = []
    @State private var question = ""
    @State private var answer = ""
    @State private var confirm = false
    var body: some View {
        Form {
            Section("密保问题") {
                Picker("选择问题", selection: $question) {
                    Text("请选择").tag("")
                    ForEach(questions, id: \.self) { Text($0).tag($0) }
                }
                SecureField("密保答案", text: $answer)
                Button("保存密保") { confirm = true }.disabled(action.busy || questions.isEmpty)
                Button("重新获取问题") { Task { await load() } }.disabled(action.busy)
            }
        }.navigationTitle("设置密保").modifier(AccountNotice(action: action))
            .task { await load() }
            .confirmationDialog("确认更换账号密保？请牢记答案。", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认保存") { Task { await action.run(success: "密保已保存") {
                    try await AccountStore.shared.updateQuestion(question: question, answer: answer); answer = ""
                } } }
            }
    }
    private func load() async {
        await action.read {
            let data = try AccountJSON.object(await AccountStore.shared.request("config", authenticated: false))
            questions = (data["question_list"] as? [String] ?? []).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            guard !questions.isEmpty else { throw AccountFailure.message("服务器没有提供密保问题") }
        }
    }
}

private struct AccountWebDestination: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct AccountWebView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@MainActor
public struct MemberCenterView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var action = AccountAction()
    @State private var vip: [String: Any]?
    @State private var points: [String: Any]?
    @State private var cardConfig: [String: Any] = [:]
    @State private var code = ""
    @State private var selectedProduct: Int?
    @State private var confirmCard = false
    @State private var confirmPurchase = false
    @State private var web: AccountWebDestination?
    @State private var lastResult: String?
    public init() {}
    private var products: [[String: Any]] { points?["products"] as? [[String: Any]] ?? [] }
    private var product: [String: Any]? { products.first { AccountJSON.integer($0, "id") == selectedProduct } }
    public var body: some View {
        Form {
            if !account.isLoggedIn { Section { NavigationLink("登录后查看真实会员与积分") { LoginView() } } }
            Section("会员状态") {
                if let vip = vip {
                    let remaining = AccountJSON.integer(vip, "vip_remaining_seconds")
                    let member = AccountJSON.flag(vip, "is_vip")
                    if let member = member {
                        Label(member && (remaining.map { $0 < 0 || $0 > 0 } ?? true) ? "会员账号" : "普通账号", systemImage: "crown")
                    } else { Text("服务端未提供会员状态") }
                    let expiry = AccountJSON.text(vip, "vip_expire_at")
                    if let value = Double(expiry), value > 0 { LabeledContent("到期时间", value: AccountJSON.time(expiry)) }
                    if let remaining = remaining, remaining >= 0 { LabeledContent("剩余秒数", value: String(remaining)) }
                    if let adFree = AccountJSON.flag(vip, "vip_ad_free") { LabeledContent("账号免广告权益", value: adFree ? "是" : "否") }
                    if let canAdFree = AccountJSON.flag(vip, "can_ad_free") { LabeledContent("服务端当前免广告权限", value: canAdFree ? "允许" : "不允许") }
                    Text("显示的是服务器账号权益，不会因无广告客户端而伪造会员身份。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else { Text("会员状态尚未获取").foregroundStyle(.secondary) }
            }
            Section(cardConfig["title"] as? String ?? "卡密兑换") {
                TextField(cardConfig["placeholder"] as? String ?? "请输入卡密", text: $code)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("兑换卡密") { confirmCard = true }.disabled(!account.isLoggedIn || action.busy)
                Button("购买卡密") { openBuyURL() }.disabled(action.busy)
                NavigationLink("卡密兑换记录") { AccountRecordsView(kind: .cards) }
            }
            Section("积分商城（不含广告赚积分）") {
                if let balance = AccountJSON.integer(points ?? [:], "balance") {
                    LabeledContent("可用积分", value: String(balance))
                } else { Text("积分余额尚未获取，不显示猜测余额").foregroundStyle(.secondary) }
                if let earned = AccountJSON.integer(points ?? [:], "total_earned") { LabeledContent("累计获得", value: String(earned)) }
                if let spent = AccountJSON.integer(points ?? [:], "total_spent") { LabeledContent("累计消耗", value: String(spent)) }
                ForEach(Array(products.enumerated()), id: \.offset) { _, item in
                    Button {
                        guard let id = AccountJSON.integer(item, "id"), id > 0 else { action.notice = "商品缺少有效 ID"; return }
                        selectedProduct = id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(AccountJSON.text(item, "name").isEmpty ? "积分商品" : AccountJSON.text(item, "name"))
                                Text(AccountJSON.text(item, "remark")).font(.caption).foregroundStyle(.secondary)
                                if let price = AccountJSON.integer(item, "points_price") { Text("\(price) 积分").font(.caption) }
                                if let stock = AccountJSON.integer(item, "remaining_stock"), stock >= 0 { Text("剩余库存 \(stock)").font(.caption) }
                                if AccountJSON.flag(item, "available") == false || AccountJSON.integer(item, "status") != 1 {
                                    Text("暂不可兑换").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if AccountJSON.integer(item, "id") == selectedProduct { Image(systemName: "checkmark.circle.fill") }
                        }
                    }.buttonStyle(.plain)
                }
                if points != nil && products.isEmpty { Text("服务器暂无积分商品") }
                Button("兑换所选商品") { confirmPurchase = true }.disabled(!account.isLoggedIn || action.busy || product == nil)
                NavigationLink("积分流水（收入 / 支出）") { AccountRecordsView(kind: .points) }
                NavigationLink("积分购买记录") { AccountRecordsView(kind: .purchases) }
            }
            if let lastResult = lastResult { Section("服务器确认结果") { Text(lastResult).textSelection(.enabled) } }
            Section { Button("刷新会员 / 积分 / 购买入口") { Task { await load() } }.disabled(action.busy) }
        }.navigationTitle("会员中心").modifier(AccountNotice(action: action))
            .task(id: account.token) {
                vip = nil; points = nil; selectedProduct = nil; lastResult = nil; code = ""
                await load()
            }
            .sheet(item: $web) { AccountWebView(url: $0.url) }
            .confirmationDialog("确认用此卡密兑换到当前账号？", isPresented: $confirmCard, titleVisibility: .visible) {
                Button("确认兑换") {
                    Task {
                        let done = await action.run(success: "服务器已确认卡密兑换") {
                            let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { throw AccountFailure.message("请输入卡密") }
                            let result = try AccountJSON.object(await account.request("card/exchange", method: "POST", body: ["code": value]))
                            lastResult = "兑换天数：\(AccountJSON.text(result, "days"))\n到期时间：\(AccountJSON.time(AccountJSON.text(result, "vip_expire_after")))"
                            code = ""
                        }
                        if done { await load() }
                    }
                }
            }
            .confirmationDialog("确认消耗服务器积分兑换 \(AccountJSON.text(product ?? [:], "name"))？", isPresented: $confirmPurchase, titleVisibility: .visible) {
                Button("确认积分兑换") {
                    Task {
                        let done = await action.run(success: "服务器已确认积分兑换") {
                            guard let product = product, let id = AccountJSON.integer(product, "id"), id > 0,
                                  let price = AccountJSON.integer(product, "points_price"), price >= 0,
                                  let balance = AccountJSON.integer(points ?? [:], "balance") else {
                                throw AccountFailure.message("商品或余额数据不完整，请刷新后重试")
                            }
                            guard AccountJSON.flag(product, "available") != false, AccountJSON.integer(product, "status") == 1 else {
                                throw AccountFailure.message("该商品暂不可兑换")
                            }
                            guard balance >= price else { throw AccountFailure.message("积分不足") }
                            let result = try AccountJSON.object(await account.request("reward/shop/buy", method: "POST", body: ["product_id": id]))
                            lastResult = "商品：\(AccountJSON.text(result, "product_name"))\n实际消耗：\(AccountJSON.text(result, "points_spent"))\n兑换后余额：\(AccountJSON.text(result, "balance_after"))"
                        }
                        if done { await load() }
                    }
                }
            }
    }
    private func openBuyURL() {
        guard let url = AccountJSON.webURL(AccountJSON.text(cardConfig, "buy_url")) else {
            action.notice = "购买卡密地址未配置或不是有效的 HTTP(S) 地址"; return
        }
        if AccountJSON.integer(cardConfig, "card_record_open_type") == 1 {
            openURL(url) { accepted in if !accepted { action.notice = "系统无法打开购买链接" } }
        } else { web = AccountWebDestination(url: url) }
    }
    private func load() async {
        await action.read {
            var errors: [String] = []
            do {
                let config = try AccountJSON.object(await account.request("config", authenticated: false))
                cardConfig = (config["card_exchange_config"] as? [String: Any]) ?? [String: Any]()
            } catch { errors.append("购买配置：\(error.localizedDescription)") }
            if account.isLoggedIn {
                do { vip = try AccountJSON.object(await account.request("vip/status")) }
                catch { vip = nil; errors.append("会员：\(error.localizedDescription)") }
                do { points = try AccountJSON.object(await account.request("reward/points/status")) }
                catch { points = nil; errors.append("积分：\(error.localizedDescription)") }
            }
            if !errors.isEmpty { throw AccountFailure.message(errors.joined(separator: "\n")) }
        }
    }
}

private enum AccountRecordKind {
    case cards, points, purchases
    var title: String {
        switch self { case .cards: return "卡密兑换记录"; case .points: return "积分流水"; case .purchases: return "积分购买记录" }
    }
}

private struct AccountRecord: Identifiable {
    let id: String
    let title: String
    let detail: String
    let time: String
    let timestamp: Double
}

@MainActor
private struct AccountRecordsView: View {
    let kind: AccountRecordKind
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var action = AccountAction()
    @State private var rows: [AccountRecord] = []
    @State private var page = 0
    @State private var more = true
    var body: some View {
        List {
            if !account.isLoggedIn { NavigationLink("请先登录") { LoginView() } }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title).font(.headline)
                    Text(row.detail).font(.subheadline).textSelection(.enabled)
                    Text(row.time).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            if rows.isEmpty && !action.busy { Text("暂无服务器记录").foregroundStyle(.secondary) }
            if more && account.isLoggedIn { Button("加载更多") { Task { await load(reset: false) } }.disabled(action.busy) }
        }.navigationTitle(kind.title).modifier(AccountNotice(action: action))
            .task(id: account.token) {
                rows = []; page = 0; more = true
                if account.isLoggedIn { await load(reset: true) }
            }
            .refreshable { await load(reset: true) }
    }
    private func load(reset: Bool) async {
        await action.read {
            let next = reset ? 1 : page + 1
            let data = try AccountJSON.object(await account.request(kind == .cards ? "card/records" : "reward/points/records",
                params: ["page": String(next), "pageSize": "20"]))
            var items: [AccountRecord] = []
            if kind == .cards {
                let list = data["items"] as? [[String: Any]] ?? []
                items = list.map { item in
                    let code = AccountJSON.text(item, "code")
                    let masked = code.count > 4 ? "••••" + String(code.suffix(4)) : "••••"
                    return AccountRecord(id: "card-" + AccountJSON.text(item, "id"), title: "\(AccountJSON.text(item, "days")) 天会员",
                        detail: "卡密 \(masked)\n\(AccountJSON.text(item, "remark"))\n到期：\(AccountJSON.time(AccountJSON.text(item, "vip_expire_after")))",
                        time: AccountJSON.time(AccountJSON.text(item, "created_at")), timestamp: 0)
                }
                let total = AccountJSON.integer(data, "total")
                more = total.map { next * 20 < $0 } ?? (list.count == 20)
            } else {
                let income = data["earn_records"] as? [[String: Any]] ?? []
                let purchases = data["purchase_records"] as? [[String: Any]] ?? []
                if kind == .points {
                    items += income.map { item in
                        AccountRecord(id: "earn-" + AccountJSON.text(item, "id"), title: "+\(AccountJSON.text(item, "points")) 积分",
                            detail: AccountJSON.text(item, "remark"), time: AccountJSON.time(AccountJSON.text(item, "created_ts")),
                            timestamp: Double(AccountJSON.text(item, "created_ts")) ?? 0)
                    }
                }
                items += purchases.map { item in
                    AccountRecord(id: "buy-" + AccountJSON.text(item, "id"), title: AccountJSON.text(item, "product_name"),
                        detail: "支出 \(AccountJSON.text(item, "points_spent")) 积分 · 余额 \(AccountJSON.text(item, "balance_after"))",
                        time: AccountJSON.time(AccountJSON.text(item, "created_ts")),
                        timestamp: Double(AccountJSON.text(item, "created_ts")) ?? 0)
                }
                more = (kind == .points && income.count == 20) || purchases.count == 20
            }
            if reset { rows = [] }
            for item in items { if !rows.contains(where: { $0.id == item.id }) { rows.append(item) } }
            if kind != .cards { rows.sort { $0.timestamp > $1.timestamp } }
            page = next
        }
    }
}

@MainActor
public struct FeedbackView: View {
    @StateObject private var action = AccountAction()
    @State private var type = "意见建议"
    @State private var message = ""
    @State private var videoID = ""
    public init() {}
    public var body: some View {
        Form {
            Section("反馈类型") {
                Picker("类型", selection: $type) {
                    Text("意见建议").tag("意见建议")
                    Text("求片").tag("求片")
                    Text("反馈问题").tag("反馈问题")
                }.pickerStyle(.segmented)
                TextField("相关视频 ID（可选）", text: $videoID).keyboardType(.numberPad)
            }
            Section(type == "求片" ? "影片名 + 年代 / 主演" : type == "反馈问题" ? "操作步骤 / 页面 / 地区 / 网络" : "详细描述你的建议") {
                TextEditor(text: $message).frame(minHeight: 160)
                Button("提交反馈") {
                    Task { await action.run(success: "服务器已接收反馈，可在消息中查看回复") {
                        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AccountFailure.message("请填写反馈内容") }
                        _ = try await AccountStore.shared.request("message", method: "POST", body: ["vod_id": videoID,
                            "bug_type": type, "message": message], authenticated: false)
                        message = ""
                    } }
                }.disabled(action.busy)
            }
            Section { NavigationLink("查看反馈回复") { MessagesView() } }
        }.navigationTitle("反馈 / 求片").modifier(AccountNotice(action: action))
    }
}

private enum AccountMessageTab: Int, CaseIterable, Identifiable {
    case announcements, messages, comments, notifications
    var id: Int { rawValue }
    var title: String {
        switch self { case .announcements: return "公告"; case .messages: return "消息"; case .comments: return "评论"; case .notifications: return "通知" }
    }
    var path: String {
        switch self { case .announcements: return "sysnotification"; case .messages: return "notification";
        case .comments: return "comment/personal"; case .notifications: return "comment/replies" }
    }
    var readType: String? {
        switch self { case .announcements: return "system"; case .messages: return "message_reply";
        case .comments: return nil; case .notifications: return "comment" }
    }
}

private struct AccountMessage: Identifiable {
    let id: String
    let raw: [String: Any]
    let tab: AccountMessageTab
    init(_ data: [String: Any], tab: AccountMessageTab, offset: Int) {
        self.raw = data; self.tab = tab
        let key = AccountJSON.text(data, "id", "comment_id", "my_comment_id", "reply_id")
        self.id = "\(tab.rawValue)-" + (key.isEmpty ? "row-\(offset)" : key)
    }
    var title: String {
        let name = AccountJSON.text(raw, "title", "vod_name", "video_name", "vod.title", "video.title", "vod.vod_name", "video.vod_name")
        return name.isEmpty ? tab.title : name
    }
    var content: String { AccountJSON.text(raw, "reply_content", "content", "message", "msg", "text", "comment.content", "reply.content") }
    var original: String { AccountJSON.text(raw, "target_content", "my_comment_content", "comment_content", "origin_content", "original_content", "parent_content", "reply_to_content", "source_content") }
    var user: String { AccountJSON.text(raw, "from_user_nick_name", "reply_user_nick_name", "user_nick_name", "nick_name", "nickname", "user.name", "from_user.user_nick_name", "user.user_nick_name", "reply_user.user_nick_name") }
    var videoID: String { AccountJSON.text(raw, "vod_id", "video_id", "vod.vod_id", "video.vod_id", "vod.id", "video.id") }
    var time: String { AccountJSON.time(AccountJSON.text(raw, "created_at", "createdAt", "create_time", "createTime", "created_time", "reply_created_at", "my_comment_created_at", "parent_created_at", "comment_time", "reply_time", "add_time", "time", "timestamp")) }
    var unread: Bool { AccountJSON.integer(raw, "is_unread") == 1 }
    var readID: Int? {
        if tab == .notifications {
            let notification = AccountJSON.integer(raw, "notification_id") ?? 0
            return notification > 0 ? notification : AccountJSON.integer(raw, "reply_id")
        }
        return AccountJSON.integer(raw, "id")
    }
    var deleteID: Int? {
        for key in ["my_comment_id", "comment_id", "id"] {
            if let value = AccountJSON.integer(raw, key), value > 0 { return value }
        }
        return nil
    }
}

@MainActor
public struct MessagesView: View {
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var action = AccountAction()
    @State private var tab = AccountMessageTab.announcements
    @State private var rows: [AccountMessage] = []
    @State private var counts: [String: Any] = [:]
    @State private var page = 0
    @State private var more = true
    @State private var selected: AccountMessage?
    @State private var deleting: AccountMessage?
    @State private var confirmDelete = false
    @State private var confirmRead = false
    public init() {}
    public var body: some View {
        List {
            Section {
                Picker("消息分类", selection: $tab) {
                    ForEach(AccountMessageTab.allCases) { item in Text(tabLabel(item)).tag(item) }
                }.pickerStyle(.segmented)
                if tab != .announcements && !account.isLoggedIn { NavigationLink("登录后查看此列表") { LoginView() } }
            }
            ForEach(rows) { row in
                Button { selected = row } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            if row.unread { Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("未读") }
                            Text(row.title).font(.headline)
                            Spacer()
                            Text(row.time).font(.caption).foregroundStyle(.secondary)
                        }
                        if !row.user.isEmpty { Text(row.user + " " + AccountJSON.text(row.raw, "action_text")).font(.caption) }
                        Text(AccountJSON.richText(AccountJSON.text(row.raw, "intro").isEmpty ? row.content : AccountJSON.text(row.raw, "intro")))
                            .font(.subheadline).lineLimit(4).foregroundStyle(.secondary)
                        if !row.original.isEmpty { Text("原评论：" + row.original).font(.caption).lineLimit(2) }
                    }.padding(.vertical, 5)
                }.buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if tab == .comments {
                            Button("删除", role: .destructive) { deleting = row; confirmDelete = true }
                        }
                    }
            }
            if rows.isEmpty && !action.busy { Text("暂无\(tab.title)或尚未加载").foregroundStyle(.secondary) }
            if more && (tab == .announcements || account.isLoggedIn) {
                Button("加载更多") { Task { await load(reset: false) } }.disabled(action.busy)
            }
        }.navigationTitle("消息中心")
            .toolbar {
                if tab.readType != nil {
                    Button("全部已读") { confirmRead = true }.disabled(action.busy)
                }
            }
            .modifier(AccountNotice(action: action))
            .task(id: "\(account.token)|\(tab.rawValue)") {
                rows = []; page = 0; more = true; counts = [:]
                if tab == .announcements || account.isLoggedIn { await load(reset: true) }
            }
            .refreshable { await load(reset: true) }
            .sheet(item: $selected) { row in
                NavigationStack {
                    AccountMessageDetailView(message: row) { id in
                        if let index = rows.firstIndex(where: { $0.id == id }) {
                            var raw = rows[index].raw; raw["is_unread"] = 0; raw["is_read"] = 1
                            rows[index] = AccountMessage(raw, tab: rows[index].tab, offset: index)
                        }
                        Task { await refreshCounts() }
                    }.toolbar { Button("关闭") { selected = nil } }
                }
            }
            .confirmationDialog("确认删除自己发表的这条评论？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除评论", role: .destructive) {
                    Task { await action.run(success: "服务器已删除评论") {
                        guard let row = deleting, row.tab == .comments, let id = row.deleteID else {
                            throw AccountFailure.message("评论缺少有效 ID，无法删除")
                        }
                        _ = try await account.request("comment/personal", params: ["comment_id": String(id)], method: "DELETE")
                        rows.removeAll { $0.id == row.id }; deleting = nil
                    } }
                }
            }
            .confirmationDialog("将当前\(tab.title)列表全部标记已读？", isPresented: $confirmRead, titleVisibility: .visible) {
                Button("全部已读") {
                    Task { await action.run(success: "服务器已确认全部已读") {
                        let current = tab
                        guard let type = current.readType else { throw AccountFailure.message("个人评论列表没有已读接口") }
                        let response = try await account.request("unread/read", method: "POST", body: ["type": type], authenticated: current != .announcements)
                        if let data = response as? [String: Any], let unread = data["unread"] as? [String: Any] { counts = unread }
                        if current == tab {
                            rows = rows.enumerated().map { index, row in
                                var raw = row.raw; raw["is_unread"] = 0; raw["is_read"] = 1
                                return AccountMessage(raw, tab: current, offset: index)
                            }
                        }
                    } }
                }
            }
    }
    private func tabLabel(_ item: AccountMessageTab) -> String {
        guard let key = item.readType, let count = AccountJSON.integer(counts, key), count > 0 else { return item.title }
        return "\(item.title) \(min(count, 99))"
    }
    private func refreshCounts() async {
        do { counts = try AccountJSON.object(await account.request("unread/count", authenticated: false)) }
        catch { action.notice = "未读计数加载失败：\(error.localizedDescription)" }
    }
    private func load(reset: Bool) async {
        let current = tab
        await action.read {
            guard current == tab else { return }
            let next = reset ? 1 : page + 1
            var params = ["page": String(next)]
            if current == .comments || current == .notifications { params["count"] = "20" }
            let list = try AccountJSON.list(await account.request(current.path, params: params, authenticated: current != .announcements))
            try Task.checkCancellation()
            guard current == tab else { return }
            if reset { rows = [] }
            for item in list {
                let row = AccountMessage(item, tab: current, offset: rows.count)
                if !rows.contains(where: { $0.id == row.id }) { rows.append(row) }
            }
            page = next
            // These list APIs have no total/page-size envelope. An empty page ends pagination.
            more = !list.isEmpty
            await refreshCounts()
        }
    }
}

@MainActor
private struct AccountMessageDetailView: View {
    let message: AccountMessage
    let onRead: (String) -> Void
    @Environment(\.openURL) private var openURL
    @StateObject private var action = AccountAction()
    @State private var detail: [String: Any]?
    @State private var web: AccountWebDestination?
    @State private var read = false
    var body: some View {
        List {
            Section {
                Text(detail.map { AccountJSON.text($0, "title") } ?? message.title).font(.title3.bold())
                Text(message.time).font(.caption).foregroundStyle(.secondary)
                if !message.user.isEmpty { Text(message.user) }
                Text(AccountJSON.richText(detail.map { AccountJSON.text($0, "content") } ?? message.content)).textSelection(.enabled)
                if !message.original.isEmpty { Text("原评论：\n" + message.original).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if !message.videoID.isEmpty, let id = Int(message.videoID), id > 0 {
                Section { NavigationLink("查看相关视频与评论") { DetailView(videoID: message.videoID) } }
            }
            if !AccountJSON.text(message.raw, "more").isEmpty {
                Section { Button("查看详情链接") { openLink() } }
            }
            if message.tab.readType != nil {
                Section {
                    if read { Label("服务器已确认已读", systemImage: "checkmark.circle") }
                    else { Button("标记已读") { Task { await markRead() } }.disabled(action.busy) }
                }
            }
            if message.tab == .announcements {
                Section { Button("从服务器刷新公告详情") { Task { await loadDetail() } }.disabled(action.busy) }
            }
        }.navigationTitle(message.tab.title).modifier(AccountNotice(action: action))
            .sheet(item: $web) { AccountWebView(url: $0.url) }
            .task {
                read = !message.unread && AccountJSON.integer(message.raw, "is_read") == 1
                if message.tab == .announcements { await loadDetail() }
                if message.unread && message.tab.readType != nil { await markRead() }
            }
    }
    private func loadDetail() async {
        await action.read {
            guard let id = AccountJSON.integer(message.raw, "id"), id > 0 else { throw AccountFailure.message("公告缺少有效 ID") }
            detail = try AccountJSON.object(await AccountStore.shared.request("sysnotification/detail", params: ["id": String(id)], authenticated: false))
        }
    }
    private func markRead() async {
        await action.run {
            guard let type = message.tab.readType, let id = message.readID, id > 0 else { throw AccountFailure.message("消息缺少有效的已读 ID") }
            _ = try await AccountStore.shared.request("unread/read-one", method: "POST", body: ["type": type, "id": id], authenticated: message.tab != .announcements)
            read = true; onRead(message.id)
        }
    }
    private func openLink() {
        guard let url = AccountJSON.webURL(AccountJSON.text(message.raw, "more")) else {
            action.notice = "详情链接不是有效的 HTTP(S) 地址，已阻止打开"; return
        }
        if AccountJSON.integer(message.raw, "type") == 0 { web = AccountWebDestination(url: url) }
        else { openURL(url) { accepted in if !accepted { action.notice = "系统无法打开详情链接" } } }
    }
}

private struct AccountLibraryRow: Identifiable {
    let id: String
    let title: String
    let poster: String
    let subtitle: String
    init(favorite data: [String: Any]) {
        id = AccountJSON.text(data, "vod_id")
        title = AccountJSON.text(data, "vod_name")
        poster = AccountJSON.text(data, "vod_pic")
        subtitle = AccountJSON.text(data, "vod_remarks")
    }
    init(history data: [String: Any]) {
        id = AccountJSON.text(data, "vodId")
        title = AccountJSON.text(data, "videoName")
        poster = AccountJSON.text(data, "videoCover")
        let position = AccountJSON.integer(data, "position")
        subtitle = AccountJSON.text(data, "episodeName") + (position.map { " · \($0 / 1000) 秒" } ?? "")
    }
}

@MainActor
public struct AccountLibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var action = AccountAction()
    @State private var historyMode = false
    @State private var categories: [[String: Any]] = []
    @State private var category = ""
    @State private var favorites: [AccountLibraryRow] = []
    @State private var cloud: [[String: Any]] = []
    @State private var page = 0
    @State private var more = true
    @State private var editing = false
    @State private var selected = Set<String>()
    @State private var confirmDelete = false
    @State private var confirmUpload = false
    @State private var confirmDownload = false
    @State private var confirmClearSnapshot = false
    public init() {}
    private var historyRows: [AccountLibraryRow] { cloud.map { AccountLibraryRow(history: $0) }.filter { !$0.id.isEmpty } }
    public var body: some View {
        ScrollViewReader { proxy in
        List {
            Section {
                Picker("账号资料", selection: $historyMode) { Text("账号收藏").tag(false); Text("云历史").tag(true) }.pickerStyle(.segmented).disabled(action.busy)
                if !account.isLoggedIn { NavigationLink("请先登录账号") { LoginView() } }
            }.id("account-library-top")
            if historyMode {
                Section("手动同步") {
                    Text("云历史下载到独立的账号快照，不覆盖游客本地历史。上传会发送当前本地最近 100 条记录；服务端是否合并由真实接口决定。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("手动上传本地历史（\(min(library.history.count, 100)) 条）") { confirmUpload = true }.disabled(!account.isLoggedIn || action.busy)
                    Button("手动下载云历史") { confirmDownload = true }.disabled(!account.isLoggedIn || action.busy)
                    Button("清除本机账号历史快照", role: .destructive) { confirmClearSnapshot = true }.disabled(!account.isLoggedIn || action.busy || cloud.isEmpty)
                }
                Section("账号历史快照") {
                    ForEach(historyRows) { row in NavigationLink { DetailView(videoID: row.id) } label: { libraryRow(row) } }
                    if cloud.isEmpty { Text("暂无快照，请手动下载云历史").foregroundStyle(.secondary) }
                }
            } else {
                Section("收藏分类") {
                    Picker("分类", selection: $category) {
                        Text("全部").tag("")
                        ForEach(Array(categories.enumerated()), id: \.offset) { _, data in
                            Text(AccountJSON.text(data, "type_name")).tag(AccountJSON.text(data, "type_id"))
                        }
                    }
                    if editing {
                        Button(selected.count == favorites.count && !favorites.isEmpty ? "取消全选" : "全选已加载收藏") {
                            selected = selected.count == favorites.count ? [] : Set(favorites.map(\.id))
                        }
                        Button("删除所选 \(selected.count) 项", role: .destructive) { confirmDelete = true }.disabled(selected.isEmpty || action.busy)
                    }
                }
                ForEach(favorites) { row in
                    if editing {
                        Button { if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) } } label: {
                            HStack { Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle"); libraryRow(row) }
                        }.buttonStyle(.plain)
                    } else { NavigationLink { DetailView(videoID: row.id) } label: { libraryRow(row) } }
                }
                if favorites.isEmpty && !action.busy { Text("当前分类暂无账号收藏或尚未加载").foregroundStyle(.secondary) }
                if more && account.isLoggedIn { Button("加载更多收藏") { Task { await loadFavorites(reset: false) } }.disabled(action.busy) }
            }
        }.navigationTitle("账号收藏与历史")
            .toolbar {
                Button("回顶部") { withAnimation { proxy.scrollTo("account-library-top", anchor: .top) } }
                if !historyMode && account.isLoggedIn { Button(editing ? "完成" : "多选") { editing.toggle(); selected = [] }.disabled(action.busy) }
            }
            .modifier(AccountNotice(action: action))
            .task(id: "\(account.token)|\(category)|\(historyMode)") {
                selected = []; favorites = []; cloud = []; page = 0; more = true
                if account.isLoggedIn {
                    await action.read { try await account.refreshProfile(); try Task.checkCancellation(); try loadSnapshot() }
                    if !historyMode { await loadFavorites(reset: true) }
                } else { cloud = []; categories = [] }
            }
            .refreshable { if !historyMode { await loadFavorites(reset: true) } else { await action.read { try loadSnapshot() } } }
            .confirmationDialog("从服务器删除 \(selected.count) 条账号收藏？游客本地收藏不受影响。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("确认删除", role: .destructive) {
                    Task { await action.run(success: "服务器已删除所选收藏") {
                        let ids = selected.compactMap(Int.init)
                        guard !ids.isEmpty, ids.count == selected.count, ids.allSatisfy({ $0 > 0 }) else { throw AccountFailure.message("收藏 ID 无效") }
                        _ = try await account.request("fav", method: "POST", body: ["vod_ids": ids, "opt": "-", "isSelected": false])
                        favorites.removeAll { selected.contains($0.id) }; selected = []
                    } }
                }
            }
            .confirmationDialog("确认上传本地最近 100 条历史到当前账号？不会自动上传，也不会重复重试写请求。", isPresented: $confirmUpload, titleVisibility: .visible) {
                Button("确认上传") { Task { await upload() } }
            }
            .confirmationDialog("确认从服务器下载云历史到独立账号快照？游客本地历史保留不变。", isPresented: $confirmDownload, titleVisibility: .visible) {
                Button("确认下载") { Task { await download() } }
            }
            .confirmationDialog("只删除本机账号快照，不删除服务端或游客历史。", isPresented: $confirmClearSnapshot, titleVisibility: .visible) {
                Button("清除本机快照", role: .destructive) {
                    Task { await action.run(success: "本机账号快照已清除，云端历史未删除") {
                        UserDefaults.standard.removeObject(forKey: try snapshotKey()); cloud = []
                    } }
                }
            }
        }
    }
    private func libraryRow(_ row: AccountLibraryRow) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: AccountJSON.webURL(row.poster)) { image in image.resizable().scaledToFill() } placeholder: {
                Image(systemName: "film").foregroundStyle(.secondary)
            }.frame(width: 52, height: 70).clipped().cornerRadius(6)
            VStack(alignment: .leading, spacing: 6) { Text(row.title); Text(row.subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func snapshotKey() throws -> String {
        try account.requireLogin()
        let id = AccountJSON.text(account.profile, "user_id")
        guard !id.isEmpty else { throw AccountFailure.message("尚未获取账号 ID，不能读写账号快照") }
        return "niuniu.account.history." + Crypto.md5(id)
    }
    private func loadSnapshot() throws {
        guard let data = UserDefaults.standard.data(forKey: try snapshotKey()) else { cloud = []; return }
        cloud = try AccountJSON.list(JSONSerialization.jsonObject(with: data))
    }
    private func loadFavorites(reset: Bool) async {
        let current = category
        await action.read {
            guard current == category, !historyMode else { return }
            if reset {
                categories = try AccountJSON.list(await account.request("types", authenticated: false))
                    .filter { !AccountJSON.text($0, "type_id").isEmpty && !AccountJSON.text($0, "type_name").isEmpty }
            }
            let next = reset ? 1 : page + 1
            let list = try AccountJSON.list(await account.request("fav", params: ["page": String(next), "type_id": current]))
            try Task.checkCancellation()
            guard current == category else { return }
            if reset { favorites = [] }
            for data in list {
                let row = AccountLibraryRow(favorite: data)
                if !row.id.isEmpty && !favorites.contains(where: { $0.id == row.id }) { favorites.append(row) }
            }
            page = next; more = !list.isEmpty
        }
    }
    private func download() async {
        await action.run(success: "云历史已下载到当前账号快照，游客历史未修改") {
            try await account.refreshProfile()
            let key = try snapshotKey()
            let list = try AccountJSON.list(await account.request("history"))
            guard list.allSatisfy({ (AccountJSON.integer($0, "vodId") ?? 0) > 0 }) else { throw AccountFailure.message("云历史格式不完整，未覆盖本机快照") }
            let data = try JSONSerialization.data(withJSONObject: list)
            UserDefaults.standard.set(data, forKey: key); cloud = list
        }
    }
    private func upload() async {
        await action.run(success: "服务器已确认历史上传") {
            try account.requireLogin()
            let source = Array(library.history.prefix(100))
            guard !source.isEmpty else { throw AccountFailure.message("没有可上传的本地历史") }
            var list: [[String: Any]] = []
            for saved in source {
                guard let id = Int(saved.id), id > 0, saved.position.isFinite, saved.position >= 0,
                      saved.position * 1000 <= Double(Int32.max) else { throw AccountFailure.message("本地历史含无效视频 ID 或播放进度，未上传任何条目") }
                // Read the real detail to recover an episode's server index. Never invent
                // an index or duration that SavedVideo does not store.
                let detail = try AccountJSON.object(await account.request("detail", params: ["vod_id": saved.id]))
                guard AccountJSON.integer(detail, "vod_id") == id else { throw AccountFailure.message("历史视频详情 ID 不匹配，未上传") }
                var row: [String: Any] = ["vodId": id, "videoName": saved.title, "videoCover": saved.poster,
                    "insertTime": Int64(saved.updated.timeIntervalSince1970 * 1000), "position": Int(saved.position * 1000)]
                row["remark"] = AccountJSON.text(detail, "vod_remarks")
                if detail["vod_behind"] != nil {
                    row["vod_behind"] = AccountJSON.text(detail, "vod_behind")
                    row["isAdultOnly"] = AccountJSON.text(detail, "vod_behind") == "adult" ? 1 : 0
                }
                guard !saved.source.isEmpty, !saved.episode.isEmpty else {
                    throw AccountFailure.message("《\(saved.title)》缺少本地播放线路或集数，无法生成真实云历史，未上传任何条目")
                }
                if !saved.source.isEmpty && !saved.episode.isEmpty {
                    let sources = detail["sources"] as? [[String: Any]] ?? []
                    guard let videoSource = sources.first(where: { AccountJSON.text($0, "player_id") == saved.source }),
                          let episodes = videoSource["episodes"] as? [[String: Any]] else {
                        throw AccountFailure.message("《\(saved.title)》的播放线路或真实 episode index 不可确认，未上传任何条目")
                    }
                    // Android assigns index from array order, not a server `index` field.
                    let index: Int
                    if let numeric = Int(saved.episode), episodes.indices.contains(numeric) {
                        index = numeric
                    } else {
                        let matches = episodes.indices.filter { AccountJSON.text(episodes[$0], "name") == saved.episode }
                        guard matches.count == 1, let match = matches.first else {
                            throw AccountFailure.message("《\(saved.title)》的旧集名无法唯一匹配，未上传任何条目")
                        }
                        index = match
                    }
                    row["playerId"] = saved.source
                    row["episodeName"] = AccountJSON.text(episodes[index], "name")
                    row["episodeIndex"] = index
                    if let duration = saved.duration {
                        guard duration.isFinite, duration > 0, duration * 1000 <= Double(Int32.max) else {
                            throw AccountFailure.message("《\(saved.title)》的真实时长无效，未上传任何条目")
                        }
                        row["duration"] = Int(duration * 1000)
                    }
                }
                list.append(row)
            }
            _ = try await account.request("history", method: "PUT", body: ["list": list])
        }
    }
}
