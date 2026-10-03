import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("niuniu.autoNext") private var autoNext = true
    @AppStorage("niuniu.resume") private var resume = true
    @AppStorage("niuniu.skipIntro") private var skipIntro = 0
    @AppStorage("niuniu.appearance") private var appearance = "system"
    @AppStorage("niuniu.incognito") private var incognito = false
    @State private var serverConfig: [String: Any] = [:]
    @State private var configError: String?
    @State private var showLogout = false
    @State private var logoutError: String?
    @State private var confirmClear = false
    @State private var cacheCleared = false

    var body: some View {
        Form {
            Section("播放设置") {
                Toggle("自动播放下一集", isOn: $autoNext)
                Toggle("记住播放位置", isOn: $resume)
                Picker("跳过片头", selection: $skipIntro) {
                    Text("不跳过").tag(0)
                    ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) 秒").tag($0) }
                }
            }
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
            }
            Section("本地数据") {
                Toggle("无痕模式（不记录观看历史）", isOn: $incognito)
                Button("清空搜索记录") { library.clearSearches() }
                Button("清空观看历史", role: .destructive) { confirmClear = true }
                Button(cacheCleared ? "图片与请求缓存已清理" : "清理图片与请求缓存") {
                    URLCache.shared.removeAllCachedResponses()
                    cacheCleared = true
                }
            }
            Section("账号与帮助") {
                NavigationLink("账号与个人信息") { AccountCenterView() }
                NavigationLink("消息与评论") { MessagesView() }
                NavigationLink("意见反馈与求片") { FeedbackView() }
                NavigationLink("会员与兑换") { MemberCenterView() }
                if let url = URL(string: serverConfig.text("connect_us_link")), ["http", "https"].contains(url.scheme ?? "") {
                    Link(serverConfig.text("connect_us_content").isEmpty ? "联系我们" : serverConfig.text("connect_us_content"), destination: url)
                }
                if let configError { Text(configError).font(.footnote).foregroundStyle(.secondary) }
                Button("刷新服务端配置") { Task { await loadConfig() } }
                if AccountStore.shared.isLoggedIn {
                    Button("退出登录", role: .destructive) { showLogout = true }
                }
                if let logoutError { Text(logoutError).foregroundStyle(.red) }
            }
            Section("关于") {
                LabeledContent("应用", value: "牛牛视频 · 无广告移植版")
                LabeledContent("对照版本", value: "Android 1.6.2")
                Text("本版本不集成广告 SDK。收藏与观看记录保存在本机。视频可用性取决于服务端和播放源。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .task { await loadConfig() }
        .confirmationDialog("退出当前账号？", isPresented: $showLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                do { try AccountStore.shared.logout() } catch { logoutError = error.localizedDescription }
            }
        }
        .confirmationDialog("清空所有观看记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空观看历史", role: .destructive) { library.clearHistory() }
        }
    }

    private func loadConfig() async {
        do { serverConfig = try await APIClient.shared.configuration(); configError = nil }
        catch { configError = error.localizedDescription }
    }
}
