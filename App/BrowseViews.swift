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

/// Only service-provided identifiers for the six supported content families are used.
@MainActor
final class BrowseCatalog: ObservableObject {
    @Published private(set) var categories: [VideoCategory] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

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
            let order = ["电影", "剧集", "综艺", "动漫", "短剧", "直播"]
            var seen = Set<String>()
            categories = response.filter {
                Self.family($0.name) != nil && !$0.id.isEmpty && seen.insert($0.id).inserted
            }.sorted {
                (order.firstIndex(of: Self.family($0.name) ?? "") ?? 99)
                    < (order.firstIndex(of: Self.family($1.name) ?? "") ?? 99)
            }
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
            hasMore = !additions.isEmpty
        } catch is CancellationError {
        } catch {
            guard request == generation else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("首页", systemImage: "house.fill") }
            NavigationStack { RankingView() }
                .tabItem { Label("榜单", systemImage: "chart.bar.fill") }
            NavigationStack { ProfileView() }
                .tabItem { Label("我", systemImage: "person.fill") }
        }
        .background(BrowseTheme.background)
        .toolbarBackground(BrowseTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
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
    let load: () -> Void
    var body: some View {
        Group {
            if store.loading {
                ProgressView("正在加载…").padding()
            } else if let error = store.error {
                BrowseMessage(title: "加载失败", detail: error, retry: load)
            } else if store.videos.isEmpty {
                BrowseMessage(title: "暂无内容", detail: "试试其他分类或筛选条件")
            } else if store.hasMore {
                Button("加载更多", action: load).buttonStyle(.bordered).padding()
            } else {
                Text("已经到底了").font(.footnote).foregroundStyle(.secondary).padding()
            }
        }.frame(maxWidth: .infinity)
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
        .task { await load() }
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
                return Choice(id: value, title: period.map { "\(name) · \($0)" } ?? name)
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
                ChoiceStrip(title: nil, choices: [Choice(id: "", title: "全部")] + catalog.categories.map { Choice(id: $0.id, title: BrowseCatalog.family($0.name) ?? $0.name) }, selection: Binding(get: { selectedID }, set: { categoryID = $0 }))
                    .padding(.vertical, 8)
                BrowseScroll {
                    VStack(spacing: 16) {
                        Text("“\(submitted)”的搜索结果").font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                        VideoGrid(videos: store.videos, columns: 3)
                        PagingFooter(store: store) { Task { await load(reset: false) } }
                    }.padding(.vertical)
                }.refreshable { await load(reset: true) }
            }
        }
        .background(BrowseTheme.background)
        .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(trimmedText)|\(suggestionRetry)") { await loadSuggestions() }
        .task { await loadHot() }
        .task(id: "\(submission)|\(selectedID)|\(submitted)") {
            if !submitted.isEmpty { await load(reset: true) }
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

    private func profileText(_ keys: [String]) -> String {
        for key in keys {
            let value = account.profile.text(key).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && value != "<null>" { return value }
        }
        return ""
    }

    private var nickname: String {
        let value = profileText(["nickname", "nick_name", "user_nick_name", "user_name", "username"])
        return account.isLoggedIn ? (value.isEmpty ? "牛牛用户" : value) : "欢迎来到牛牛"
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
        HStack(spacing: 16) {
            AsyncImage(url: URL(string: profileText(["avatar", "avatar_url", "user_portrait", "portrait"]))) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else {
                    ZStack {
                        BrowseTheme.green.opacity(0.18)
                        Image(systemName: "person.fill").font(.system(size: 28)).foregroundStyle(BrowseTheme.green)
                    }
                }
            }.frame(width: 66, height: 66).clipShape(Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(nickname).font(.title2.bold()).foregroundStyle(.primary)
                Text(account.isLoggedIn ? "账号资料与个人中心" : "登录 / 注册，管理账号收藏")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }

    var body: some View {
        List {
            Section {
                if account.isLoggedIn {
                    NavigationLink { AccountProfileView() } label: { profileHeader }
                } else {
                    Button { showLogin = true } label: { profileHeader }.buttonStyle(BrowsePressStyle())
                }
                NavigationLink { MemberCenterView() } label: {
                    HStack {
                        Label("会员中心", systemImage: "crown.fill").foregroundStyle(.primary)
                        Spacer()
                        Text(membership).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 6)
                }
            }
            Section("我的内容") {
                NavigationLink { SavedLibraryView(kind: .favorites) } label: {
                    Label("游客收藏（\(library.favorites.count)）", systemImage: "heart")
                }
                NavigationLink { AccountLibraryView() } label: {
                    Label("账号收藏", systemImage: "heart.text.square")
                }
                NavigationLink { SavedLibraryView(kind: .history) } label: {
                    Label("观看历史（\(library.history.count)）", systemImage: "clock")
                }
                NavigationLink { DownloadsView() } label: { Label("我的下载", systemImage: "arrow.down.circle") }
                NavigationLink { MessagesView() } label: {
                    Label("我的评论", systemImage: "text.bubble")
                }
            }
            Section("账号与服务") {
                NavigationLink { AccountCenterView() } label: { Label("账号中心", systemImage: "person.crop.circle") }
                NavigationLink { MessagesView() } label: { Label("消息通知", systemImage: "bell") }
                NavigationLink { FeedbackView() } label: { Label("意见反馈", systemImage: "square.and.pencil") }
                ShareLink(item: URL(string: "https://www.xinniuniushipin.com/")!,
                          subject: Text("牛牛视频"), message: Text("快来牛牛视频发现喜欢的影片")) {
                    Label("分享 APP", systemImage: "square.and.arrow.up").foregroundStyle(.primary)
                }
                NavigationLink { SettingsView() } label: { Label("设置", systemImage: "gearshape") }
            }
            Section {
                Text("游客收藏与观看历史保存在本机；账号收藏和评论来自登录账号。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = account.credentialError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if let error = profileError {
                    BrowseMessage(title: "账号资料加载失败", detail: error) { Task { await refreshProfile() } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listRowBackground(BrowseTheme.surface)
        .background(BrowseTheme.background)
        .navigationTitle("我").navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrowseTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                LoginView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showLogin = false } } }
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .onChange(of: account.isLoggedIn) { loggedIn in if loggedIn { showLogin = false } }
        .task(id: account.isLoggedIn) { await refreshProfile() }
        .refreshable { await refreshProfile() }
    }

    private func refreshProfile() async {
        profileError = nil
        guard account.isLoggedIn else { return }
        do { try await account.refreshProfile() }
        catch is CancellationError { }
        catch { profileError = error.localizedDescription }
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
