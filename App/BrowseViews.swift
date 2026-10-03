import SwiftUI
import UIKit

enum BrowseTheme {
    static let green = Color(red: 151.0 / 255, green: 211.0 / 255, blue: 39.0 / 255)
    // Brand green remains exact on filled controls; links need readable contrast in daylight.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 151.0 / 255, green: 211.0 / 255, blue: 39.0 / 255, alpha: 1)
            : UIColor(red: 0.23, green: 0.38, blue: 0.04, alpha: 1)
    })
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.070, blue: 0.062, alpha: 1)
            : UIColor(red: 0.975, green: 0.970, blue: 0.950, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.125, blue: 0.110, alpha: 1)
            : UIColor(red: 1, green: 0.995, blue: 0.980, alpha: 1)
    })
    static let paleGreen = surface
}

private struct BrowsePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct BrowseScroll<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 1).id("browse.top")
                    content
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                            proxy.scrollTo("browse.top", anchor: .top)
                        }
                    } label: {
                        Label("回到顶部", systemImage: "arrow.up").font(.footnote.weight(.medium))
                            .foregroundStyle(Color.primary).padding(.horizontal, 18).padding(.vertical, 12)
                            .background(BrowseTheme.surface, in: Capsule())
                    }.buttonStyle(BrowsePressStyle()).padding(.vertical, 20)
                }
            }
        }
    }
}

/// Preserve server order; visibility follows the original teen-mode metadata.
@MainActor
final class BrowseCatalog: ObservableObject {
    @Published private(set) var categories: [VideoCategory] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var allCategories: [VideoCategory] = []
    func refreshVisibility() {
        var seen = Set<String>()
        categories = allCategories.filter {
            !$0.id.isEmpty && seen.insert($0.id).inserted
                && (!APIClient.shared.isTeenModeEnabled || !$0.adultOnly)
        }
    }

    nonisolated static func family(_ name: String) -> String? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "电影", "电影片": return "电影"
        case "剧集", "电视剧", "连续剧": return "剧集"
        case "综艺", "综艺片": return "综艺"
        case "动漫", "动画", "动漫片": return "动漫"
        case "短剧", "短剧片": return "短剧"
        case "直播", "电视直播": return "直播"
        default: return nil
        }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response = try await APIClient.shared.categories()
            try Task.checkCancellation()
            allCategories = response
            refreshVisibility()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func category(for recommendation: Recommendation) -> VideoCategory? {
        // The backend's category-linked blocks use category IDs or category names.
        // Unknown promotional/adult blocks are deliberately not displayed.
        categories.first { category in
            recommendation.id == category.id
                || recommendation.title == category.name
                || recommendation.title == Self.family(category.name)
        }
    }

    func accepts(_ recommendation: Recommendation) -> Bool { category(for: recommendation) != nil }
}

@MainActor
private final class VideoPageStore: ObservableObject {
    @Published private(set) var videos: [Video] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = true
    private var page = 0
    private var generation = UUID()
    var needsFirstPage: Bool { page == 0 && error == nil && hasMore }

    func loadRank(category: String, order: String) async {
        generation = UUID()
        let request = generation
        videos = []
        hasMore = false
        error = nil
        guard !category.isEmpty && !order.isEmpty else { loading = false; return }
        loading = true
        defer { if generation == request { loading = false } }
        do {
            let response = try await APIClient.shared.rank(category: category, order: order)
            try Task.checkCancellation()
            guard request == generation else { return }
            var seen = Set<String>()
            videos = response.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        } catch is CancellationError {
        } catch {
            guard request == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func load(reset: Bool, category: String, filters: [String: String] = [:], query: String? = nil) async {
        if !reset && (loading || !hasMore) { return }
        if reset {
            generation = UUID()
            videos = []
            page = 0
            hasMore = true
        }
        let request = generation
        guard query != nil || !category.isEmpty else { loading = false; hasMore = false; return }
        loading = true
        error = nil
        let nextPage = page + 1
        defer { if generation == request { loading = false } }
        do {
            let response: [Video]
            if let query = query {
                response = try await APIClient.shared.search(query: query, category: category, page: nextPage)
            } else {
                response = try await APIClient.shared.videos(category: category, page: nextPage, filters: filters)
            }
            try Task.checkCancellation()
            guard request == generation else { return }
            var seen = Set(videos.map(\.id))
            let additions = response.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            videos.append(contentsOf: additions)
            page = nextPage
            // Android SearchItemFragment.updateLoadMoreState uses >= 12.
            // Keep category paging unchanged and stop duplicate-only pages too.
            hasMore = !additions.isEmpty && (query == nil || response.count >= 12)
        } catch is CancellationError {
        } catch {
            guard request == generation else { return }
            // URLSession may report URLError.cancelled instead of CancellationError.
            // A cancelled first page remains resumable when the view reappears.
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
struct MainTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    @State private var capsuleStyle = false
    @State private var unreadCount = 0

    private var unreadBadge: String? {
        guard account.isLoggedIn, unreadCount > 0 else { return nil }
        return unreadCount > 99 ? "99+" : String(unreadCount)
    }

    var body: some View {
        // Keep the actual system tab bar: destination toolbar(.hidden) must still
        // control its visibility, and each tab retains its own navigation stack.
        TabView(selection: $selection) {
            NavigationStack { HomeView() }
                .tabItem { Label("首页", image: "MainTabHome") }.tag(0)
            NavigationStack { RankingView() }
                .tabItem { Label("榜单", image: "MainTabRank") }.tag(1)
            NavigationStack { ProfileView() }
                .tabItem { Label("我", image: "MainTabMe") }.tag(2)
                .badge(unreadBadge)
        }
        .tint(BrowseTheme.green)
        .background(BrowseTheme.background)
        .background(MainTabAppearance(capsule: capsuleStyle, dark: colorScheme == .dark))
        .toolbarBackground(capsuleStyle ? MainTabAppearance.trackColor : BrowseTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .task {
            if let config = try? await APIClient.shared.configuration() {
                capsuleStyle = MainTabAppearance.integer(config["tab_style"]) == 1
            }
        }
        .task(id: "\(account.token)|\(selection)|\(scenePhase)") {
            unreadCount = 0
            guard account.isLoggedIn, scenePhase == .active else { return }
            // Read actions in MessagesView are intentionally unchanged. Periodic
            // refresh also catches read-one/read-all without inventing local counts.
            while !Task.isCancelled {
                do {
                    let response = try await account.request("unread/count", authenticated: false)
                    try Task.checkCancellation()
                    guard account.isLoggedIn, let counts = response as? [String: Any] else { return }
                    let total = MainTabAppearance.integer(counts["total"])
                    unreadCount = total > 0 ? total : ["system", "message_reply", "comment"].reduce(0) {
                        $0 + max(0, MainTabAppearance.integer(counts[$1]))
                    }
                } catch is CancellationError { return }
                catch { /* An unavailable count must never become a fabricated badge. */ }
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { return }
            }
        }
    }
}

/// Public UITabBarAppearance only; no overlay, private subview lookup, or forced
/// tab-bar visibility/height. Native safe-area and navigation remain authoritative.
private struct MainTabAppearance: UIViewControllerRepresentable {
    let capsule: Bool
    let dark: Bool
    static let trackColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 30.0 / 255, alpha: 239.0 / 255)
            : UIColor(red: 239.0 / 255, green: 239.0 / 255, blue: 244.0 / 255, alpha: 239.0 / 255)
    })

    static func integer(_ value: Any?) -> Int {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return 0
    }

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.capsule = capsule
        controller.dark = dark
        controller.applyAppearance()
    }

    final class Controller: UIViewController {
        var capsule = false
        var dark = false
        private var appliedKey = ""
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyAppearance()
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyAppearance()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyAppearance()
        }

        func applyAppearance() {
            guard let bar = containingTabController()?.tabBar, bar.bounds.width > 0 else { return }
            let key = "\(capsule)|\(dark)|\(bar.bounds.width)|\(bar.items?.count ?? 0)"
            guard key != appliedKey else { return }
            appliedKey = key
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = capsule
                ? (dark ? UIColor(white: 30.0 / 255, alpha: 239.0 / 255)
                    : UIColor(red: 239.0 / 255, green: 239.0 / 255, blue: 244.0 / 255, alpha: 239.0 / 255))
                : UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(red: 0.105, green: 0.125, blue: 0.110, alpha: 1)
                        : UIColor(red: 1, green: 0.995, blue: 0.980, alpha: 1)
                }.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
            if capsule {
                appearance.shadowColor = .clear
                let size = CGSize(width: max(1, bar.bounds.width / CGFloat(max(3, bar.items?.count ?? 3)) - 8), height: 42)
                appearance.selectionIndicatorImage = UIGraphicsImageRenderer(size: size).image { context in
                    let fill = dark ? UIColor(red: 90.0 / 255, green: 90.0 / 255, blue: 96.0 / 255, alpha: 242.0 / 255)
                        : UIColor(white: 1, alpha: 242.0 / 255)
                    context.cgContext.setFillColor(fill.cgColor)
                    UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 21).fill()
                }
            }
            let green = UIColor(red: 151.0 / 255, green: 211.0 / 255, blue: 39.0 / 255, alpha: 1)
            let inactive = capsule ? UIColor(white: dark ? 161.0 / 255 : 147.0 / 255, alpha: 1)
                : UIColor(white: dark ? 82.0 / 255 : 217.0 / 255, alpha: 1)
            for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
                item.normal.iconColor = inactive
                item.selected.iconColor = green
                item.normal.titleTextAttributes = [.foregroundColor: inactive, .font: UIFont.systemFont(ofSize: capsule ? 10 : 12)]
                item.selected.titleTextAttributes = [.foregroundColor: green, .font: UIFont.systemFont(ofSize: capsule ? 10 : 12)]
                item.normal.badgeBackgroundColor = UIColor(red: 1, green: 77.0 / 255, blue: 79.0 / 255, alpha: 1)
                item.selected.badgeBackgroundColor = item.normal.badgeBackgroundColor
            }
            bar.itemPositioning = .fill
            bar.standardAppearance = appearance
            bar.scrollEdgeAppearance = appearance
        }

        private func containingTabController() -> UITabBarController? {
            if let controller = tabBarController { return controller }
            // A TabView background can be a sibling of the native tab controller.
            // Walk public controller containment, never private UIKit subviews.
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            return findTabController(in: root)
        }

        private func findTabController(in controller: UIViewController) -> UITabBarController? {
            if let tab = controller as? UITabBarController { return tab }
            for child in controller.children {
                if let tab = findTabController(in: child) { return tab }
            }
            return nil
        }
    }
}

@MainActor
private struct BrowseTopBar: View {
    var body: some View {
        HStack(spacing: 8) {
            NavigationLink { SearchView() } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("发现下一部好片").font(.subheadline)
                    Spacer()
                }
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 13).frame(minHeight: 44)
                .background(BrowseTheme.surface, in: Capsule())
            }.buttonStyle(BrowsePressStyle()).accessibilityLabel("搜索影片、剧集")
            NavigationLink { DownloadsView() } label: {
                Image(systemName: "arrow.down.to.line").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }.accessibilityLabel("下载管理")
            NavigationLink { SavedLibraryView(kind: .history) } label: {
                Image(systemName: "clock").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }.accessibilityLabel("观看历史")
            NavigationLink { MessagesView() } label: {
                Image(systemName: "bell").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }.accessibilityLabel("消息通知")
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal).padding(.vertical, 6)
        .background(BrowseTheme.background)
    }
}

private struct Choice: Identifiable {
    let id: String
    let title: String
}

private struct ChoiceStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String?
    let choices: [Choice]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            if let title = title {
                Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 42)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(choices) { choice in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { selection = choice.id }
                        } label: {
                            Text(choice.title)
                                .font(.subheadline.weight(selection == choice.id ? .semibold : .regular))
                                .padding(.horizontal, 13).frame(minHeight: 44)
                                .foregroundStyle(selection == choice.id ? Color.black : Color.primary)
                                .background(selection == choice.id ? BrowseTheme.green : Color.clear, in: Capsule())
                        }.buttonStyle(BrowsePressStyle())
                            .accessibilityAddTraits(selection == choice.id ? .isSelected : [])
                    }
                }.padding(.horizontal, 8)
            }
        }
    }
}

private struct BrowseMessage: View {
    let title: String
    var detail: String = ""
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: retry == nil ? "film" : "wifi.exclamationmark")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let retry = retry { Button("重试", action: retry).buttonStyle(.bordered) }
        }.frame(maxWidth: .infinity).padding(28)
    }
}

private struct PosterView: View {
    let url: String
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: URL(string: url)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(uiColor: .secondarySystemBackground)
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(0.7, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

@MainActor
private struct VideoTile: View {
    let video: Video
    var body: some View {
        NavigationLink { DetailView(videoID: video.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                PosterView(url: video.poster)
                    .overlay(alignment: .bottomTrailing) {
                        if !video.remark.isEmpty {
                            Text(video.remark).font(.caption2).lineLimit(1)
                                .foregroundStyle(.white).padding(5)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if !video.score.isEmpty && video.score != "0" && video.score != "0.0" {
                            Text(video.score).font(.caption.bold()).foregroundStyle(BrowseTheme.green)
                                .padding(5).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                        }
                    }
                Text(video.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Text([video.year, video.area].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.buttonStyle(BrowsePressStyle())
    }
}

@MainActor
private struct VideoGrid: View {
    let videos: [Video]
    let columns: Int
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 18) {
            ForEach(videos) { video in VideoTile(video: video) }
        }.padding(.horizontal)
    }
}

@MainActor
private struct PagingFooter: View {
    @ObservedObject var store: VideoPageStore
    var automatic = false
    var viewportHeight: CGFloat = 0
    var automaticEnabled = true
    let load: () -> Void
    @State private var sentinelVisible = false

    private var automaticKey: String {
        "\(automaticEnabled)|\(sentinelVisible)|\(store.videos.count)|\(store.loading)|\(store.hasMore)|\(store.error ?? "")"
    }
    var body: some View {
        Group {
            if store.loading {
                ProgressView("正在加载…").padding()
            } else if let error = store.error {
                BrowseMessage(title: "加载失败", detail: error, retry: load)
            } else if store.videos.isEmpty {
                BrowseMessage(title: "暂无内容", detail: "试试其他分类或筛选条件")
            } else if store.hasMore {
                if automatic {
                    ProgressView("继续浏览以加载更多…").padding()
                } else {
                    Button("加载更多", action: load).buttonStyle(.bordered).padding()
                }
            } else {
                Text("已经到底了").font(.footnote).foregroundStyle(.secondary).padding()
            }
        }.frame(maxWidth: .infinity)
            .background {
                if automatic {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SearchFooterFrameKey.self,
                                               value: geometry.frame(in: .named("search.results")))
                    }
                }
            }
            .onPreferenceChange(SearchFooterFrameKey.self) { frame in
                // Unlike onAppear, this does not eagerly fetch a whole eager VStack.
                sentinelVisible = frame.map { $0.maxY > 0 && $0.minY < viewportHeight } ?? false
            }
            .task(id: automaticKey) {
                guard automatic, automaticEnabled, sentinelVisible, !store.loading, store.hasMore,
                      store.error == nil, !store.videos.isEmpty else { return }
                load()
            }
            .onDisappear { sentinelVisible = false }
    }
}

private struct SearchFooterFrameKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

private struct SearchVideoFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SearchScrollPosition {
    let videoID: String
    let minY: CGFloat
    let height: CGFloat
}

/// iOS 16 has no scrollPosition. Stable row IDs plus their viewport geometry
/// preserve the partially clipped top row, without inspecting private UIKit views.
@MainActor
private struct SearchResultsScroll: View {
    @ObservedObject var store: VideoPageStore
    let query: String
    @Binding var position: SearchScrollPosition?
    @Binding var restoreOnReturn: Bool
    let rememberOnDisappear: () -> Bool
    let load: () -> Void
    let refresh: () async -> Void
    @State private var tracking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        Color.clear.frame(height: 1).id("search.top")
                        Text("“\(query)”的搜索结果").font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 18) {
                            ForEach(store.videos) { video in
                                VideoTile(video: video).id(video.id)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: SearchVideoFramesKey.self,
                                                value: [video.id: geometry.frame(in: .named("search.results"))])
                                        }
                                    }
                            }
                        }.padding(.horizontal)
                        PagingFooter(store: store, automatic: true, viewportHeight: viewport.size.height,
                                     automaticEnabled: tracking, load: load)
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                proxy.scrollTo("search.top", anchor: .top)
                            }
                        } label: {
                            Label("回到顶部", systemImage: "arrow.up").font(.footnote.weight(.medium))
                                .foregroundStyle(Color.primary).padding(.horizontal, 18).padding(.vertical, 12)
                                .background(BrowseTheme.surface, in: Capsule())
                        }.buttonStyle(BrowsePressStyle()).padding(.vertical, 20)
                    }.padding(.vertical)
                }
                .coordinateSpace(name: "search.results")
                .refreshable { await refresh() }
                .onPreferenceChange(SearchVideoFramesKey.self) { frames in
                    guard tracking else { return }
                    let visible = frames.filter { $0.value.maxY > 0 && $0.value.minY < viewport.size.height }
                    guard let first = visible.sorted(by: {
                        $0.value.minY == $1.value.minY ? $0.key < $1.key : $0.value.minY < $1.value.minY
                    }).first else { return }
                    position = SearchScrollPosition(videoID: first.key, minY: first.value.minY,
                                                    height: first.value.height)
                }
                .task {
                    if restoreOnReturn, let saved = position,
                       store.videos.contains(where: { $0.id == saved.videoID }) {
                        // Allow the retained grid to lay out before a single restoration.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        let available = viewport.size.height - saved.height
                        let y = available > 0 ? saved.minY / available : 0
                        proxy.scrollTo(saved.videoID, anchor: UnitPoint(x: 0, y: y))
                    }
                    restoreOnReturn = false
                    tracking = true
                }
                .onDisappear {
                    tracking = false
                    if rememberOnDisappear() { restoreOnReturn = position != nil }
                }
            }
        }
    }
}

@MainActor
struct HomeView: View {
    @EnvironmentObject private var catalog: BrowseCatalog
    @EnvironmentObject private var library: LibraryStore
    @State private var selection = "recommended"
    @State private var dismissedResume: String?

    private var resumeVideo: SavedVideo? {
        guard let video = library.history.first, !video.id.isEmpty,
              video.position.isFinite, video.position > 0 else { return nil }
        let key = video.id + "|" + String(video.updated.timeIntervalSince1970)
        return dismissedResume == key ? nil : video
    }

    var body: some View {
        VStack(spacing: 0) {
            BrowseTopBar()
            ChoiceStrip(title: nil, choices: [Choice(id: "recommended", title: "推荐")] + catalog.categories.map {
                Choice(id: $0.id, title: BrowseCatalog.family($0.name) ?? $0.name)
            }, selection: $selection).padding(.vertical, 6)
            if let error = catalog.error {
                BrowseMessage(title: "分类加载失败", detail: error) { Task { await catalog.load() } }
                Spacer()
            } else if catalog.loading && catalog.categories.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalog.categories.isEmpty {
                BrowseMessage(title: "暂无支持的分类") { Task { await catalog.load() } }
                Spacer()
            } else if let category = catalog.categories.first(where: { $0.id == selection }) {
                CategoryVideosView(category: category).id(category.id)
            } else {
                RecommendationsView()
            }
        }
        .background(BrowseTheme.background)
        .navigationTitle("牛牛视频").navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrowseTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let video = resumeVideo {
                HStack(spacing: 10) {
                    NavigationLink { DetailView(videoID: video.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.fill").font(.headline).foregroundStyle(.black)
                                .frame(width: 42, height: 42).background(BrowseTheme.green, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text("继续观看 · \(video.title)").font(.subheadline.bold()).lineLimit(1)
                                Text([video.episode, "已观看 \(Int(min(video.position, 86_400_000)) / 60) 分钟"].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.foregroundStyle(.primary)
                    }.buttonStyle(BrowsePressStyle())
                    Button {
                        dismissedResume = video.id + "|" + String(video.updated.timeIntervalSince1970)
                    } label: {
                        Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel("关闭继续观看提示，不删除观看历史")
                }.padding(12).background(BrowseTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).stroke(BrowseTheme.accent.opacity(0.18), lineWidth: 1) }
                    .padding(.horizontal).padding(.vertical, 8).background(BrowseTheme.background.opacity(0.96))
            }
        }
    }
}

@MainActor
private struct RecommendationsView: View {
    @EnvironmentObject private var catalog: BrowseCatalog
    @State private var blocks: [Recommendation] = []
    @State private var loading = false
    @State private var error: String?
    @State private var visibleGroups = 4

    var body: some View {
        BrowseScroll {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let video = blocks.first?.videos.first {
                    NavigationLink { DetailView(videoID: video.id) } label: {
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("今日精选", systemImage: "sparkles")
                                    .font(.caption.weight(.semibold)).foregroundStyle(BrowseTheme.green)
                                Text(video.name).font(.title2.bold()).lineLimit(3).foregroundStyle(.white)
                                Text([video.year, video.area, video.remark].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.white.opacity(0.70)).lineLimit(2)
                                Label("查看影片", systemImage: "play.fill").font(.caption.bold())
                                    .foregroundStyle(.black).padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(BrowseTheme.green, in: Capsule())
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            PosterView(url: video.poster).frame(width: 116)
                        }.padding(20)
                            .background(Color(red: 0.08, green: 0.12, blue: 0.09), in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(BrowsePressStyle()).padding(.horizontal)
                }
                ForEach(Array(blocks.prefix(visibleGroups))) { block in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(BrowseTheme.green).frame(width: 4, height: 20)
                            Text(block.title).font(.title3.bold())
                            Spacer()
                            if let category = catalog.category(for: block) {
                                NavigationLink { CategoryVideosView(category: category).navigationTitle(category.name) } label: {
                                    Label("查看更多", systemImage: "chevron.right").font(.caption.weight(.medium))
                                        .foregroundStyle(.primary).frame(minHeight: 44)
                                }.buttonStyle(BrowsePressStyle())
                            }
                        }.padding(.horizontal)
                        VideoGrid(videos: Array(block.videos.prefix(6)), columns: 3)
                    }
                }
                if visibleGroups < blocks.count {
                    Button { visibleGroups += 4 } label: {
                        Label("查看更多推荐组", systemImage: "plus.circle")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(BrowseTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(BrowsePressStyle()).padding(.horizontal)
                }
                if loading { ProgressView("正在加载推荐…").frame(maxWidth: .infinity).padding() }
                if let error = error {
                    BrowseMessage(title: "推荐加载失败", detail: error) { Task { await load() } }
                } else if !loading && blocks.isEmpty {
                    BrowseMessage(title: "暂无推荐", detail: "可切换上方分类浏览影片")
                }
            }.padding(.vertical)
        }
        .task(id: catalog.categories.map(\.id).joined(separator: "|")) {
            blocks.removeAll { !catalog.accepts($0) }
            while loading { try? await Task.sleep(nanoseconds: 50_000_000); if Task.isCancelled { return } }
            await load()
        }
        .refreshable { await load() }
        .background(BrowseTheme.background)
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response = try await APIClient.shared.recommendations()
            try Task.checkCancellation()
            var seen = Set<String>()
            blocks = response.filter { catalog.accepts($0) && !$0.videos.isEmpty && seen.insert($0.id).inserted }
                .map { block in
                    var videos = Set<String>()
                    return Recommendation(id: block.id, title: block.title,
                                          videos: block.videos.filter { !$0.id.isEmpty && videos.insert($0.id).inserted })
                }
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct CategoryVideosView: View {
    let category: VideoCategory
    @StateObject private var store = VideoPageStore()
    @State private var filters: [String: String] = ["by": "time"]
    @AppStorage("niuniu.gridColumns") private var columnCount = 3
    @State private var showFilters = false

    private var requestKey: String {
        category.id + filters.keys.sorted().map { "|\($0)=\(filters[$0] ?? "")" }.joined()
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { filters[key] ?? "" }, set: { filters[key] = $0 })
    }

    private func options(_ key: String) -> [Choice] {
        let values = (category.filters[key] ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",，|/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var seen: Set<String> = ["", "全部"]
        return [Choice(id: "", title: "全部")] + values.filter { seen.insert($0).inserted }.map { Choice(id: $0, title: $0) }
    }

    var body: some View {
        BrowseScroll {
            VStack(spacing: 12) {
                ChoiceStrip(title: "排序", choices: [Choice(id: "time", title: "最新"), Choice(id: "hits", title: "最热"), Choice(id: "score", title: "评分")], selection: binding("by"))
                    .padding(.horizontal, 8)
                HStack {
                    Text(BrowseCatalog.family(category.name) ?? category.name).font(.headline)
                    Spacer()
                    Button { showFilters = true } label: {
                        Label("筛选", systemImage: "slider.horizontal.3").font(.caption.weight(.semibold)).frame(minHeight: 44)
                    }
                    Button { columnCount = columnCount == 2 ? 3 : 2 } label: {
                        Label(columnCount == 2 ? "三列" : "两列", systemImage: columnCount == 2 ? "square.grid.3x3" : "square.grid.2x2")
                            .font(.caption).frame(minHeight: 44)
                    }.accessibilityLabel("切换为\(columnCount == 2 ? "三" : "两")列布局")
                }.padding(.horizontal)
                if !filterSummary.isEmpty {
                    Text(filterSummary).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                }
                VideoGrid(videos: store.videos, columns: columnCount == 2 ? 2 : 3)
                PagingFooter(store: store) { Task { await load(reset: false) } }
            }.padding(.vertical, 10)
        }
        .task(id: requestKey) { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .background(BrowseTheme.background)
        .sheet(isPresented: $showFilters) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("找到更合心意的影片").font(.title2.bold())
                        ChoiceStrip(title: "类型", choices: options("class"), selection: binding("class"))
                        ChoiceStrip(title: "地区", choices: options("area"), selection: binding("area"))
                        ChoiceStrip(title: "年份", choices: options("year"), selection: binding("year"))
                        ChoiceStrip(title: "状态", choices: options("state"), selection: binding("state"))
                        Button("重置筛选") { filters = ["by": "time"] }.buttonStyle(.bordered)
                    }.padding()
                }.background(BrowseTheme.background)
                    .navigationTitle("筛选").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showFilters = false } } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    private var filterSummary: String {
        ["class", "area", "year", "state"].compactMap { filters[$0] }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load(reset: Bool) async {
        await store.load(reset: reset, category: category.id, filters: filters.filter { !$0.value.isEmpty })
    }
}

@MainActor
struct RankingView: View {
    @EnvironmentObject private var catalog: BrowseCatalog
    @StateObject private var store = VideoPageStore()
    @State private var categoryID = ""
    @State private var order = ""
    private var selectedID: String { catalog.categories.first(where: { $0.id == categoryID })?.id ?? catalog.categories.first?.id ?? "" }
    private var rankChoices: [Choice] {
        let category = catalog.categories.first { $0.id == selectedID }
        var seen = Set<String>()
        return (category?.filters["director"] ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",，|/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { value in
                let parts = value.components(separatedBy: "_")
                let name = parts.count > 1 ? parts[1] : value
                let period = ["day": "日榜", "week": "周榜", "month": "月榜"][parts.first ?? ""]
                // Android getRankParams() sends only the first component (day),
                // not the full UI metadata string day_电影榜_1.
                return Choice(id: parts.first ?? value, title: period.map { "\(name) · \($0)" } ?? name)
            }
    }
    private var selectedOrder: String { rankChoices.first(where: { $0.id == order })?.id ?? rankChoices.first?.id ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            BrowseTopBar()
            ChoiceStrip(title: nil, choices: catalog.categories.map { Choice(id: $0.id, title: BrowseCatalog.family($0.name) ?? $0.name) }, selection: Binding(get: { selectedID }, set: { categoryID = $0 }))
                .padding(.vertical, 8)
            ChoiceStrip(title: "榜单", choices: rankChoices,
                        selection: Binding(get: { selectedOrder }, set: { order = $0 }))
                .padding(.horizontal).padding(.bottom, 8)
             BrowseScroll {
                 LazyVStack(spacing: 14) {
                     HStack(alignment: .bottom) {
                         VStack(alignment: .leading, spacing: 6) {
                             Text("THE WATCH LIST").font(.caption2.bold()).tracking(2).foregroundStyle(BrowseTheme.accent)
                             Text("热爱，正在上榜").font(.title2.bold())
                             Text("按服务端榜单排序，发现大家正在看的好片")
                                 .font(.caption).foregroundStyle(.secondary)
                         }
                         Spacer(minLength: 8)
                         Image(systemName: "chart.bar.xaxis").font(.system(size: 32, weight: .light))
                             .foregroundStyle(BrowseTheme.accent)
                     }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
                     if let error = catalog.error {
                        BrowseMessage(title: "分类加载失败", detail: error) { Task { await catalog.load() } }
                    } else if catalog.loading {
                        ProgressView().padding()
                    } else if selectedID.isEmpty {
                        BrowseMessage(title: "暂无支持的分类")
                    } else if selectedOrder.isEmpty {
                        BrowseMessage(title: "当前分类暂无榜单", detail: "榜单类型以服务端提供的配置为准")
                    } else {
                        ForEach(Array(store.videos.enumerated()), id: \.element.id) { index, video in
                            NavigationLink { DetailView(videoID: video.id) } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    PosterView(url: video.poster).frame(width: 92)
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("TOP \(index + 1)").font(.caption.bold())
                                             .foregroundStyle(index < 3 ? BrowseTheme.accent : Color.secondary)
                                        Text(video.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                        Text([video.year, video.area, video.category].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text(video.remark).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        if !video.score.isEmpty && video.score != "0" && video.score != "0.0" {
                                            Label(video.score, systemImage: "star.fill").font(.caption.bold()).foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(14).background(BrowseTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                            }.buttonStyle(BrowsePressStyle())
                        }
                        if store.loading { ProgressView("正在加载榜单…").padding() }
                        else if let error = store.error {
                            BrowseMessage(title: "榜单加载失败", detail: error) { Task { await load() } }
                        } else if store.videos.isEmpty {
                            BrowseMessage(title: "暂无上榜影片", detail: "稍后刷新，或切换其他分类")
                        }
                    }
                }.padding()
            }.refreshable { await load() }
        }
        .background(BrowseTheme.background)
        .navigationTitle("榜单").navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrowseTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: selectedID + "|" + selectedOrder) { await load() }
    }

    private func load() async { await store.loadRank(category: selectedID, order: selectedOrder) }
}

@MainActor
struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var catalog: BrowseCatalog
    @StateObject private var store = VideoPageStore()
    @State private var text = ""
    @State private var submitted = ""
    @State private var categoryID = ""
    @State private var submission = 0
    @State private var requestKey: String?
    @State private var scrollPosition: SearchScrollPosition?
    @State private var restoreOnReturn = false
    @State private var suggestions: [String] = []
    @State private var hotWords: [String] = []
    @State private var suggestLoading = false
    @State private var suggestError: String?
    @State private var hotLoading = false
    @State private var hotError: String?
    @State private var suggestionRetry = 0
    @FocusState private var focused: Bool
    private var selectedID: String { catalog.categories.contains(where: { $0.id == categoryID }) ? categoryID : "" }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchRequestKey: String { "\(submission)|\(selectedID)|\(submitted)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索影片、演员或关键词", text: $text).focused($focused)
                    .autocorrectionDisabled()
                    .submitLabel(.search).onSubmit { submit(text) }
                if !text.isEmpty {
                    Button { text = ""; submitted = "" } label: { Image(systemName: "xmark.circle.fill") }
                         .accessibilityLabel("清空搜索").frame(width: 44, height: 44)
                }
                Button("搜索") { submit(text) }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal).padding(.vertical, 6).background(BrowseTheme.surface)
            if let error = catalog.error {
                BrowseMessage(title: "分类加载失败", detail: error) { Task { await catalog.load() } }
            } else if catalog.loading {
                ProgressView().padding()
            } else if catalog.categories.isEmpty {
                BrowseMessage(title: "暂无可搜索的分类") { Task { await catalog.load() } }
            }
            if submitted.isEmpty || (focused && trimmedText != submitted) {
                BrowseScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        if !trimmedText.isEmpty {
                            Text("联想建议").font(.title3.bold())
                            if suggestLoading { ProgressView("正在查找建议…") }
                            ForEach(suggestions, id: \.self) { term in
                                Button { text = term; submit(term) } label: {
                                    HStack {
                                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                        Text(term).foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                                    }.padding(13).background(BrowseTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                                }.buttonStyle(BrowsePressStyle())
                            }
                            if let error = suggestError {
                                BrowseMessage(title: "联想建议加载失败", detail: error) { suggestionRetry += 1 }
                            } else if !suggestLoading && suggestions.isEmpty {
                                Text("没有联想建议，点击搜索查看结果").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Text("搜索历史").font(.title3.bold())
                            Spacer()
                            if !library.searches.isEmpty {
                                Button { library.clearSearches() } label: { Label("清空", systemImage: "trash").font(.caption).frame(minHeight: 44) }
                            }
                        }
                        if library.searches.isEmpty {
                            BrowseMessage(title: "还没有搜索记录", detail: "输入影片名称开始搜索")
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading, spacing: 10) {
                                ForEach(library.searches, id: \.self) { term in
                                    Button { text = term; submit(term) } label: {
                                        Text(term).font(.subheadline).lineLimit(1).padding(10)
                                            .frame(maxWidth: .infinity)
                                            .background(BrowseTheme.surface, in: Capsule())
                                    }.buttonStyle(BrowsePressStyle())
                                }
                            }
                        }
                         HStack {
                             Label("热门搜索", systemImage: "flame.fill").font(.title3.bold())
                            Spacer()
                            Button { Task { await loadHot() } } label: {
                                Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                             }.accessibilityLabel("刷新热门搜索")
                        }
                         Text("服务端实时配置 · 点击关键词搜索").font(.caption).foregroundStyle(.secondary)
                         ForEach(Array(hotWords.enumerated()), id: \.element) { index, term in
                             Button { text = term; submit(term) } label: {
                                HStack(spacing: 12) {
                                    Text(String(format: "%02d", index + 1)).font(.headline.monospacedDigit())
                                         .foregroundStyle(index < 3 ? BrowseTheme.accent : Color.secondary)
                                     Text(term).foregroundStyle(.primary).lineLimit(2)
                                    Spacer()
                                     Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44)
                            }.buttonStyle(BrowsePressStyle())
                        }
                        if hotLoading { ProgressView("正在加载热门…") }
                        else if let error = hotError {
                            BrowseMessage(title: "热门加载失败", detail: error) { Task { await loadHot() } }
                         } else if hotWords.isEmpty {
                             Text("服务器暂无热门搜索").font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding()
                }
            } else {
                let identity = searchRequestKey
                ChoiceStrip(title: nil, choices: [Choice(id: "", title: "全部")] + catalog.categories.map { Choice(id: $0.id, title: BrowseCatalog.family($0.name) ?? $0.name) }, selection: Binding(get: { selectedID }, set: { categoryID = $0 }))
                    .padding(.vertical, 8)
                SearchResultsScroll(store: store, query: submitted, position: $scrollPosition,
                                    restoreOnReturn: $restoreOnReturn,
                                    rememberOnDisappear: { searchRequestKey == identity && !focused },
                                    load: { Task { await load(reset: false) } },
                                    refresh: { await load(reset: true) })
                    .id(searchRequestKey)
            }
        }
        .background(BrowseTheme.background)
        .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(trimmedText)|\(suggestionRetry)") { await loadSuggestions() }
        .task { await loadHot() }
        .task(id: searchRequestKey) {
            guard !submitted.isEmpty else { requestKey = nil; return }
            if requestKey != searchRequestKey {
                requestKey = searchRequestKey
                scrollPosition = nil
                restoreOnReturn = false
                await load(reset: true)
            } else if store.needsFirstPage {
                // The navigation lifetime can cancel page one before it commits.
                // Resume without clearing any completed pages or remembering a false success.
                while store.loading {
                    do { try await Task.sleep(nanoseconds: 20_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled, store.needsFirstPage else { return }
                await load(reset: false)
            }
        }
    }

    private func submit(_ value: String) {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        focused = false
        library.rememberSearch(query)
        submitted = query
        submission += 1
    }

    private func load(reset: Bool) async {
        guard !submitted.isEmpty else { return }
        guard reset || requestKey == searchRequestKey else { return }
        if reset {
            scrollPosition = nil
            restoreOnReturn = false
        }
        await store.load(reset: reset, category: selectedID, query: submitted)
    }

    private func loadSuggestions() async {
        let query = trimmedText
        suggestions = []
        suggestError = nil
        suggestLoading = false
        guard !query.isEmpty else { return }
        suggestLoading = true
        defer { if trimmedText == query { suggestLoading = false } }
        do {
            try await Task.sleep(nanoseconds: 280_000_000)
            let response = try await APIClient.shared.suggest(keyword: query)
            try Task.checkCancellation()
            guard trimmedText == query else { return }
            var seen = Set<String>()
            suggestions = response.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        } catch is CancellationError {
        } catch {
            guard trimmedText == query else { return }
            suggestError = error.localizedDescription
        }
    }

    private func loadHot() async {
        guard !hotLoading else { return }
        hotLoading = true
        hotError = nil
        defer { hotLoading = false }
        do {
            let configuration = try await APIClient.shared.configuration()
            try Task.checkCancellation()
            // Verified in SexyConfig.java: @SerializedName("search_hot_words") List<String>.
            guard let response = configuration["search_hot_words"] as? [String] else {
                hotWords = []
                return
            }
            var seen = Set<String>()
            hotWords = response.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        } catch is CancellationError {
        } catch { hotError = error.localizedDescription }
    }
}

@MainActor
struct ProfileView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var account = AccountStore.shared
    @State private var showLogin = false
    @State private var profileError: String?
    @State private var configuration: [String: Any] = [:]
    @State private var configurationError: String?

    private var memberConfiguration: [String: Any] {
        configuration["member_module_config"] as? [String: Any] ?? [:]
    }

    private var showsMemberCard: Bool {
        ["1", "2"].contains(memberConfiguration.text("member_style").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func memberText(_ key: String, fallback: String) -> String {
        let value = memberConfiguration.text(key).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private func profileText(_ keys: [String]) -> String {
        for key in keys {
            let value = account.profile.text(key).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && value != "<null>" { return value }
        }
        return ""
    }

    private var nickname: String {
        let value = profileText(["nickname", "nick_name", "user_nick_name", "user_name", "username"])
        return account.isLoggedIn ? (value.isEmpty ? "牛牛用户" : value) : "点击登录"
    }

    private var membership: String {
        guard account.isLoggedIn else { return "登录查看会员状态" }
        let label = profileText(["member_name", "vip_name", "group_name", "user_group_name"])
        if !label.isEmpty { return label }
        let expiry = profileText(["vip_expire", "vip_expire_time", "user_end_time", "member_expire"])
        if !expiry.isEmpty && expiry != "0" {
            if let timestamp = Double(expiry), timestamp.isFinite, timestamp > 0 {
                let date = Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp)
                return date > Date() ? "会员至 " + date.formatted(date: .abbreviated, time: .omitted) : "会员已到期"
            }
            return "会员有效期：\(expiry)"
        }
        let flag = profileText(["is_vip", "vip", "is_member"])
        if ["1", "true"].contains(flag.lowercased()) { return "会员账号" }
        if ["0", "false"].contains(flag.lowercased()) { return "普通账号" }
        return "查看会员状态"
    }

    private var profileHeader: some View {
        VStack(spacing: 10) {
            AsyncImage(url: URL(string: account.isLoggedIn
                                 ? profileText(["user_portrait", "avatar", "avatar_url", "portrait"])
                                 : configuration.text("default_avatar"))) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Image("ProfileAvatarDefault").resizable().scaledToFill() }
            }.frame(width: 64, height: 64).clipShape(Circle())
            VStack(spacing: 6) {
                Text(nickname).font(.system(size: 18, weight: .bold)).foregroundStyle(.primary).lineLimit(1)
                if account.isLoggedIn {
                    let phone = profileText(["user_phone", "phone"])
                    Text(phone.isEmpty ? "手机号未绑定" : "手机号：\(phone)")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }.frame(maxWidth: .infinity).padding(.top, 50).padding(.bottom, 11)
            .contentShape(Rectangle())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 11) {
                if account.isLoggedIn {
                    NavigationLink { AccountProfileView().toolbar(.visible, for: .navigationBar) } label: { profileHeader }
                } else {
                    Button { showLogin = true } label: { profileHeader }.buttonStyle(BrowsePressStyle())
                }
                if showsMemberCard {
                    NavigationLink { MemberCenterView().toolbar(.visible, for: .navigationBar) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "crown.fill").font(.system(size: 28)).foregroundStyle(Color(red: 0.94, green: 0.78, blue: 0.48))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("VIP会员中心").font(.system(size: 16, weight: .bold))
                                Text(account.isLoggedIn ? membership : memberText("member_text", fallback: "开通VIP享受专属特权，海量视频抢先看"))
                                    .font(.system(size: 10)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(memberText("open", fallback: "立即开通"))
                                .font(.system(size: 14)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color(red: 0.96, green: 0.75, blue: 0.42), in: Capsule())
                        }.foregroundStyle(Color(red: 0.94, green: 0.82, blue: 0.61)).padding(.horizontal, 14).frame(height: 70)
                            .background(Color(red: 0.18, green: 0.17, blue: 0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                historyCard
                functionCard
                if let error = account.credentialError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if let error = profileError {
                    BrowseMessage(title: "账号资料加载失败", detail: error) { Task { await refreshProfile() } }
                }
                if let error = configurationError {
                    Button { Task { await loadConfiguration() } } label: {
                        Text("配置加载失败：\(error) · 点击重试").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 15).padding(.bottom, 11)
        }
        .buttonStyle(BrowsePressStyle())
        .background {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Image("ProfileTopBackground").resizable().frame(height: geometry.size.width * 0.576)
                    Spacer(minLength: 0)
                }.ignoresSafeArea(edges: .top)
            }.background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationTitle("我").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                LoginView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showLogin = false } } }
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .onChange(of: account.isLoggedIn) { loggedIn in if loggedIn { showLogin = false } }
        .task(id: account.token) { await refreshProfile() }
        .task { await loadConfiguration() }
        .refreshable { await refreshProfile(); await loadConfiguration() }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("播放历史").font(.system(size: 16, weight: .bold))
                Spacer()
                NavigationLink { ProfileHistoryView() } label: {
                    HStack(spacing: 4) {
                        Text("查看更多")
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }.font(.system(size: 12)).foregroundStyle(.secondary).frame(minHeight: 32)
                }
            }
            if !library.history.isEmpty {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(library.history.prefix(9))) { video in
                                ProfileHistoryTile(video: video).frame(width: max(1, (geometry.size.width - 20) / 3))
                            }
                        }
                    }
                }.frame(height: 90)
            }
        }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, library.history.isEmpty ? 10 : 16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var functionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("常用功能").font(.system(size: 16, weight: .bold)).padding(.horizontal, 16).padding(.vertical, 10)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4), spacing: 10) {
                NavigationLink { ProfileFavoritesView() } label: { ProfileFunctionLabel(title: "我的收藏", image: "ProfileFavorite") }
                NavigationLink { DownloadsView().toolbar(.visible, for: .navigationBar) } label: { ProfileFunctionLabel(title: "我的下载", image: "ProfileDownload") }
                ShareLink(item: URL(string: "https://www.xinniuniushipin.com/")!, subject: Text("牛牛视频"), message: Text("快来牛牛视频发现喜欢的影片")) {
                    ProfileFunctionLabel(title: "分享APP", image: "ProfileShare")
                }
                NavigationLink { MessagesView().toolbar(.visible, for: .navigationBar) } label: { ProfileFunctionLabel(title: "消息评论", image: "ProfileMessage") }
                NavigationLink { FeedbackView().toolbar(.visible, for: .navigationBar) } label: { ProfileFunctionLabel(title: "意见反馈", image: "ProfileFeedback") }
                NavigationLink { SettingsView().toolbar(.visible, for: .navigationBar) } label: { ProfileFunctionLabel(title: "设置", image: "ProfileSettings") }
                Color.clear.frame(height: 64).accessibilityHidden(true)
                Color.clear.frame(height: 64).accessibilityHidden(true)
            }.padding(.horizontal, 13).padding(.bottom, 6)
        }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func loadConfiguration() async {
        configurationError = nil
        do {
            let response = try await account.request("config", authenticated: false)
            try Task.checkCancellation()
            configuration = response as? [String: Any] ?? [:]
        } catch is CancellationError { }
        catch { configurationError = error.localizedDescription }
    }

    private func refreshProfile() async {
        profileError = nil
        guard account.isLoggedIn else { return }
        do { try await account.refreshProfile() }
        catch is CancellationError { }
        catch { profileError = error.localizedDescription }
    }
}

private struct ProfileFunctionLabel: View {
    let title: String
    let image: String
    var body: some View {
        VStack(spacing: 5) {
            Image(image).resizable().scaledToFit().frame(width: 24, height: 24)
            Text(title).font(.system(size: 14)).lineLimit(1).minimumScaleFactor(0.8)
        }.foregroundStyle(.primary).frame(maxWidth: .infinity).frame(height: 64).contentShape(Rectangle())
    }
}

@MainActor
private struct ProfileHistoryTile: View {
    let video: SavedVideo
    private var time: String {
        let seconds = video.position.isFinite ? Int(max(0, min(video.position, 86_400_000))) : 0
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        NavigationLink { DetailView(videoID: video.id).toolbar(.visible, for: .navigationBar) } label: {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geometry in
                    AsyncImage(url: URL(string: video.poster)) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Color(uiColor: .tertiarySystemFill) }
                    }.frame(width: geometry.size.width, height: 64).clipped()
                }.frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        Text(time).font(.system(size: 11)).foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3)).padding(5)
                    }
                Text([video.title, video.episode].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.system(size: 14)).foregroundStyle(.primary).lineLimit(1)
            }
        }.buttonStyle(BrowsePressStyle())
    }
}

@MainActor
private struct ProfileFavoritesView: View {
    @State private var local = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("收藏来源", selection: $local) {
                Text("账号收藏").tag(false)
                Text("游客收藏（本机）").tag(true)
            }.pickerStyle(.segmented).padding(12)
            if local { SavedLibraryView(kind: .favorites) }
            else { AccountLibraryView() }
        }.navigationTitle("我的收藏").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

@MainActor
private struct ProfileHistoryView: View {
    var body: some View {
        SavedLibraryView(kind: .history)
            .navigationTitle("播放历史").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { AccountLibraryView().toolbar(.visible, for: .navigationBar) } label: {
                        Text("云历史")
                    }
                }
            }
    }
}

@MainActor
struct SavedLibraryView: View {
    enum Kind { case favorites, history }
    let kind: Kind
    @EnvironmentObject private var library: LibraryStore
    @State private var confirmClear = false
    private var items: [SavedVideo] { kind == .favorites ? library.favorites : library.history }
    private var title: String { kind == .favorites ? "游客收藏" : "观看历史" }

    var body: some View {
        List {
            if items.isEmpty {
                BrowseMessage(title: kind == .favorites ? "还没有收藏" : "还没有观看记录",
                              detail: kind == .favorites ? "在影片详情页点击收藏即可保存在这里" : "播放影片后可在这里继续观看")
                    .listRowSeparator(.hidden)
            }
            ForEach(items) { video in
                NavigationLink { DetailView(videoID: video.id) } label: {
                    HStack(spacing: 14) {
                        PosterView(url: video.poster).frame(width: 66)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(video.title).font(.headline).lineLimit(2)
                            if kind == .history {
                                if !video.episode.isEmpty { Text(video.episode).font(.caption).foregroundStyle(.secondary) }
                                if video.position.isFinite && video.position > 0 {
                                    Text("已观看 \(Int(min(video.position, 86_400_000)) / 60) 分钟")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(video.updated, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 4)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        if kind == .favorites { library.toggleFavorite(video) }
                        else { library.removeHistory(video.id) }
                    } label: { Label(kind == .favorites ? "取消收藏" : "删除", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .background(BrowseTheme.background).navigationTitle(title)
        .toolbar {
            if kind == .history && !items.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) { Button("清空") { confirmClear = true } }
            }
        }
        .confirmationDialog("清空所有观看历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空观看历史", role: .destructive) { library.clearHistory() }
        }
    }
}
