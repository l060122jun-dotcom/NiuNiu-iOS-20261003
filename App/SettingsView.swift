import SwiftUI
import UIKit

/// SettingActivity: one card, source order, with logout outside the card.
@MainActor
struct SettingsView: View {
    @EnvironmentObject private var catalog: BrowseCatalog
    @ObservedObject private var account = AccountStore.shared
    @AppStorage("niuniu.incognito") private var incognito = false
    @AppStorage(GlassAppearance.storageKey) private var glassOpacity = GlassAppearance.defaultOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var teenMode = APIClient.shared.isTeenModeEnabled
    @State private var serverConfig: [String: Any] = [:]
    @State private var configLoaded = false
    @State private var configError: String?
    @State private var busy = false
    @State private var notice: String?
    @State private var showLogin = false
    @State private var showPassword = false
    @State private var password = ""
    @State private var cacheBytes: Int64 = 0
    @State private var sourceStatus: [String: String] = [:]
    @State private var updateNotice: SettingsUpdate?

    private let sources = [("xm3u8", "牛牛"), ("xiaocao", "小草"), ("hema", "河马")]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    NavigationLink { SettingsNightView() } label: {
                        row("深色模式") { Image(systemName: "chevron.right").font(.system(size: 14)) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("液态玻璃不透明度").font(.system(size: 14, weight: .bold))
                            Spacer()
                            Text("\(Int((GlassAppearance.normalized(glassOpacity) * 100).rounded()))%")
                                .font(.system(size: 15)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { GlassAppearance.normalized(glassOpacity) },
                                              set: { glassOpacity = GlassAppearance.normalized($0) }),
                               in: GlassAppearance.opacityRange, step: 0.01)
                            .accessibilityLabel("液态玻璃不透明度")
                            .accessibilityValue("\(Int((GlassAppearance.normalized(glassOpacity) * 100).rounded()))%")
                        glassPreview
                        Text(reduceTransparency ? "系统已开启降低透明度，玻璃背景始终显示为实色；此设置将在关闭后生效。" : "15% 更通透，100% 为实色背景；即时应用并自动保存，不影响文字和图标。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                    Toggle(isOn: Binding(get: { incognito }, set: { value in
                        incognito = value
                        teenMode = APIClient.shared.isTeenModeEnabled
                        notice = value ? "无痕模式已开启" : "无痕模式已关闭"
                    })) {
                        caption("无痕模式", "默认关闭，开启后关闭APP还你一身清白")
                    }.frame(minHeight: 60)
                    Toggle(isOn: Binding(get: { teenMode }, set: { value in
                        Task { await changeTeenMode(to: value) }
                    })) {
                        caption("青少年模式", "默认开启，关闭后将显示R18内容")
                    }.frame(minHeight: 60)
                    Button { clearCache() } label: {
                        row("清除缓存") { Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)) }
                    }
                    ForEach(sources.indices, id: \.self) { index in
                        let source = sources[index]
                        Button { Task { await clearSource(source.0) } } label: {
                            row("清除\(source.1)播放器缓存") { Text(sourceStatus[source.0] ?? "读取中") }
                        }
                    }
                    Button { Task { await checkVersion() } } label: {
                        row("版本检测") { Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")") }
                    }
                    Button { contact() } label: {
                        row("联系我们") { Text(serverConfig.text("connect_us_content")).multilineTextAlignment(.trailing) }
                    }
                }
                .padding(15)
                .background(BrowseTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .padding(15)
                .disabled(busy)

                if account.isLoggedIn {
                    Button {
                        do { try account.logout(); notice = "已退出登录" }
                        catch { notice = error.localizedDescription }
                    } label: {
                        Text("退出登录").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 40)
                            .background(BrowseTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    }.padding(.horizontal, 73).padding(.top, 12)
                }
                if busy { ProgressView().padding() }
                if let configError {
                    Button { Task { await loadConfig(); await refreshCaches() } } label: {
                        Text("配置加载失败：\(configError)\n点击重试").font(.footnote).foregroundStyle(.secondary)
                    }.padding(15)
                }
            }
        }
        .buttonStyle(.plain)
        .background(BrowseTheme.background)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            teenMode = APIClient.shared.isTeenModeEnabled
            await refreshCaches()
            await loadConfig()
        }
        .sheet(isPresented: $showLogin) {
            NavigationStack { LoginView().toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { showLogin = false }
            } } }
        }
        .sheet(item: $updateNotice) { update in SettingsUpdateView(update: update) }
        .alert("设置", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .alert("请输入口令", isPresented: $showPassword) {
            SecureField("口令", text: $password)
            Button("确定") { Task { await validatePassword() } }
            Button("取消", role: .cancel) { password = "" }
        } message: { Text("关闭青少年模式需要验证服务端配置的口令") }
    }

    private var glassPreview: some View {
        ZStack {
            // High-contrast source detail makes transparency changes visible even
            // when the rest of Settings sits on a uniform background.
            LinearGradient(colors: [.blue, .purple, .orange], startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 18) {
                ForEach(0..<8, id: \.self) { _ in
                    Rectangle().fill(Color.white.opacity(0.6)).frame(width: 8)
                }
            }.rotationEffect(.degrees(20)).accessibilityHidden(true)
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("玻璃实时预览").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 20).frame(height: 44)
            .liuyunGlass(in: Capsule())
        }
        .frame(height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("玻璃实时预览，文字和图标保持不透明")
    }

    private func caption(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func row<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 14, weight: .bold)).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 5)
            accessory().font(.system(size: 15)).foregroundStyle(.secondary)
        }.frame(minHeight: 60).contentShape(Rectangle())
    }

    private func loadConfig() async {
        do { serverConfig = try await APIClient.shared.configuration(); configLoaded = true; configError = nil }
        catch { configError = error.localizedDescription }
    }

    private func changeTeenMode(to enabled: Bool) async {
        guard !busy else { return }
        if enabled { await applyTeenMode(true); return }
        guard account.isLoggedIn else { showLogin = true; return }
        busy = true
        defer { busy = false }
        do {
            // Never interpret a failed/malformed config as an empty password list.
            serverConfig = try await APIClient.shared.configuration()
            configLoaded = true
            guard account.isLoggedIn else { showLogin = true; return }
            let passwords = try configuredPasswords()
            if passwords.isEmpty { await applyTeenMode(false) }
            else { password = ""; showPassword = true }
        } catch { notice = error.localizedDescription }
    }

    private func configuredPasswords() throws -> [String] {
        guard let raw = serverConfig["pwd"], !(raw is NSNull) else { return [] }
        guard let values = raw as? [String] else { throw APIError.invalidResponse }
        return values
    }

    private func validatePassword() async {
        guard account.isLoggedIn else { password = ""; showLogin = true; return }
        let entered = password.trimmingCharacters(in: .whitespacesAndNewlines)
        password = ""
        guard !entered.isEmpty else { notice = "口令不能为空"; return }
        busy = true
        defer { busy = false }
        do {
            serverConfig = try await APIClient.shared.configuration()
            // Login can change while the asynchronous configuration request is in flight.
            guard account.isLoggedIn else { showLogin = true; return }
            let values = try configuredPasswords()
            guard values.isEmpty || values.contains(entered) else { notice = "口令不正确"; return }
            await applyTeenMode(false)
        } catch { notice = error.localizedDescription }
    }

    private func applyTeenMode(_ enabled: Bool) async {
        APIClient.shared.setTeenMode(enabled)
        catalog.refreshVisibility()
        teenMode = APIClient.shared.isTeenModeEnabled
        notice = enabled ? "青少年模式已开启" : "青少年模式已关闭"
        // BrowseCatalog has no reload API. Allow an in-flight pre-change load to
        // finish before invoking load(), otherwise its loading guard drops refresh.
        while catalog.loading {
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return }
        }
        await catalog.load()
    }

    private func refreshCaches() async {
        cacheBytes = Int64(URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage)
        for source in sources {
            do {
                sourceStatus[source.0] = try SpecialSourceResolver.shared.cacheStatus(source: source.0)
            } catch { sourceStatus[source.0] = "读取失败：\(error.localizedDescription)" }
        }
    }

    private func clearCache() {
        // AVPlayer does not expose Android's disk video-proxy cache on iOS.
        // Only remove the cache actually owned by this client, never downloads/history.
        URLCache.shared.removeAllCachedResponses()
        cacheBytes = Int64(URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage)
        notice = "图片与请求缓存已清除。iOS 系统播放缓存由 AVPlayer 管理。"
    }

    private func clearSource(_ source: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try SpecialSourceResolver.shared.clearCache(source: source)
            await refreshCaches()
            notice = "播放器缓存已清除"
        } catch {
            await refreshCaches()
            notice = error.localizedDescription
        }
    }

    private func contact() {
        let link = serverConfig.text("connect_us_link")
        let content = serverConfig.text("connect_us_content")
        if !link.isEmpty, let url = URL(string: link), url.scheme != nil {
            UIApplication.shared.open(url) { opened in
                if !opened { Task { @MainActor in copyContact(content) } }
            }
        } else { copyContact(content) }
    }

    private func copyContact(_ content: String) {
        guard !content.isEmpty else { notice = "服务端暂未提供联系方式"; return }
        UIPasteboard.general.string = content
        notice = "联系方式已复制到剪切板"
    }

    private func checkVersion() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            serverConfig = try await APIClient.shared.configuration()
            guard let version = serverConfig["version_check"] as? [String: Any] else {
                notice = "服务端暂未提供版本检测配置"; return
            }
            // SettingActivity compares newest_android to the APK version, not the port's build number.
            let newest = version.text("newest_android")
            let hasNew = try compareVersions(newest, "1.6.2") > 0
            if hasNew, let update = serverConfig["pop_up_update"] as? [String: Any] {
                updateNotice = SettingsUpdate(update)
            } else {
                let message = version.text(hasNew ? "has_new" : "no_new")
                notice = message.isEmpty ? "服务端未提供版本检测结果文案" : message
            }
        } catch { notice = error.localizedDescription }
    }

    private func compareVersions(_ lhs: String, _ rhs: String) throws -> Int {
        let a = lhs.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        let b = rhs.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !a.isEmpty, !b.isEmpty, a.allSatisfy({ $0 != nil && $0! >= 0 }),
              b.allSatisfy({ $0 != nil && $0! >= 0 }) else { throw APIError.invalidResponse }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index]! : 0
            let y = index < b.count ? b[index]! : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}

@MainActor
private struct SettingsNightView: View {
    @AppStorage("niuniu.appearance") private var appearance = "system"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var followsSystem = true
    @State private var dark = false
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 20) {
                    Toggle("跟随系统", isOn: $followsSystem).font(.system(size: 16))
                    Text("开启后，将随系统打开或关闭深色模式").font(.system(size: 15)).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).padding(.vertical, 20)
                    .background(BrowseTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                if !followsSystem {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("手动选择").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 20).padding(.bottom, 10)
                        Toggle("普通模式", isOn: Binding(get: { !dark }, set: { dark = !$0 })).frame(height: 44)
                        Toggle("深色模式", isOn: $dark).frame(height: 44)
                    }.font(.system(size: 14)).padding(.horizontal, 10)
                        .background(BrowseTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(15)
        }.background(BrowseTheme.background)
            .navigationTitle("深色模式").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { confirm = true } } }
            .onAppear { followsSystem = appearance == "system"; dark = appearance == "dark" || (followsSystem && colorScheme == .dark) }
            .alert("应用深色模式设置", isPresented: $confirm) {
                Button("确定") { appearance = followsSystem ? "system" : (dark ? "dark" : "light"); dismiss() }
                Button("取消", role: .cancel) {}
            } message: { Text("iOS 会立即应用新的设置，无需重启 App。") }
    }
}

private struct SettingsUpdate: Identifiable {
    let id = UUID()
    let title: String
    let content: String
    let positive: String
    let negative: String
    let link: String
    let download: String
    init(_ config: [String: Any]) {
        title = config.text("title")
        content = config.text("content")
        positive = config.text("positive")
        negative = config.text("negative")
        link = config.text("url")
        download = config.text("download_url")
    }
}

private struct SettingsUpdateView: View {
    let update: SettingsUpdate
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(update.content)
                    Text("这是 Android 对照版本的更新通知，不能安装到 iOS。").font(.footnote).foregroundStyle(.secondary)
                    Button(update.positive.isEmpty ? "查看更新说明" : update.positive) {
                        // Never redirect an APK download into an iOS installation workflow.
                        guard let url = URL(string: update.link), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                              url.pathExtension.lowercased() != "apk" else {
                            message = update.download.isEmpty ? "服务端未提供可用的更新说明链接" : "服务端提供的是 Android 下载配置，iOS 不支持安装 APK。"
                            return
                        }
                        UIApplication.shared.open(url) { opened in
                            if !opened { Task { @MainActor in message = "无法打开更新说明链接" } }
                        }
                    }
                    Button(update.negative.isEmpty ? "关闭" : update.negative) { dismiss() }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }.padding(20)
            }.navigationTitle(update.title.isEmpty ? "版本更新" : update.title)
        }
    }
}
