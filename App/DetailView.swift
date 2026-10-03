import SwiftUI
import AVKit
import Combine
import UIKit

public struct DetailView: View {
    public let videoID: String
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = PlaybackController()
    @StateObject private var settings: PlaybackPreferences
    @StateObject private var danmaku: DanmakuStore
    @ObservedObject private var downloads = DownloadsStore.shared
    @ObservedObject private var account = AccountStore.shared
    @State private var video: Video?
    @State private var related: [Video] = []
    @State private var sourceIndex = 0
    @State private var episodeIndex = 0
    @State private var group = 0
    @State private var reversed = false
    @State private var tab = 0
    @State private var loading = false
    @State private var resolving = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var relatedFailure: String?
    @State private var resolved: ResolvedVideo?
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var playing = false
    @State private var fullScreen = false
    @State private var landscape = true
    @State private var locked = false
    @State private var fill = false
    @State private var tools = true
    @State private var introPending = false
    @State private var backgroundPauseTask: Task<Void, Never>?
    @State private var resolveTask: Task<Void, Never>?
    @State private var resolutionGeneration = 0
    @State private var handledEnd = false
    @State private var savedHistorySecond = -1
    @State private var sheet: DetailSheet?
    @State private var shareItems: [Any] = []
    @State private var accountFavorite: Bool?
    @State private var favoriteBusy = false
    @State private var reportBusy = false
    @State private var selectedDownloads = Set<Int>()
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloading = false
    @State private var holdOriginalRate: Float?
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(videoID: String) {
        self.videoID = videoID
        _settings = StateObject(wrappedValue: PlaybackPreferences(videoID: videoID))
        _danmaku = StateObject(wrappedValue: DanmakuStore(videoID: videoID))
    }
    private var source: VideoSource? { guard let video, video.sources.indices.contains(sourceIndex) else { return nil }; return video.sources[sourceIndex] }
    private var episodes: [Episode] { source?.episodes ?? [] }
    private var episode: Episode? { episodes.indices.contains(episodeIndex) ? episodes[episodeIndex] : nil }
    private var favorite: Bool { AccountStore.shared.isLoggedIn ? accountFavorite ?? false : library.isFavorite(videoID) }
    private var errorText: String? { failure ?? playback.error }

    public var body: some View {
        VStack(spacing: 0) {
            if !fullScreen { playerArea }
            Picker("详情标签", selection: $tab) { Text("视频").tag(0); Text("评论").tag(1) }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            if tab == 1 { CommentsView(videoID: videoID) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if loading { ProgressView("正在加载详情…") }
                        if let video { information(video); actions; episodeSection; recommendations }
                        else if let failure { Text(failure).foregroundStyle(.red); Button("重试详情") { Task { await loadDetail() } } }
                        if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                    }.padding()
                }
            }
        }
        .navigationTitle(video?.name ?? "影片详情").navigationBarTitleDisplayMode(.inline)
        .task { configureCallbacks(); await loadDetail() }
        .onReceive(clock) { _ in tickTimer() }
        .onChange(of: scenePhase) { phase in backgroundChanged(phase) }
        .onChange(of: account.isLoggedIn) { _ in Task { await loadFavoriteStatus() } }
        .onDisappear {
            if !fullScreen && !playback.isPictureInPicture {
                recordHistory(); resolveTask?.cancel(); resolutionGeneration += 1; resolving = false
                playback.pause(); playing = false
            }
        }
        .sheet(item: Binding(get: { fullScreen ? nil : sheet }, set: { sheet = $0 })) { value in sheetContent(value) }
        .fullScreenCover(isPresented: $fullScreen) {
            GeometryReader { geometry in
                ZStack { Color.black.ignoresSafeArea(); playerArea.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    .preferredColorScheme(.dark)
                    .overlay(alignment: .topLeading) {
                        if !locked { Button { fullScreen = false } label: { Label("退出全屏", systemImage: "xmark").padding(12).background(.ultraThinMaterial, in: Capsule()) }.padding() }
                    }
                    .onAppear { requestOrientation(landscape ? .landscape : .portrait) }
                    .onChange(of: landscape) { requestOrientation($0 ? .landscape : .portrait) }
                    .accessibilityLabel(geometry.size.width > geometry.size.height ? "横屏播放器" : "竖屏播放器")
            }.onDisappear { requestOrientation(.portrait); locked = false }
                .sheet(item: $sheet) { value in sheetContent(value) }
        }
    }

    private var playerArea: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                NativePlayer(player: playback.player, onPictureInPictureChanged: { playback.isPictureInPicture = $0 }, videoGravity: fill ? .resizeAspectFill : .resizeAspect)
                    .allowsHitTesting(!locked)
                if !locked { DanmakuOverlay(store: danmaku) }
                if resolving { ProgressView("正在解析播放地址…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                if let errorText {
                    VStack(spacing: 12) {
                        Text(errorText).multilineTextAlignment(.center)
                        HStack {
                            Button("返回") { if fullScreen { fullScreen = false } else { dismiss() } }
                            Button("重试") { startEpisode(episodeIndex, resume: time) }
                            Menu("换源") { sourceButtons }
                            Button("报错") { Task { await report(update: false) } }.disabled(reportBusy || source == nil)
                        }
                        if let notice { Text(notice).font(.caption) }
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                }
                if let countdown = settings.countdown {
                    VStack { Text("\(countdown) 秒后停止播放"); Button("取消定时停止") { settings.cancelTimer() } }
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if locked {
                    Color.black.opacity(0.01).contentShape(Rectangle())
                    Button { locked = false } label: { Label("解锁", systemImage: "lock.open").padding().background(.ultraThinMaterial, in: Capsule()) }
                }
            }
            .aspectRatio(fullScreen ? nil : 16 / 9, contentMode: .fit)
            if !locked {
                gestureStrip
                if tools { playerTools }
            }
        }.background(.black).foregroundStyle(.white)
    }
    private var gestureStrip: some View {
        Text(holdOriginalRate == nil ? "单击显隐工具 · 双击播放/暂停 · 长按临时倍速" : String(format: "临时 %g× · 松手恢复", settings.holdRate))
            .font(.caption2).frame(maxWidth: .infinity).frame(height: 32).background(Color.white.opacity(0.08)).contentShape(Rectangle())
            .onTapGesture(count: 2) { togglePlay() }
            .onTapGesture(count: 1) { tools.toggle() }
            .onLongPressGesture(minimumDuration: 0.35, pressing: { down in
                if !down, let original = holdOriginalRate { playback.setRate(original); holdOriginalRate = nil; if !playing { playback.pause() } }
            }, perform: {
                if holdOriginalRate == nil { holdOriginalRate = playback.rate; playback.setRate(settings.holdRate) }
            })
    }
    private var playerTools: some View {
        VStack(spacing: 10) {
            HStack {
                Text(formatTime(time)).monospacedDigit()
                Slider(value: Binding(get: { min(time, max(1, duration)) }, set: { seek($0) }), in: 0...max(1, duration))
                    .disabled(duration <= 0).accessibilityLabel("播放进度")
                Text(formatTime(duration)).monospacedDigit()
            }.font(.caption)
            HStack {
                tool("上一集", "backward.end") { startEpisode(episodeIndex - 1) }.disabled(episodeIndex == 0 || resolving)
                tool("后退15秒", "gobackward.15") { seek(time - 15) }
                tool(playing ? "暂停" : "播放", playing ? "pause.fill" : "play.fill", action: togglePlay)
                tool("前进15秒", "goforward.15") { seek(time + 15) }
                tool("下一集", "forward.end") { startEpisode(episodeIndex + 1) }.disabled(episodeIndex + 1 >= episodes.count || resolving)
                Menu { ForEach(PlaybackPreferences.rates, id: \.self) { rate in Button(String(format: "%g×", rate)) { settings.rate = rate; playback.setRate(rate); playing = true } } }
                    label: { Text(String(format: "%g×", settings.rate)).font(.caption) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    tool("设置", "gearshape") { sheet = .settings }
                    tool("选集换源", "list.bullet") { sheet = .episodes }
                    tool(danmaku.show ? "关闭弹幕" : "打开弹幕", "text.bubble") { danmaku.show.toggle() }
                    tool("发送弹幕", "square.and.pencil") { sheet = .composer }
                    tool("弹幕样式", "textformat.size") { sheet = .danmaku }
                    tool("全屏", "arrow.up.left.and.arrow.down.right") { fullScreen.toggle() }
                    if fullScreen { tool(landscape ? "竖屏" : "横屏", "rotate.right") { landscape.toggle() } }
                    tool("锁屏", "lock") { locked = true }
                    tool(fill ? "适应" : "填充", "arrow.up.left.and.down.right.magnifyingglass") { fill.toggle() }
                    Menu("播放方式") { Button("连续播放") { settings.mode = "continuous" }; Button("单集停止") { settings.mode = "single" }; Button("单集循环") { settings.mode = "loop" } }
                    AirPlayButton().frame(width: 36, height: 36).accessibilityLabel("AirPlay 投屏")
                    tool("DLNA投屏", "tv") { if resolved != nil { sheet = .dlna } else { notice = "请先解析当前视频后投屏" } }
                    Button("画中画说明") { sheet = .pip }
                }.font(.caption)
            }
        }.padding(12)
    }
    private func tool(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(minWidth: 32, minHeight: 32) }.accessibilityLabel(label)
    }

    private func information(_ video: Video) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(video.name).font(.title2.bold())
            Text([video.year, video.area, video.category, video.score.isEmpty ? "" : "评分 \(video.score)", video.remark].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            DisclosureGroup("简介") { Text(video.introduction.isEmpty ? "暂无简介" : video.introduction).textSelection(.enabled).padding(.vertical, 8) }
            people("导演", value: video.director)
            people("主演", value: video.actor)
        }
    }
    private func people(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(value.components(separatedBy: CharacterSet(charactersIn: ",，/、")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, id: \.self) { name in
                        NavigationLink(name) { DetailPeopleSearch(query: name) }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }
    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button { Task { await toggleFavorite() } } label: { Label(favorite ? "已收藏" : "收藏", systemImage: favorite ? "heart.fill" : "heart") }.disabled(favoriteBusy)
                Button { selectedDownloads = []; sheet = .downloads } label: { Label("下载", systemImage: "arrow.down.circle") }
                Menu("分享") { Button("分享影片海报") { Task { await share(poster: true) } }; Button("分享 APP") { Task { await share(poster: false) } } }
                Button("催更") { Task { await report(update: true) } }.disabled(reportBusy)
            }.buttonStyle(.bordered)
        }
    }
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("播放线路与选集").font(.headline); Spacer(); Button("全部") { sheet = .episodes } }
            Menu("线路：\(source?.id ?? "暂无")") { sourceButtons }
            HStack {
                Picker("每50集分组", selection: $group) {
                    ForEach(0..<max(1, (episodes.count + 49) / 50), id: \.self) { value in
                        Text(reversed ? "\(max(1, episodes.count - (value + 1) * 50 + 1))–\(max(0, episodes.count - value * 50))" : "\(value * 50 + 1)–\(min(episodes.count, (value + 1) * 50))").tag(value)
                    }
                }
                Spacer(); Button(reversed ? "倒序 ↓" : "正序 ↑") { reversed.toggle(); group = max(0, (reversed ? episodes.count - 1 - episodeIndex : episodeIndex) / 50) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], spacing: 10) {
                ForEach(displayedIndices, id: \.self) { index in
                    Button { startEpisode(index) } label: { Text(episodes[index].name).font(.subheadline).frame(maxWidth: .infinity).padding(10).background(index == episodeIndex ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8)) }
                }
            }
            if episodes.isEmpty { Text("服务端没有可播放的集数").foregroundStyle(.secondary) }
        }
    }
    private var displayedIndices: [Int] {
        let indices = Array(episodes.indices)
        let sorted = reversed ? Array(indices.reversed()) : indices
        return Array(sorted.dropFirst(group * 50).prefix(50))
    }
    @ViewBuilder private var sourceButtons: some View {
        if let video {
            ForEach(Array(video.sources.enumerated()), id: \.offset) { index, item in
                Button("\(item.id)（\(item.episodes.count)集）\(index == sourceIndex ? " ✓" : "")") { switchSource(index) }
            }
        }
    }
    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("相关推荐").font(.headline)
            if let relatedFailure { Text(relatedFailure).foregroundStyle(.secondary); Button("重试推荐") { Task { await loadRelated() } } }
            ForEach(related) { item in
                NavigationLink { DetailView(videoID: item.id) } label: {
                    HStack {
                        AsyncImage(url: URL(string: item.poster)) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                            .frame(width: 55, height: 76).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading) { Text(item.name); Text(item.remark).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right")
                    }
                }.foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder private func sheetContent(_ item: DetailSheet) -> some View {
        switch item {
        case .settings: PlaybackSettingsView(settings: settings) { playback.setRate($0); playing = true }
        case .composer: DanmakuComposer(store: danmaku, episode: String(episodeIndex), time: time)
        case .danmaku: NavigationStack { DanmakuSettingsView(store: danmaku).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } } }
        case .episodes: NavigationStack { ScrollView { episodeSection.padding() }.navigationTitle("全部线路与选集").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } } }
        case .downloads: downloadPicker
        case .share: DetailShareSheet(items: shareItems)
        case .dlna:
            if let resolved { DLNADeviceView(mediaURL: resolved.url, title: video?.name ?? "视频", headers: resolved.headers) }
        case .pip:
            NavigationStack {
                Text("点击视频系统控制栏中的画中画按钮。只有系统支持且媒体可用时按钮才会出现。进入画中画后可返回桌面继续观看；非画中画进入后台会暂停。AirPlay 与画中画是否可同时使用由系统决定。")
                    .padding().navigationTitle("系统画中画").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
            }
        }
    }
    private var downloadPicker: some View {
        NavigationStack {
            List {
                Section {
                    Menu("下载线路：\(source?.id ?? "暂无")") { sourceButtons }
                    HStack {
                        Button("全选未缓存") { selectedDownloads = Set(episodes.indices.filter { cachedDownload($0) == nil }) }
                        Spacer(); Button("取消全选") { selectedDownloads = [] }
                    }.disabled(downloading)
                }
                ForEach(Array(episodes.enumerated()), id: \.offset) { index, item in
                    HStack {
                        Button {
                            if selectedDownloads.contains(index) { selectedDownloads.remove(index) } else { selectedDownloads.insert(index) }
                        } label: { Label(item.name, systemImage: selectedDownloads.contains(index) ? "checkmark.circle.fill" : "circle") }
                        .disabled(downloading || cachedDownload(index) != nil)
                        Spacer()
                        if let cached = cachedDownload(index) {
                            Text(cached.state.label).font(.caption).foregroundStyle(.secondary)
                            if [.queued, .downloading].contains(cached.state) { Button("取消") { downloads.cancel(cached.id) } }
                        }
                    }
                }
                if let notice { Text(notice).font(.caption) }
                if downloading { ProgressView("逐集解析并加入真实下载队列…"); Button("停止加入队列") { downloadTask?.cancel() } }
                NavigationLink("查看所有下载") { DownloadsView() }
            }.navigationTitle("下载选集")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("下载所选 \(selectedDownloads.count) 集") { queueDownloads() }.disabled(selectedDownloads.isEmpty || downloading) }
                }
        }
    }
    private func downloadTitle(_ index: Int) -> String { "\(video?.name ?? videoID) · \(source?.id ?? "") · \(episodes[index].name)" }
    private func cachedDownload(_ index: Int) -> OfflineDownload? {
        guard episodes.indices.contains(index) else { return nil }
        return downloads.items.first { $0.title == downloadTitle(index) && [.queued, .downloading, .completed].contains($0.state) }
    }
    private func queueDownloads() {
        guard let source, let video, !downloading else { return }
        let selected = selectedDownloads.sorted().filter { source.episodes.indices.contains($0) }
        downloading = true
        downloadTask = Task { @MainActor in
            defer { downloading = false }
            var queued = 0
            for index in selected {
                if Task.isCancelled { break }
                do {
                    let item = source.episodes[index]
                    let result = try await APIClient.shared.resolve(episode: item, source: source.id)
                    try Task.checkCancellation()
                    let title = "\(video.name) · \(source.id) · \(item.name)"
                    if !downloads.items.contains(where: { $0.title == title && [.queued, .downloading, .completed].contains($0.state) }) {
                        downloads.add(title: title, url: result.url, headers: result.headers); queued += 1
                    }
                    selectedDownloads.remove(index)
                } catch is CancellationError { break }
                catch { notice = "已加入 \(queued) 集；第 \(index + 1) 集失败：\(error.localizedDescription)"; return }
            }
            notice = "已加入 \(queued) 个下载任务；缓存是否完成以下载列表为准"
        }
    }

    private func configureCallbacks() {
        playback.onTime = { seconds in
            guard resolved != nil, !resolving else { return }
            time = seconds
            let rawDuration = playback.player.currentItem?.duration.seconds ?? 0
            duration = rawDuration.isFinite ? max(0, rawDuration) : 0
            if introPending, duration > 0 {
                introPending = false
                if duration > settings.intro + settings.outro + 1, seconds < settings.intro { seek(settings.intro) }
            }
            playing = playback.player.timeControlStatus == .playing
            danmaku.updatePlayback(episode: String(episodeIndex), time: seconds)
            if duration > settings.intro + settings.outro + 1, settings.outro > 0, seconds >= duration - settings.outro, !handledEnd { finishEpisode() }
        }
        playback.onProgress = { _ in recordHistory() }
        playback.onEnd = { finishEpisode() }
    }
    private func loadDetail() async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let result = try await APIClient.shared.detail(id: videoID)
            try Task.checkCancellation()
            recordHistory(); resolved = nil
            video = result
            if let history = library.history.first(where: { $0.id == videoID }) {
                sourceIndex = result.sources.firstIndex(where: { $0.id == history.source }) ?? 0
                if let source {
                    episodeIndex = Int(history.episode).flatMap { source.episodes.indices.contains($0) ? $0 : nil }
                        ?? source.episodes.firstIndex(where: { $0.name == history.episode }) ?? 0
                }
                startEpisode(episodeIndex, resume: history.position > 60 ? history.position : 0)
            } else { sourceIndex = 0; episodeIndex = 0; startEpisode(0) }
            await loadFavoriteStatus()
            await loadRelated()
        } catch is CancellationError {} catch { failure = error.localizedDescription }
    }
    private func loadRelated() async {
        do { related = try await APIClient.shared.related(id: videoID); relatedFailure = nil }
        catch { relatedFailure = error.localizedDescription }
    }
    private func switchSource(_ index: Int) {
        guard !downloading, let video, video.sources.indices.contains(index) else { return }
        let oldIndex = episodeIndex
        let oldTime = time
        recordHistory(); resolved = nil; sourceIndex = index; group = 0; selectedDownloads = []
        let target = min(oldIndex, max(0, episodes.count - 1))
        if oldIndex != target { notice = "该线路集数较少，已切换到最后一集" }
        startEpisode(target, resume: oldIndex == target ? oldTime : 0)
    }
    private func startEpisode(_ index: Int, resume: Double = 0) {
        guard episodes.indices.contains(index), let source else { return }
        recordHistory(); resolveTask?.cancel(); resolutionGeneration += 1
        let generation = resolutionGeneration
        episodeIndex = index; group = (reversed ? episodes.count - 1 - index : index) / 50
        let episode = source.episodes[index]
        playback.pause(); playing = false; handledEnd = false; failure = nil; resolved = nil; resolving = true
        time = 0; duration = 0; savedHistorySecond = -1
        danmaku.updatePlayback(episode: String(index), time: 0)
        resolveTask = Task { @MainActor in
            do {
                let result = try await APIClient.shared.resolve(episode: episode, source: source.id)
                guard generation == resolutionGeneration, !Task.isCancelled else { return }
                resolved = result
                playback.rate = settings.rate
                introPending = resume <= 0 && settings.intro > 0
                playback.load(result.url, headers: result.headers, resume: resume)
                resolving = false
            } catch {
                guard generation == resolutionGeneration, !Task.isCancelled else { return }
                failure = error.localizedDescription; resolving = false
            }
        }
    }
    private func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        handledEnd = false
        playback.player.seek(to: CMTime(seconds: target, preferredTimescale: 600)); time = target
        danmaku.updatePlayback(episode: String(episodeIndex), time: target)
    }
    private func togglePlay() {
        if playback.player.timeControlStatus == .playing { playback.pause(); playing = false }
        else if resolved != nil { playback.player.playImmediately(atRate: settings.rate); playing = true }
    }
    private func finishEpisode() {
        guard !handledEnd else { return }
        handledEnd = true; recordHistory()
        if settings.timerMode == -1 { settings.deadline = Date().addingTimeInterval(10); settings.countdown = 10; playback.pause(); playing = false; return }
        switch settings.mode {
        case "loop":
            let target = duration > settings.intro + settings.outro + 1 ? settings.intro : 0
            playback.player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { finished in
                Task { @MainActor in
                    guard finished else { return }
                    handledEnd = false; playback.player.playImmediately(atRate: settings.rate)
                }
            }
        case "continuous" where episodeIndex + 1 < episodes.count: startEpisode(episodeIndex + 1)
        default: playback.pause(); playing = false
        }
    }
    private func recordHistory() {
        guard var saved = video?.saved, resolved != nil, time.isFinite, time >= 0 else { return }
        let second = Int(time)
        guard second != savedHistorySecond else { return }
        savedHistorySecond = second
        saved.source = source?.id ?? ""; saved.episode = String(episodeIndex); saved.position = time
        saved.playbackURL = resolved?.url.absoluteString ?? ""
        library.record(saved)
    }
    private func tickTimer() {
        guard let deadline = settings.deadline else { return }
        let remaining = Int(ceil(deadline.timeIntervalSinceNow))
        if remaining <= 10 { settings.countdown = max(0, remaining) }
        if remaining <= 0 { playback.pause(); playing = false; settings.cancelTimer(); notice = "定时停止已生效" }
    }
    private func backgroundChanged(_ phase: ScenePhase) {
        backgroundPauseTask?.cancel()
        if phase == .background {
            recordHistory()
            backgroundPauseTask = Task { @MainActor in
                // Allow the AVPlayerViewController PiP delegate transition to settle first.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !playback.isPictureInPicture, !playback.player.isExternalPlaybackActive else { return }
                playback.pause(); playing = false
            }
        }
    }
    private func loadFavoriteStatus() async {
        guard AccountStore.shared.isLoggedIn else { accountFavorite = nil; return }
        do {
            guard let data = try await APIClient.shared.request(path: "favstatus", params: ["vod_id": videoID]) as? [String: Any], let value = data["status"] else { throw APIError.invalidResponse }
            accountFavorite = String(describing: value) == "1"
        } catch { notice = "账号收藏状态获取失败：\(error.localizedDescription)"; accountFavorite = nil }
    }
    private func toggleFavorite() async {
        guard let video, !favoriteBusy else { return }
        if !AccountStore.shared.isLoggedIn { library.toggleFavorite(video.saved); notice = "游客收藏只保存在本机"; return }
        favoriteBusy = true; defer { favoriteBusy = false }
        if accountFavorite == nil { await loadFavoriteStatus() }
        guard let previous = accountFavorite, let id = Int64(videoID), id > 0 else { notice = "无法确认账号收藏状态，请重试"; return }
        do {
            _ = try await APIClient.shared.request(path: "fav", method: "POST", body: ["vod_ids": [id], "opt": previous ? "-" : "+", "isSelected": !previous])
            await loadFavoriteStatus()
            notice = accountFavorite == !previous ? "账号收藏状态已由服务端确认" : "请求已提交，状态以服务端回读为准"
        } catch { notice = error.localizedDescription }
    }
    private func report(update: Bool) async {
        guard !reportBusy else { return }
        reportBusy = true; defer { reportBusy = false }
        do {
            var params = ["vod_id": videoID, "type": update ? "update" : "failure"]
            if !update { params["source_id"] = source?.id ?? "" }
            _ = try await APIClient.shared.request(path: "report", params: params)
            notice = update ? "催更请求已由服务端接收；更新进度以实际内容为准" : "播放报错已由服务端接收"
        } catch { notice = "提交失败：\(error.localizedDescription)" }
    }
    private func share(poster: Bool) async {
        do {
            let config = try await APIClient.shared.configuration()
            guard let share = config["share"] as? [String: Any], let url = URL(string: share.text("url")), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw APIError.configurationUnavailable }
            var items: [Any] = [share.text("content"), url]
            if poster, let video {
                var image: UIImage?
                if let posterURL = URL(string: video.poster), ["https", "http"].contains(posterURL.scheme?.lowercased() ?? "") {
                    let (data, response) = try await URLSession.shared.data(from: posterURL)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 10 * 1024 * 1024 else { throw APIError.invalidResponse }
                    image = UIImage(data: data)
                }
                let renderer = ImageRenderer(content: DetailPoster(video: video, image: image, appURL: url).frame(width: 360))
                renderer.scale = 2
                guard let rendered = renderer.uiImage else { throw APIError.invalidResponse }
                items.insert(rendered, at: 0)
            }
            shareItems = items; sheet = .share
        } catch { notice = "分享准备失败：\(error.localizedDescription)" }
    }
    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Task { @MainActor in notice = "系统未允许此屏幕方向：\(error.localizedDescription)" }
        }
    }
    private func formatTime(_ value: Double) -> String { let seconds = value.isFinite ? Int(max(0, value)) : 0; return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

private enum DetailSheet: String, Identifiable { case settings, composer, danmaku, episodes, downloads, share, dlna, pip; var id: String { rawValue } }

private struct DetailShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
private struct DetailPoster: View {
    let video: Video
    let image: UIImage?
    let appURL: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 440) }
            Text(video.name).font(.title.bold())
            Text([video.year, video.area, video.remark].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline)
            Text(video.introduction).font(.caption).lineLimit(6)
            Text("在 APP 中搜索影片名称观看").font(.caption.bold())
            Text(appURL.absoluteString).font(.caption2).textSelection(.enabled)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).foregroundStyle(.black)
    }
}

// SearchView currently has private @State text and no seeded-query initializer.
// This real API-backed actor/director search keeps the other agent's file untouched.
private struct DetailPeopleSearch: View {
    let query: String
    @State private var categories: [VideoCategory] = []
    @State private var category = ""
    @State private var results: [Video] = []
    @State private var error: String?
    @State private var loading = false
    @State private var page = 1
    @State private var hasMore = true
    @State private var generation = 0
    var body: some View {
        List {
            Picker("分类", selection: $category) { ForEach(categories) { Text($0.name).tag($0.id) } }
            if let error { Text(error).foregroundStyle(.red); Button("重试") { Task { await search(reset: page == 1) } } }
            ForEach(results) { video in NavigationLink(video.name) { DetailView(videoID: video.id) } }
            if loading { ProgressView() }
            else if hasMore { Button("加载更多") { Task { await search(reset: false) } } }
            else if results.isEmpty { Text("未找到结果") }
        }.navigationTitle(query)
            .task { do { categories = try await APIClient.shared.categories(); category = categories.first?.id ?? "" } catch { self.error = error.localizedDescription } }
            .task(id: category) { if !category.isEmpty { await search(reset: true) } }
    }
    private func search(reset: Bool) async {
        guard !category.isEmpty, reset || !loading else { return }
        generation += 1
        let revision = generation
        loading = true
        if reset { results = []; page = 1; hasMore = true }
        defer { if revision == generation { loading = false } }
        let selectedCategory = category
        let requestedPage = reset ? 1 : page
        do {
            let found = try await APIClient.shared.search(query: query, category: selectedCategory, page: requestedPage)
            guard revision == generation, category == selectedCategory, !Task.isCancelled else { return }
            var ids = Set(reset ? [] : results.map(\.id))
            let unique = found.filter { ids.insert($0.id).inserted }
            results = reset ? unique : results + unique; page = requestedPage + 1; hasMore = !found.isEmpty; error = nil
        } catch { if revision == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
