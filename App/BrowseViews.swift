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

private struct BrowseViewportKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct BrowseTrackingKey: EnvironmentKey {
    static let defaultValue = true
}

private struct PosterCoordinateSpaceKey: EnvironmentKey {
    static let defaultValue = "browse.results"
}

private extension EnvironmentValues {
    var posterCoordinateSpace: String {
        get { self[PosterCoordinateSpaceKey.self] }
        set { self[PosterCoordinateSpaceKey.self] = newValue }
    }
    var browseViewportHeight: CGFloat {
        get { self[BrowseViewportKey.self] }
        set { self[BrowseViewportKey.self] = newValue }
    }
    var browseTracking: Bool {
        get { self[BrowseTrackingKey.self] }
        set { self[BrowseTrackingKey.self] = newValue }
    }
}

private struct BrowseScroll<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tracking = false
    private let resetKey: String
    private let resetRevision: Int
    private let active: Bool
    private let content: Content
    init(resetKey: String = "", resetRevision: Int = 0, active: Bool = true, @ViewBuilder content: () -> Content) {
        self.resetKey = resetKey
        self.resetRevision = resetRevision
        self.active = active
        self.content = content()
    }
    var body: some View {
        GeometryReader { viewport in
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
            .coordinateSpace(name: "browse.results")
            .environment(\.browseViewportHeight, viewport.size.height)
            .environment(\.browseTracking, tracking && active)
            .environment(\.posterCoordinateSpace, "browse.results")
            .onAppear { tracking = true }
            .onDisappear { tracking = false }
            // Push/pop keeps this ScrollView's identity. Never issue a scroll command
            // from task/onAppear: a retained scroll already owns its real offset.
            .onChange(of: resetKey) { _ in proxy.scrollTo("browse.top", anchor: .top) }
            .onChange(of: resetRevision) { _ in proxy.scrollTo("browse.top", anchor: .top) }
        }
        }
    }
}

private struct BrowseAnchor: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.id(id)
    }
}

/// Preserve server order; visibility follows the original teen-mode metadata.
@MainActor
final class BrowseCatalog: ObservableObject {
    @Published private(set) var categories: [VideoCategory] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var visibilityContext = ""
    private var visibilityRevision: UInt64 = 0
    private var allCategories: [VideoCategory] = []
    private var visibilitySignature: String?
    func refreshVisibility() {
        let signature = String(APIClient.shared.isTeenModeEnabled) + String(describing:
            allCategories.map { category in
                [category.id, category.name] + category.filters.keys.sorted().map { key in
                    "\(key)=\(category.filters[key] ?? "")"
                }
            })
        if visibilitySignature != signature {
            visibilitySignature = signature
            visibilityRevision &+= 1
            visibilityContext = "\(visibilityRevision)|\(APIClient.shared.isTeenModeEnabled)"
        }
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
    @Published var scrollResetRevision = 0
    private var page = 0
    private var generation = UUID()
    private var rankCompleted = false
    var needsFirstPage: Bool { page == 0 && error == nil && hasMore }
    var needsRank: Bool { !rankCompleted && error == nil }

    func loadRank(category: String, order: String, reset: Bool = false,
                  shouldCommit: () -> Bool = { true }) async {
        guard reset || !loading else { return }
        generation = UUID()
        let request = generation
        if reset { videos = [] }
        hasMore = false
        error = nil
        rankCompleted = false
        guard !category.isEmpty && !order.isEmpty else { loading = false; return }
        loading = true
        defer { if generation == request { loading = false } }
        do {
            let response = try await APIClient.shared.rank(category: category, order: order)
            try Task.checkCancellation()
            guard request == generation, shouldCommit() else { return }
            var seen = Set<String>()
            videos = response.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            rankCompleted = true
        } catch is CancellationError {
        } catch {
            guard request == generation else { return }
            guard !Task.isCancelled, shouldCommit() else { return }
            self.error = error.localizedDescription
        }
    }

    func load(reset: Bool, category: String, filters: [String: String] = [:], query: String? = nil,
              shouldCommit: () -> Bool = { true }) async {
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
            guard request == generation, shouldCommit() else { return }
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
            guard !Task.isCancelled, shouldCommit() else { return }
            self.error = error.localizedDescription
        }
    }
}

/// This is a page-state cache, not a URL/HTTP response cache. Strong ownership
/// survives SwiftUI destination destruction; completed empty pages and errors
/// are retained along with page number, hasMore and in-flight request guards.
@MainActor
private final class BrowsePageCache {
    static let shared = BrowsePageCache()
    private var context = ""
    private var pages: [String: VideoPageStore] = [:]
    private var recommendations: [String: RecommendationPageStore] = [:]
    private var recency: [String] = []
    private let limit = 64

    static func contextKey(_ catalog: BrowseCatalog) -> String {
        // APIClient.contextRevision is private. The observable account token,
        // effective teen mode, metadata revision and persisted endpoint are the
        // available public context; no APIClient changes are required here.
        String(describing: [AccountStore.shared.token, catalog.visibilityContext,
            String(APIClient.shared.isTeenModeEnabled), UserDefaults.standard.string(forKey: "api.baseURL") ?? ""])
    }

    private func prepare(_ newContext: String, key: String) {
        if context != newContext {
            context = newContext
            pages.removeAll()
            recommendations.removeAll()
            recency.removeAll()
        }
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > limit {
            let victim = recency.removeFirst()
            pages.removeValue(forKey: victim)
            recommendations.removeValue(forKey: victim)
        }
    }

    func page(context: String, key: String) -> VideoPageStore {
        prepare(context, key: key)
        if let page = pages[key] { return page }
        let page = VideoPageStore()
        pages[key] = page
        return page
    }

    func recommendation(context: String) -> RecommendationPageStore {
        let key = "recommendations"
        prepare(context, key: key)
        if let page = recommendations[key] { return page }
        let page = RecommendationPageStore()
        recommendations[key] = page
        return page
    }
}

@MainActor
private final class RecommendationPageStore: ObservableObject {
    @Published var blocks: [Recommendation] = []
    @Published var loading = false
    @Published var error: String?
    @Published var visibleGroups = 4
    @Published var completed = false
    @Published var scrollResetRevision = 0
}

@MainActor
private struct ObservedVideoPage<Content: View>: View {
    @ObservedObject var store: VideoPageStore
    let content: (VideoPageStore) -> Content
    var body: some View { content(store) }
}

private func retainBrowseKey(_ key: String, in keys: inout [String], limit: Int = 6) {
    keys.removeAll { $0 == key }
    keys.append(key)
    if keys.count > limit { keys.removeFirst(keys.count - limit) }
}

@MainActor
struct MainTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
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
                .tabItem { Label { Text("首页") } icon: { Image(uiImage: GlassTabContainer.icon("MainTabHome")) } }.tag(0)
            NavigationStack { RankingView() }
                .tabItem { Label { Text("榜单") } icon: { Image(uiImage: GlassTabContainer.icon("MainTabRank")) } }.tag(1)
            NavigationStack { ProfileView() }
                .tabItem { Label { Text("我") } icon: { Image(uiImage: GlassTabContainer.icon("MainTabMe")) } }.tag(2)
                .badge(unreadBadge)
        }
        .tint(BrowseTheme.accent)
        .background(BrowseTheme.background)
        .background(MainTabAppearance(dark: colorScheme == .dark, selection: $selection, badge: unreadBadge, active: scenePhase == .active))
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

/// Keep SwiftUI's native navigation/visibility router; the compact bar owns its UI.
private struct MainTabAppearance: UIViewControllerRepresentable {
    @Environment(\.liuyunGlassConfiguration) private var glassConfiguration
    let dark: Bool
    @Binding var selection: Int
    let badge: String?
    let active: Bool
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

    func makeUIViewController(context: Context) -> GlassTabContainer {
        return GlassTabContainer()
    }
    func updateUIViewController(_ controller: GlassTabContainer, context: Context) {
        controller.dark = dark
        controller.glassConfiguration = glassConfiguration
        controller.selection = selection
        controller.badge = badge
        controller.active = active
        controller.onSelect = { selection = $0 }
        controller.refresh()
    }
}

@MainActor
private struct BrowseTopBar: View {
    @EnvironmentObject private var search: SearchMorphPresentation
    @Environment(\.searchMorphNamespace) private var searchNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            Button { search.open(reduceMotion: reduceMotion) } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("发现下一部好片").font(.subheadline)
                    Spacer()
                }
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 13).frame(minHeight: 44)
                .background {
                    if let namespace = searchNamespace, !reduceMotion {
                        GlassSearchPill()
                            .matchedGeometryEffect(id: "browse.search.pill", in: namespace, isSource: !search.expanded)
                    } else {
                        GlassSearchPill()
                    }
                }
            }.buttonStyle(BrowsePressStyle()).accessibilityLabel("搜索影片、剧集")
            NavigationLink { DownloadsView().toolbar(.visible, for: .navigationBar) } label: {
                Image(systemName: "arrow.down.to.line").font(.body.weight(.semibold)).frame(width: 44, height: 44).glassBackground(in: Circle())
            }.accessibilityLabel("下载管理")
            NavigationLink { SavedLibraryView(kind: .history).toolbar(.visible, for: .navigationBar) } label: {
                Image(systemName: "clock").font(.body.weight(.semibold)).frame(width: 44, height: 44).glassBackground(in: Circle())
            }.accessibilityLabel("观看历史")
            NavigationLink { MessagesView().toolbar(.visible, for: .navigationBar) } label: {
                Image(systemName: "bell").font(.body.weight(.semibold)).frame(width: 44, height: 44).glassBackground(in: Circle())
            }.accessibilityLabel("消息通知")
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal).padding(.vertical, 6)
    }
}

private struct Choice: Identifiable {
    let id: String
    let title: String
}

private struct ChoiceStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var indicatorNamespace
    @State private var bounds: [String: CGRect] = [:]
    @State private var motionStart = Date.distantPast
    @State private var motionDistance: CGFloat = 0
    @State private var moving = false
    @State private var motionEpoch = UUID()
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
                            selection = choice.id
                        } label: {
                            Text(choice.title)
                                // Stable metrics: selected weight must not move the measured targets.
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 13).frame(minHeight: 44)
                                .foregroundStyle(selection == choice.id ? BrowseTheme.accent : Color.primary)
                                .contentShape(Capsule())
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: ChoiceBoundsPreference.self,
                                            value: [choice.id: proxy.frame(in: .named(indicatorNamespace))])
                                    }
                                }
                                .background {
                                    if selection == choice.id {
                                        if reduceMotion {
                                            LiquidChoiceCapsule(start: .distantPast, distance: 0, moving: false)
                                                .transition(.opacity)
                                        } else {
                                            LiquidChoiceCapsule(start: motionStart, distance: motionDistance, moving: moving)
                                                .matchedGeometryEffect(id: "selection", in: indicatorNamespace)
                                        }
                                    }
                                }
                        }.buttonStyle(BrowsePressStyle())
                            .accessibilityAddTraits(selection == choice.id ? .isSelected : [])
                    }
                }
                .coordinateSpace(name: indicatorNamespace)
                .onPreferenceChange(ChoiceBoundsPreference.self) {
                    bounds = $0
                    if !moving { lastSelectedCenter = $0[selection]?.midX ?? lastSelectedCenter }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .animation(reduceMotion ? .easeInOut(duration: 0.18) : .easeOut(duration: LiquidSelectionMotion.duration * LiquidSelectionMotion.travelEnd), value: selection)
                .onChange(of: selection) { newValue in
                    let target = bounds[newValue]
                    motionDistance = (target?.midX ?? 0) - lastSelectedCenter
                    lastSelectedCenter = target?.midX ?? lastSelectedCenter
                    motionStart = Date()
                    motionEpoch = UUID()
                    moving = !reduceMotion && abs(motionDistance) > 0.5
                }
                .onAppear { lastSelectedCenter = bounds[selection]?.midX ?? 0 }
                .task(id: motionEpoch) {
                    let epoch = motionEpoch
                    guard moving else { return }
                    do { try await Task.sleep(nanoseconds: UInt64(LiquidSelectionMotion.duration * 1_000_000_000)) }
                    catch { return }
                    guard !Task.isCancelled, epoch == motionEpoch else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { moving = false }
                }
                .onChange(of: reduceMotion) { if $0 { motionEpoch = UUID(); moving = false } }
            }
        }
        .glassBackground(in: Capsule())
    }
    @State private var lastSelectedCenter: CGFloat = 0
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

private struct PosterPrefetchKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct PosterView: View {
    let url: String
    @Environment(\.displayScale) private var displayScale
    @Environment(\.browseViewportHeight) private var viewportHeight
    @Environment(\.browseTracking) private var tracking
    @Environment(\.posterCoordinateSpace) private var coordinateSpace
    @State private var prefetched = false
    @State private var image: UIImage?
    @State private var loadedURL: String?
    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named(coordinateSpace))
            let pixels = min(2048, max(1, Int(ceil(max(geometry.size.width, geometry.size.height) * displayScale))))
            let eligible = tracking && prefetched
            Group {
                if let image = image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(uiColor: .secondarySystemBackground)
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .preference(key: PosterPrefetchKey.self, value: viewportHeight > 0 && frame.width > 0
                        && frame.maxY > -viewportHeight && frame.minY < viewportHeight * 2)
            .onPreferenceChange(PosterPrefetchKey.self) { prefetched = $0 }
            .task(id: "\(url)|\(pixels)|\(eligible)") {
                if loadedURL != url { image = nil }
                guard eligible, let source = URL(string: url), ["http", "https"].contains(source.scheme?.lowercased() ?? "") else { return }
                guard loadedURL != url || image == nil else { return }
                let result = await PosterImagePipeline.shared.image(url: source, pixels: pixels)
                guard !Task.isCancelled else { return }
                image = result
                loadedURL = url
            }
            .onDisappear { image = nil; prefetched = false }
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
    var anchorPrefix = "video."
    var body: some View {
        // Eager rows have actual heights, not lazy offscreen estimates that change
        // when the navigation destination detaches and reattaches the viewport.
        VStack(spacing: 18) {
            ForEach(0..<((videos.count + columns - 1) / columns), id: \.self) { row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < videos.count {
                            VideoTile(video: videos[index])
                                .modifier(BrowseAnchor(id: anchorPrefix + videos[index].id))
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                        }
                    }
                }
            }
        }.padding(.horizontal)
    }
}

@MainActor
private struct PagingFooter: View {
    @ObservedObject var store: VideoPageStore
    var automatic = true
    var viewportHeight: CGFloat = 0
    var automaticEnabled = true
    var coordinateSpace = "browse.results"
    var automaticLoad: (() async -> Void)? = nil
    let load: () -> Void
    @Environment(\.browseViewportHeight) private var browseViewportHeight
    @Environment(\.browseTracking) private var browseTracking
    @State private var sentinelVisible = false
    @State private var measuredVideoCount = -1
    @State private var pagingTask: Task<Void, Never>?

    private var automaticKey: String {
        "\(automaticEnabled)|\(browseTracking)|\(sentinelVisible)|\(measuredVideoCount)|\(store.videos.count)|\(store.loading)|\(store.hasMore)|\(store.error ?? "")"
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
                Text("继续浏览以加载更多…").font(.footnote).foregroundStyle(.secondary).padding()
            } else {
                Text("已经到底了").font(.footnote).foregroundStyle(.secondary).padding()
            }
        }.frame(maxWidth: .infinity)
            .background {
                if automatic {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SearchFooterFrameKey.self,
                                               value: geometry.frame(in: .named(coordinateSpace)))
                            .preference(key: PagingMeasurementKey.self,
                                        value: PagingMeasurement(frame: geometry.frame(in: .named(coordinateSpace)),
                                                                 count: store.videos.count))
                    }
                }
            }
            .onPreferenceChange(SearchFooterFrameKey.self) { frame in
                guard automaticLoad == nil else { return }
                // Unlike onAppear, this does not eagerly fetch a whole eager VStack.
                let height = viewportHeight > 0 ? viewportHeight : browseViewportHeight
                sentinelVisible = height > 0 && (frame.map { $0.width > 0 && $0.maxY > 0 && $0.minY < height } ?? false)
            }
            .onPreferenceChange(PagingMeasurementKey.self) { measurement in
                measuredVideoCount = measurement?.count ?? -1
                guard automaticLoad != nil else { return }
                let height = viewportHeight > 0 ? viewportHeight : browseViewportHeight
                sentinelVisible = height > 0 && (measurement.map {
                    $0.frame.width > 0 && $0.frame.maxY > 0 && $0.frame.minY < height
                } ?? false)
            }
            .task(id: automaticKey) {
                guard automatic, automaticEnabled, browseTracking, sentinelVisible, !store.loading, store.hasMore,
                      store.error == nil, !store.videos.isEmpty else { return }
                guard automaticLoad == nil || measuredVideoCount == store.videos.count else { return }
                // Own the request separately: loading/geometry updates must not
                // cancel it, but leaving this page must cancel URLSession work.
                if let automaticLoad = automaticLoad {
                    pagingTask = Task { await automaticLoad() }
                }
                else { load() }
            }
            .onDisappear {
                sentinelVisible = false
                pagingTask?.cancel()
                pagingTask = nil
            }
            .onChange(of: automaticEnabled) { enabled in
                if !enabled { pagingTask?.cancel(); pagingTask = nil }
            }
    }
}

private struct SearchFooterFrameKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

private struct PagingMeasurement: Equatable {
    let frame: CGRect
    let count: Int
}

private struct PagingMeasurementKey: PreferenceKey {
    static var defaultValue: PagingMeasurement? = nil
    static func reduce(value: inout PagingMeasurement?, nextValue: () -> PagingMeasurement?) {
        value = nextValue() ?? value
    }
}

/// The eager recommendation stack is already laid out offscreen. Only intersection
/// with the measured ScrollView viewport is permission to reveal another local batch.
private struct RecommendationGroupsFooter: View {
    @Binding var visibleGroups: Int
    let total: Int
    let enabled: Bool
    @Environment(\.browseViewportHeight) private var viewportHeight
    @Environment(\.browseTracking) private var tracking
    @State private var visible = false

    var body: some View {
        Text(visibleGroups < total ? "继续浏览以展示更多推荐…" : "已经到底了")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding()
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: SearchFooterFrameKey.self,
                                           value: geometry.frame(in: .named("browse.results")))
                }
            }
            .onPreferenceChange(SearchFooterFrameKey.self) { frame in
                visible = viewportHeight > 0 && (frame.map {
                    $0.width > 0 && $0.maxY > 0 && $0.minY < viewportHeight
                } ?? false)
            }
            .task(id: "\(tracking)|\(enabled)|\(visible)|\(visibleGroups)|\(total)") {
                guard tracking, enabled, visible, visibleGroups < total else { return }
                visible = false
                visibleGroups = min(total, visibleGroups + 4)
            }
            .onDisappear { visible = false }
    }
}

/// Let the retained native scroll own its offset; only a changed query or an
/// explicit refresh resets it. Visibility geometry is used solely for pagination.
@MainActor
private struct SearchResultsScroll: View {
    @ObservedObject var store: VideoPageStore
    let query: String
    let visible: Bool
    let resetKey: String
    let resetRevision: Int
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
                        VideoGrid(videos: store.videos, columns: 3)
                        PagingFooter(store: store, automatic: true, viewportHeight: viewport.size.height,
                                      automaticEnabled: tracking && visible, coordinateSpace: "search.results", automaticLoad: { await nextPage() }, load: load)
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
                .environment(\.browseViewportHeight, viewport.size.height)
                .environment(\.browseTracking, tracking && visible)
                .environment(\.posterCoordinateSpace, "search.results")
                .refreshable { await refresh() }
                .onChange(of: resetKey) { _ in proxy.scrollTo("search.top", anchor: .top) }
                .onChange(of: resetRevision) { _ in proxy.scrollTo("search.top", anchor: .top) }
                .onAppear { tracking = true }
                .onDisappear { tracking = false }
            }
        }
    }
    let nextPage: () async -> Void
}

@MainActor
struct HomeView: View {
    @EnvironmentObject private var catalog: BrowseCatalog
    @EnvironmentObject private var library: LibraryStore
    @State private var selection = "recommended"
    @State private var dismissedResume: String?
    @ObservedObject private var account = AccountStore.shared
    @State private var visited = ["recommended"]
    @State private var visible = false
    private var pageContext: String { BrowsePageCache.contextKey(catalog) }
    private var selectedPage: String {
        catalog.categories.contains(where: { $0.id == selection }) ? selection : "recommended"
    }

    private var resumeVideo: SavedVideo? {
        guard let video = library.history.first, !video.id.isEmpty,
              video.position.isFinite, video.position > 0 else { return nil }
        let key = video.id + "|" + String(video.updated.timeIntervalSince1970)
        return dismissedResume == key ? nil : video
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = catalog.error, catalog.categories.isEmpty {
                BrowseMessage(title: "分类加载失败", detail: error) { Task { await catalog.load() } }
                Spacer()
            } else if catalog.loading && catalog.categories.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalog.categories.isEmpty {
                BrowseMessage(title: "暂无支持的分类") { Task { await catalog.load() } }
                Spacer()
            } else {
                GeometryReader { viewport in
                    ZStack {
                        ForEach(visited, id: \.self) { key in
                            Group {
                                if key == "recommended" {
                                    RecommendationsView(active: visible && selectedPage == key)
                                } else if let category = catalog.categories.first(where: { $0.id == key }) {
                                    CategoryVideosView(category: category, active: visible && selectedPage == key)
                                }
                            }
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .opacity(selectedPage == key ? 1 : 0)
                            .allowsHitTesting(visible && selectedPage == key)
                            .accessibilityHidden(!visible || selectedPage != key)
                        }
                    }
                }.id(pageContext)
            }
        }
        .background(BrowseTheme.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                BrowseTopBar()
                ChoiceStrip(title: nil, choices: [Choice(id: "recommended", title: "推荐")] + catalog.categories.map {
                    Choice(id: $0.id, title: BrowseCatalog.family($0.name) ?? $0.name)
                }, selection: $selection).padding(.horizontal, 8).padding(.vertical, 6)
            }.modifier(FloatingBrowseHeader())
        }
        .navigationTitle("牛牛视频").navigationBarTitleDisplayMode(.inline)
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
                }.frame(height: 42).padding(12).background(BrowseTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).stroke(BrowseTheme.accent.opacity(0.18), lineWidth: 1) }
                    .padding(.horizontal).padding(.vertical, 8).background(BrowseTheme.background.opacity(0.96))
            } else {
                // Keep the retained scroll viewport unchanged when history or
                // dismissal changes while navigating to and from a detail page.
                Color.clear.frame(height: 82).accessibilityHidden(true)
            }
        }
        .modifier(SearchMorphHost())
        .onAppear { visible = true; retainBrowseKey(selectedPage, in: &visited) }
        .onDisappear { visible = false }
        .onChange(of: selectedPage) { retainBrowseKey($0, in: &visited) }
        .onChange(of: pageContext) { _ in visited = [selectedPage] }
    }
}

@MainActor
private struct RecommendationsView: View {
    @EnvironmentObject private var catalog: BrowseCatalog
    @ObservedObject private var account = AccountStore.shared
    var active = true
    var body: some View {
        let context = BrowsePageCache.contextKey(catalog)
        RecommendationPageView(active: active,
            store: BrowsePageCache.shared.recommendation(context: context), requestKey: context)
            .id(context)
    }
}

@MainActor
private struct RecommendationPageView: View {
    @EnvironmentObject private var catalog: BrowseCatalog
    @ObservedObject private var account = AccountStore.shared
    let active: Bool
    @ObservedObject var store: RecommendationPageStore
    let requestKey: String

    var body: some View {
        BrowseScroll(resetRevision: store.scrollResetRevision, active: active) {
            VStack(alignment: .leading, spacing: 22) {
                if let video = store.blocks.first?.videos.first {
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
                        .modifier(BrowseAnchor(id: "recommend.hero." + video.id))
                }
                ForEach(Array(store.blocks.prefix(store.visibleGroups))) { block in
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
                        VideoGrid(videos: Array(block.videos.prefix(6)), columns: 3, anchorPrefix: "recommend.\(block.id).")
                    }
                }
                if !store.blocks.isEmpty {
                    RecommendationGroupsFooter(visibleGroups: $store.visibleGroups, total: store.blocks.count,
                                               enabled: active && !store.loading && store.error == nil)
                }
                if store.loading { ProgressView("正在加载推荐…").frame(maxWidth: .infinity).padding() }
                if let error = store.error {
                    BrowseMessage(title: "推荐加载失败", detail: error) { Task { await load() } }
                } else if !store.loading && store.blocks.isEmpty {
                    BrowseMessage(title: "暂无推荐", detail: "可切换上方分类浏览影片")
                }
            }.padding(.vertical)
        }
        .task(id: "\(requestKey)|\(active)") {
            guard active else { return }
            while store.loading {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            }
            guard !Task.isCancelled, !store.completed, store.error == nil else { return }
            await load()
        }
        .refreshable {
            store.scrollResetRevision += 1
            store.visibleGroups = 4
            await load()
        }
        .background(BrowseTheme.background)
    }

    @MainActor private func load() async {
        guard active, !store.loading else { return }
        store.loading = true
        let identity = requestKey
        store.error = nil
        defer { store.loading = false }
        do {
            let response = try await APIClient.shared.recommendations()
            try Task.checkCancellation()
            guard identity == BrowsePageCache.contextKey(catalog) else { return }
            var seen = Set<String>()
            store.blocks = response.filter { catalog.accepts($0) && !$0.videos.isEmpty && seen.insert($0.id).inserted }
                .map { block in
                    var videos = Set<String>()
                    return Recommendation(id: block.id, title: block.title,
                                          videos: block.videos.filter { !$0.id.isEmpty && videos.insert($0.id).inserted })
                }
            store.completed = true
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, identity == BrowsePageCache.contextKey(catalog) else { return }
            store.error = error.localizedDescription
        }
    }
}

@MainActor
struct CategoryVideosView: View {
    let category: VideoCategory
    var active = true
    @EnvironmentObject private var catalog: BrowseCatalog
    @ObservedObject private var account = AccountStore.shared
    @State private var filters: [String: String] = ["by": "time"]
    @AppStorage("niuniu.gridColumns") private var columnCount = 3
    @State private var showFilters = false
    @State private var visited: [String] = []
    @State private var pageFilters: [String: [String: String]] = [:]

    private var requestKey: String {
        "category|" + String(describing: [category.id] + filters.keys.sorted().filter { !(filters[$0] ?? "").isEmpty }.map { "\($0)=\(filters[$0] ?? "")" })
    }
    private var context: String { BrowsePageCache.contextKey(catalog) }

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
        GeometryReader { viewport in
            ZStack {
                ForEach(visited.contains(requestKey) ? visited : Array((visited + [requestKey]).suffix(6)), id: \.self) { key in
                    let snapshot = pageFilters[key] ?? filters
                    let pageActive = active && key == requestKey
                    ObservedVideoPage(store: BrowsePageCache.shared.page(context: context, key: key)) { store in
        BrowseScroll(resetRevision: store.scrollResetRevision, active: pageActive) {
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
                let summary = ["class", "area", "year", "state"].compactMap { snapshot[$0] }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                }
                VideoGrid(videos: store.videos, columns: columnCount == 2 ? 2 : 3)
                PagingFooter(store: store, automaticEnabled: pageActive, automaticLoad: { await load(store, filters: snapshot, reset: false, active: pageActive) }) {
                    Task { await load(store, filters: snapshot, reset: false, active: pageActive) }
                }
            }.padding(.vertical, 10)
        }
        .task(id: "\(context)|\(key)|\(pageActive)") {
            guard pageActive else { return }
            if store.needsFirstPage {
                while store.loading {
                    do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                }
                guard !Task.isCancelled, store.needsFirstPage else { return }
                await load(store, filters: snapshot, reset: false, active: pageActive)
            }
        }
        .refreshable {
            store.scrollResetRevision += 1
            await load(store, filters: snapshot, reset: true, active: pageActive)
        }
                    }
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .opacity(pageActive ? 1 : 0)
                    .allowsHitTesting(pageActive)
                    .accessibilityHidden(!pageActive)
                }
            }
        }.id(context)
        .onAppear { rememberPage() }
        .onChange(of: requestKey) { _ in rememberPage() }
        .onChange(of: context) { _ in visited = []; pageFilters = [:]; rememberPage() }
        .background(BrowseTheme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
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

    private func rememberPage() {
        pageFilters[requestKey] = filters
        retainBrowseKey(requestKey, in: &visited)
        pageFilters = pageFilters.filter { visited.contains($0.key) }
    }

    private func load(_ store: VideoPageStore, filters: [String: String], reset: Bool, active: Bool) async {
        guard active else { return }
        let identity = context
        await store.load(reset: reset, category: category.id, filters: filters.filter { !$0.value.isEmpty },
                         shouldCommit: { identity == BrowsePageCache.contextKey(catalog) })
    }
}

@MainActor
struct RankingView: View {
    @EnvironmentObject private var catalog: BrowseCatalog
    @ObservedObject private var account = AccountStore.shared
    @State private var categoryID = ""
    @State private var order = ""
    @State private var visited: [String] = []
    @State private var parameters: [String: [String]] = [:]
    @State private var visible = false
    private var requestKey: String {
        "rank|" + String(describing: [selectedID, selectedOrder])
    }
    private var context: String { BrowsePageCache.contextKey(catalog) }
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
            GeometryReader { viewport in
                ZStack {
                    ForEach(visited.contains(requestKey) ? visited : Array((visited + [requestKey]).suffix(6)), id: \.self) { key in
                        let snapshot = parameters[key] ?? [selectedID, selectedOrder]
                        let pageActive = visible && key == requestKey
                        ObservedVideoPage(store: BrowsePageCache.shared.page(context: context, key: key)) { store in
               BrowseScroll(resetRevision: store.scrollResetRevision, active: pageActive) {
                 VStack(spacing: 14) {
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
                      if let error = catalog.error, catalog.categories.isEmpty {
                        BrowseMessage(title: "分类加载失败", detail: error) { Task { await catalog.load() } }
                     } else if catalog.loading && catalog.categories.isEmpty {
                        ProgressView().padding()
                     } else if snapshot[0].isEmpty {
                        BrowseMessage(title: "暂无支持的分类")
                     } else if snapshot[1].isEmpty {
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
                            }.buttonStyle(BrowsePressStyle()).modifier(BrowseAnchor(id: "rank." + video.id))
                        }
                        if store.loading { ProgressView("正在加载榜单…").padding() }
                        else if let error = store.error {
                            BrowseMessage(title: "榜单加载失败", detail: error) { Task { await load(store, parameters: snapshot, active: pageActive) } }
                        } else if store.videos.isEmpty {
                            BrowseMessage(title: "暂无上榜影片", detail: "稍后刷新，或切换其他分类")
                        }
                    }
                }.padding()
             }.refreshable {
                  store.scrollResetRevision += 1
                  await load(store, parameters: snapshot, active: pageActive, reset: true)
             }
              .task(id: "\(context)|\(key)|\(pageActive)") {
                  guard pageActive else { return }
                  while store.loading {
                      do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                  }
                  guard !Task.isCancelled, store.needsRank else { return }
                  await load(store, parameters: snapshot, active: pageActive)
              }
                        }
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .opacity(pageActive ? 1 : 0)
                        .allowsHitTesting(pageActive)
                        .accessibilityHidden(!pageActive)
                    }
                }
            }.id(context)
        }
        .background(BrowseTheme.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                BrowseTopBar()
                ChoiceStrip(title: nil, choices: catalog.categories.map { Choice(id: $0.id, title: BrowseCatalog.family($0.name) ?? $0.name) }, selection: Binding(get: { selectedID }, set: { categoryID = $0 }))
                    .padding(.horizontal, 8).padding(.vertical, 8)
                ChoiceStrip(title: "榜单", choices: rankChoices,
                            selection: Binding(get: { selectedOrder }, set: { order = $0 }))
                    .padding(.horizontal).padding(.bottom, 8)
            }.modifier(FloatingBrowseHeader())
        }
        .navigationTitle("榜单").navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true; rememberPage() }
        .onDisappear { visible = false }
        .onChange(of: requestKey) { _ in rememberPage() }
        .onChange(of: context) { _ in visited = []; parameters = [:]; rememberPage() }
        .modifier(SearchMorphHost())
    }

    private func rememberPage() {
        parameters[requestKey] = [selectedID, selectedOrder]
        retainBrowseKey(requestKey, in: &visited)
        parameters = parameters.filter { visited.contains($0.key) }
    }

    private func load(_ store: VideoPageStore, parameters: [String], active: Bool, reset: Bool = false) async {
        guard active else { return }
        let identity = context
        await store.loadRank(category: parameters[0], order: parameters[1], reset: reset,
                             shouldCommit: { identity == BrowsePageCache.contextKey(catalog) })
    }
}

@MainActor
private final class SearchActivity: ObservableObject {
    var visible = false
    var revision = 0
    func update(_ visible: Bool) {
        if self.visible != visible { revision += 1 }
        self.visible = visible
    }
}

@MainActor
struct SearchView: View {
    var morphPresented = true
    var morphReady = true
    var onCancel: (() -> Void)? = nil
    @Environment(\.searchMorphNamespace) private var searchNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var catalog: BrowseCatalog
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var store = VideoPageStore()
    @StateObject private var activity = SearchActivity()
    @State private var text = ""
    @State private var submitted = ""
    @State private var categoryID = ""
    @State private var submission = 0
    @State private var requestKey: String?
    @State private var scrollResetRevision = 0
    @State private var suggestions: [String] = []
    @State private var hotWords: [String] = []
    @State private var suggestLoading = false
    @State private var suggestError: String?
    @State private var hotLoading = false
    @State private var hotError: String?
    @State private var suggestionRetry = 0
    @State private var suggestionGeneration = UUID()
    @State private var searchActionTask: Task<Void, Never>?
    @State private var hotActionTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    private var selectedID: String { catalog.categories.contains(where: { $0.id == categoryID }) ? categoryID : "" }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchRequestKey: String {
        "\(account.token)|\(catalog.visibilityContext)|\(APIClient.shared.isTeenModeEnabled)|\(submission)|\(selectedID)|\(submitted)"
    }
    private var visibleSearchKey: String { "\(morphPresented)|\(searchRequestKey)" }
    private var suggestionKey: String { "\(morphPresented)|\(account.token)|\(catalog.visibilityContext)|\(trimmedText)|\(suggestionRetry)" }
    private var hotKey: String { "\(morphPresented)|\(account.token)|\(catalog.visibilityContext)" }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索影片、演员或关键词", text: $text).focused($focused)
                    .autocorrectionDisabled()
                    .submitLabel(.search).onSubmit { submit(text) }
                if !text.isEmpty {
                    Button { text = ""; submitted = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("清空搜索").frame(width: 36, height: 44)
                }
                Button("搜索") { submit(text) }.disabled(trimmedText.isEmpty)
            }
            .padding(.horizontal, 13).frame(minHeight: 44)
            .background {
                if let namespace = searchNamespace, !reduceMotion {
                    GlassSearchPill()
                        .matchedGeometryEffect(id: "browse.search.pill", in: namespace, isSource: morphPresented)
                } else { GlassSearchPill() }
            }
            if let onCancel = onCancel {
                Button("取消") { focused = false; onCancel() }
                    .frame(minHeight: 44).accessibilityLabel("取消搜索，返回原列表位置")
            }
        }.padding(.horizontal).padding(.vertical, 6)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = catalog.error {
                BrowseMessage(title: "分类加载失败", detail: error) { Task { await catalog.load() } }
            } else if catalog.loading {
                ProgressView().padding()
            } else if catalog.categories.isEmpty {
                BrowseMessage(title: "暂无可搜索的分类") { Task { await catalog.load() } }
            }
            if submitted.isEmpty || (focused && trimmedText != submitted) {
                BrowseScroll(active: morphPresented) {
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
                             Button { refreshHot() } label: {
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
                             BrowseMessage(title: "热门加载失败", detail: error) { refreshHot() }
                         } else if hotWords.isEmpty {
                             Text("服务器暂无热门搜索").font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding()
                }
            } else {
                SearchResultsScroll(store: store, query: submitted, visible: morphPresented,
                                     resetKey: searchRequestKey, resetRevision: scrollResetRevision,
                                     load: {
                                         searchActionTask?.cancel()
                                         searchActionTask = Task { await load(reset: false) }
                                     },
                                     refresh: {
                                         scrollResetRevision += 1
                                         await load(reset: true)
                                      }, nextPage: { await load(reset: false) })
                    .opacity(requestKey == searchRequestKey ? 1 : 0)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                searchHeader
                if !submitted.isEmpty && !(focused && trimmedText != submitted) {
                    ChoiceStrip(title: nil, choices: [Choice(id: "", title: "全部")] + catalog.categories.map { Choice(id: $0.id, title: BrowseCatalog.family($0.name) ?? $0.name) }, selection: Binding(get: { selectedID }, set: { categoryID = $0 }))
                        .padding(.horizontal, 8).padding(.vertical, 8)
                }
            }
        }
        // One canvas behind content, transparent header and all container safe
        // areas. Only the pill/category controls carry their own glass surface;
        // Reduce Transparency must not turn the whole header into surface color.
        .background {
            BrowseTheme.background.ignoresSafeArea(.container, edges: .all)
        }
        .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
        .onChange(of: morphReady) { ready in
            // Focus only after expansion. A detail pop does not rerun this edge
            // or force the keyboard over retained search results.
            focused = ready && morphPresented
        }
        .onChange(of: morphPresented) { visible in
            activity.update(visible)
            if !visible {
                focused = false
                searchActionTask?.cancel(); searchActionTask = nil
                hotActionTask?.cancel(); hotActionTask = nil
            }
        }
        .onDisappear {
            activity.update(false)
            searchActionTask?.cancel(); searchActionTask = nil
            hotActionTask?.cancel(); hotActionTask = nil
        }
        .onAppear { activity.update(morphPresented) }
        .task(id: suggestionKey) { guard morphPresented else { return }; activity.update(true); await loadSuggestions() }
        .task(id: hotKey) {
            guard morphPresented else { return }
            activity.update(true)
            while hotLoading {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            }
            guard !Task.isCancelled, morphPresented else { return }
            await loadHot()
        }
        .task(id: visibleSearchKey) {
            guard morphPresented else { return }
            activity.update(true)
            guard !submitted.isEmpty else { requestKey = nil; return }
            if requestKey != searchRequestKey {
                requestKey = searchRequestKey
                await load(reset: true)
            } else if store.needsFirstPage {
                // The navigation lifetime can cancel page one before it commits.
                // Resume without clearing any completed pages or remembering a false success.
                while store.loading {
                    do { try await Task.sleep(nanoseconds: 20_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled, morphPresented, store.needsFirstPage else { return }
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
        guard morphPresented, !Task.isCancelled, !submitted.isEmpty else { return }
        guard reset || requestKey == searchRequestKey else { return }
        let revision = activity.revision
        await store.load(reset: reset, category: selectedID, query: submitted,
                         shouldCommit: { activity.visible && activity.revision == revision })
    }

    private func loadSuggestions() async {
        guard morphPresented, !Task.isCancelled else { return }
        let identity = suggestionKey
        let revision = activity.revision
        let generation = UUID()
        suggestionGeneration = generation
        let query = trimmedText
        suggestions = []
        suggestError = nil
        suggestLoading = false
        guard !query.isEmpty else { return }
        suggestLoading = true
        defer { if suggestionGeneration == generation { suggestLoading = false } }
        do {
            try await Task.sleep(nanoseconds: 280_000_000)
            guard activity.visible, activity.revision == revision, morphPresented, identity == suggestionKey else { return }
            let response = try await APIClient.shared.suggest(keyword: query)
            try Task.checkCancellation()
            guard activity.visible, activity.revision == revision, morphPresented, identity == suggestionKey else { return }
            var seen = Set<String>()
            suggestions = response.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, activity.visible, activity.revision == revision, morphPresented, identity == suggestionKey else { return }
            suggestError = error.localizedDescription
        }
    }

    private func loadHot() async {
        guard morphPresented, !Task.isCancelled, !hotLoading else { return }
        let identity = hotKey
        let revision = activity.revision
        hotLoading = true
        hotError = nil
        defer { hotLoading = false }
        do {
            let configuration = try await APIClient.shared.configuration()
            try Task.checkCancellation()
            guard activity.visible, activity.revision == revision, morphPresented, identity == hotKey else { return }
            // Verified in SexyConfig.java: @SerializedName("search_hot_words") List<String>.
            guard let response = configuration["search_hot_words"] as? [String] else {
                hotWords = []
                return
            }
            var seen = Set<String>()
            hotWords = response.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, activity.visible, activity.revision == revision, morphPresented, identity == hotKey else { return }
            hotError = error.localizedDescription
        }
    }

    private func refreshHot() {
        guard morphPresented else { return }
        hotActionTask?.cancel()
        hotActionTask = Task { await loadHot() }
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
