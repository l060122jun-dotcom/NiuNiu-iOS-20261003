import SwiftUI
import Combine
import UIKit

@MainActor public struct DetailView: View {
    public let videoID: String
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.fullscreenPlayerInsets) private var fullscreenInsets
    @StateObject private var playback = PlaybackController()
    @StateObject private var playerInteraction = AndroidPlayerInteraction()
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
    @State private var detailVisible = false
    // Explicit orientation lasts for this detail playback session (including source/episode changes).
    @State private var manualLandscape: Bool?
    @State private var locked = false
    @State private var fill = false
    @State private var introPending = false
    @State private var backgroundPauseTask: Task<Void, Never>?
    @State private var resolveTask: Task<Void, Never>?
    @State private var resolutionGeneration = 0
    @State private var firstFrameTimeout: Task<Void, Never>?
    @State private var triedSources = Set<String>()
    @State private var attemptDiagnostics: [String] = []
    @State private var attemptEpisodeName = ""
    @State private var attemptEpisodeIndex = 0
    @State private var attemptResume: Double = 0
    @State private var attemptPaused = false
    @State private var attemptStatus: String?
    @State private var loadedGeneration: Int?
    @State private var loadedSourceID: String?
    @State private var handledEnd = false
    @State private var suspended = false
    @State private var resumeAfterNavigation = false
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
    @State private var holdWasPlaying = false
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
    private var landscape: Bool {
        // Unknown and near-square video stay portrait. Only real displayed DAR
        // above 1.10 chooses the system's counterclockwise LandscapeRight turn.
        manualLandscape ?? ((playback.videoDisplayAspect ?? 1) > 1.10)
    }

    public var body: some View {
        VStack(spacing: 0) {
            FullscreenPlayerTransition(isPresented: $fullScreen, landscape: landscape,
                                       orientationFailure: { notice = $0 },
                                       onDismiss: { locked = false }) {
                playerArea.preferredColorScheme(.dark).environmentObject(library)
                    .sheet(item: $sheet) { value in sheetContent(value) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
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
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            configureCallbacks()
            playback.restorePictureInPictureUI = {
                guard detailVisible else { return false }
                fullScreen = true
                return true
            }
            if video == nil { suspended = false; await loadDetail() }
            else if suspended {
                suspended = false
                danmaku.retry()
                if let resolved {
                    playback.load(resolved.url, headers: resolved.headers, resume: time)
                    playback.setRate(settings.rate)
                    if !resumeAfterNavigation { playback.pause() }
                } else { startEpisode(episodeIndex, resume: time) }
            }
        }
        .onReceive(clock) { _ in tickTimer() }
        .onAppear { detailVisible = true }
        .onChange(of: scenePhase) { phase in backgroundChanged(phase) }
        .onChange(of: fill) { playback.setFill($0) }
        .onChange(of: playback.isPlaying) { playing = $0 }
        .onChange(of: playback.hasRenderedFrame) { rendered in
            guard rendered, !suspended, loadedGeneration == resolutionGeneration,
                  loadedSourceID == source?.id, let source else { return }
            // Prepared is not proof of a working source. Persist only actual first frame.
            UserDefaults.standard.set(source.id, forKey: preferredSourceKey)
            firstFrameTimeout?.cancel(); firstFrameTimeout = nil
            attemptStatus = nil
        }
        .onChange(of: playback.error) { message in
            guard let message, loadedGeneration == resolutionGeneration,
                  loadedSourceID == source?.id else { return }
            failover(message, generation: resolutionGeneration, sourceID: source?.id ?? "")
        }
        .onChange(of: account.isLoggedIn) { _ in Task { await loadFavoriteStatus() } }
        .onDisappear {
            // A custom fullscreen presentation is not navigation away from detail.
            if !fullScreen { detailVisible = false }
            if !fullScreen && !playback.hasPictureInPictureSession {
                closeDetail()
            }
        }
    }

    private var playerArea: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                PlaybackSurface(controller: playback, fill: fill)
                    .allowsHitTesting(false)
                AndroidPlayerGestureSurface(
                    sessionID: "\(sourceIndex)|\(episodeIndex)|\(resolutionGeneration)",
                    enabled: resolved != nil && !resolving && errorText == nil,
                    locked: locked, time: time, duration: duration, holdRate: settings.holdRate,
                    interaction: playerInteraction, onPlay: togglePlay, onSeek: seek,
                    onHold: temporaryRate)
                if !locked { DanmakuOverlay(store: danmaku) }
                AndroidPlayerControls(
                    interaction: playerInteraction, locked: $locked,
                    sessionID: "\(sourceIndex)|\(episodeIndex)|\(resolutionGeneration)",
                    title: [video?.name, episode?.name].compactMap { $0 }.joined(separator: " · "),
                    time: time, duration: duration, playing: playing, fullScreen: fullScreen,
                    wide: fullScreen && geometry.size.width > geometry.size.height, fill: fill,
                    canNext: episodeIndex + 1 < episodes.count && !resolving,
                    rate: settings.rate, rates: PlaybackPreferences.rates, danmakuShown: danmaku.show,
                    onBack: { if fullScreen { fullScreen = false } else { closeDetail(); dismiss() } },
                    onPlay: togglePlay, onNext: { startEpisode(episodeIndex + 1) }, onSeek: seek,
                    onFullScreen: { fullScreen.toggle() }, onFill: { fill.toggle() },
                    onSettings: { sheet = .settings }, onEpisodes: { sheet = .episodes },
                    onDanmaku: { danmaku.show.toggle() },
                    onRate: applyRate,
                    onCast: { sheet = .cast }) {
                        playerMoreMenu
                    }
                    .padding(fullScreen ? fullscreenInsets : EdgeInsets())
                if resolving && !locked { ProgressView("正在解析播放地址…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                if let attemptStatus, !locked {
                    VStack { Spacer(); Text(attemptStatus).font(.caption).padding(8).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8)); Spacer().frame(height: 80) }
                        .allowsHitTesting(false)
                }
                if let errorText, !locked {
                    VStack(spacing: 12) {
                        Text(errorText).multilineTextAlignment(.center)
                        HStack {
                            Button("返回") { if fullScreen { fullScreen = false } else { closeDetail(); dismiss() } }
                            Button("重试") { startEpisode(episodeIndex, resume: time, preferSuccessful: false, preservePaused: attemptPaused) }
                            Menu("换源") { sourceButtons }
                            Button("报错") { Task { await report(update: false) } }.disabled(reportBusy || source == nil)
                        }
                        if let notice { Text(notice).font(.caption) }
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                }
                if let countdown = settings.countdown, !locked {
                    VStack { Text("\(countdown) 秒后停止播放"); Button("取消定时停止") { settings.cancelTimer() } }
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(.black).foregroundStyle(.white)
    }
    @ViewBuilder private var playerMoreMenu: some View {
        Button("上一集") { startEpisode(episodeIndex - 1) }.disabled(episodeIndex == 0 || resolving)
        Button("后退15秒") { seek(time - 15) }
        Button("前进15秒") { seek(time + 15) }
        Menu("倍速") { ForEach(PlaybackPreferences.rates, id: \.self) { value in Button(String(format: "%g×", value)) { applyRate(value) } } }
        Button("选集 / 换源") { sheet = .episodes }
        Button(danmaku.show ? "关闭弹幕" : "打开弹幕") { danmaku.show.toggle() }
        Button("发送弹幕") { sheet = .composer }
        Button("弹幕样式") { sheet = .danmaku }
        Button(fill ? "画面适应" : "画面填充") { fill.toggle() }
        Button("锁屏") { locked = true; playerInteraction.show() }
        if fullScreen {
            Button(landscape ? "切换竖屏" : "切换横屏") { manualLandscape = !landscape }
            if manualLandscape != nil { Button("按视频比例自动方向") { manualLandscape = nil } }
        }
        Menu("播放方式") { Button("连续播放") { settings.mode = "continuous" }; Button("单集停止") { settings.mode = "single" }; Button("单集循环") { settings.mode = "loop" } }
        Button("AirPlay / 系统投屏") { sheet = .cast }
        Button("画中画") { sheet = .pip }
    }
    private func temporaryRate(_ active: Bool) {
        if active {
            guard holdOriginalRate == nil else { return }
            guard resolved != nil, !resolving, settings.holdRate.isFinite, settings.holdRate > 0 else { return }
            holdOriginalRate = playback.rate; holdWasPlaying = playback.isPlaying
            playback.setRate(settings.holdRate)
            if !holdWasPlaying { playback.pause() }
        } else if let original = holdOriginalRate {
            holdOriginalRate = nil; playback.setRate(original)
            if !holdWasPlaying { playback.pause(); playing = false }
        }
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
                        Text(groupLabel(value)).tag(value)
                    }
                }
                Spacer(); Button(reversed ? "倒序 ↓" : "正序 ↑") { reversed.toggle(); group = max(0, (reversed ? episodes.count - 1 - episodeIndex : episodeIndex) / 50) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], spacing: 10) {
                ForEach(displayedIndices, id: \.self) { index in
                    Button { startEpisode(index) } label: { episodeLabel(index) }
                }
            }
            if episodes.isEmpty { Text("服务端没有可播放的集数").foregroundStyle(.secondary) }
        }
    }
    private func groupLabel(_ value: Int) -> String {
        let lower = reversed ? max(1, episodes.count - (value + 1) * 50 + 1) : value * 50 + 1
        let upper = reversed ? max(0, episodes.count - value * 50) : min(episodes.count, (value + 1) * 50)
        return "\(lower)–\(upper)"
    }
    private func episodeLabel(_ index: Int) -> some View {
        let active = index == episodeIndex
        return Text(episodes[index].name)
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
        case .settings:
            PlaybackSettingsView(settings: settings, rateChanged: { applyRate($0) }, hardwareDecodeChanged: { _ in
                notice = "硬件解码设置已保存，下次加载影片或重试播放时生效"
            })
        case .composer: DanmakuComposer(store: danmaku, episode: String(episodeIndex), time: time)
        case .danmaku: NavigationStack { DanmakuSettingsView(store: danmaku).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } } }
        case .episodes: NavigationStack { ScrollView { episodeSection.padding() }.navigationTitle("全部线路与选集").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } } }
        case .downloads: downloadPicker
        case .share: DetailShareSheet(items: shareItems)
        case .dlna:
            if let resolved { DLNADeviceView(mediaURL: resolved.url, title: video?.name ?? "视频", headers: resolved.headers) }
        case .cast:
            NavigationStack {
                VStack(spacing: 20) {
                    AirPlayButton().frame(width: 64, height: 64).accessibilityLabel("选择 AirPlay 设备")
                    Text("系统音频路由 / AirPlay").font(.headline)
                    Text("IJK 不提供与 AVPlayer 相同的直接 AirPlay 视频投屏。系统路由可用于音频设备；电视视频投屏请使用下方 DLNA。")
                        .font(.callout).multilineTextAlignment(.center)
                    Button("搜索 DLNA 电视") { sheet = .dlna }.disabled(resolved == nil)
                }.padding().navigationTitle("电视投屏").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
            }
        case .pip:
            NavigationStack {
                VStack(spacing: 16) {
                    Text(playback.pictureInPictureStatus)
                    Button("启动画中画") { sheet = nil; playback.requestPictureInPicture() }
                        .disabled(!playback.canStartPictureInPicture)
                }.padding().navigationTitle("画中画")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
            }
        }
    }
    private var downloadPicker: some View {
        NavigationStack {
            List {
                Section {
                    Menu("下载线路：\(source?.id ?? "暂无")") { sourceButtons }
                        .disabled(downloading)
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
                if let error = downloads.storageError { Text(error).font(.caption).foregroundStyle(.red) }
                if downloads.isRestoring { ProgressView("正在恢复下载记录…") }
                if let notice { Text(notice).font(.caption) }
                if downloading { ProgressView("逐集解析并加入真实下载队列…"); Button("停止加入队列") { downloadTask?.cancel() } }
                NavigationLink("查看所有下载") { DownloadsView() }
            }.navigationTitle("下载选集")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("下载所选 \(selectedDownloads.count) 集") { queueDownloads() }.disabled(selectedDownloads.isEmpty || downloading || downloads.isRestoring || downloads.storageError != nil) }
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
        guard !downloads.isRestoring, downloads.storageError == nil else {
            notice = downloads.storageError ?? "下载记录正在恢复，请稍后再试。"
            return
        }
        let selected = selectedDownloads.sorted().filter { source.episodes.indices.contains($0) }
        downloading = true
        downloadTask = Task { @MainActor in
            defer { downloading = false }
            var queued = 0
            for index in selected {
                if Task.isCancelled { break }
                do {
                    let item = source.episodes[index]
                    let title = "\(video.name) · \(source.id) · \(item.name)"
                    if downloads.items.contains(where: { $0.title == title && [.queued, .downloading, .completed].contains($0.state) }) {
                        selectedDownloads.remove(index)
                        continue
                    }
                    let result = try await APIClient.shared.resolve(episode: item, source: source.id, purpose: .download)
                    var transferred = false
                    defer { if !transferred { SpecialSourceResolver.shared.releaseDownload(url: result.url) } }
                    try Task.checkCancellation()
                    guard !suspended, UIApplication.shared.applicationState != .background else { throw CancellationError() }
                    if !downloads.items.contains(where: { $0.title == title && [.queued, .downloading, .completed].contains($0.state) }) {
                        let origin = OfflineDownloadOrigin(videoID: video.id, playerID: source.id,
                                                           episodeIndex: index, episodeURL: item.url)
                        let id = downloads.add(title: title, url: result.url, headers: result.headers, origin: origin)
                        guard let added = downloads.items.first(where: { $0.id == id }) else {
                            throw NSError(domain: "OfflineDownloads", code: 1, userInfo: [NSLocalizedDescriptionKey: downloads.storageError ?? "下载入队失败，未创建任务"])
                        }
                        guard [.queued, .downloading, .completed].contains(added.state) else {
                            throw NSError(domain: "OfflineDownloads", code: 2, userInfo: [NSLocalizedDescriptionKey: added.errorMessage ?? "下载入队失败"])
                        }
                        transferred = true
                        queued += 1
                    }
                    selectedDownloads.remove(index)
                } catch is CancellationError { break }
                catch { guard !Task.isCancelled, !suspended else { return }; notice = "已加入 \(queued) 集；第 \(index + 1) 集失败：\(error.localizedDescription)"; return }
            }
            guard !Task.isCancelled, !suspended else { return }
            notice = "已加入 \(queued) 个下载任务；缓存是否完成以下载列表为准"
        }
    }

    private func configureCallbacks() {
        playback.onTime = { seconds in
            guard !suspended, !playback.isSeeking, resolved != nil, !resolving, seconds.isFinite, seconds >= 0 else { return }
            let position = playback.position
            guard position.isFinite, position >= 0 else { return }
            time = position
            let rawDuration = playback.duration
            duration = rawDuration.isFinite ? max(0, rawDuration) : 0
            if introPending, duration > 0 {
                introPending = false
                if duration > settings.intro + settings.outro + 1, time < settings.intro { seek(settings.intro); return }
            }
            playing = playback.isPlaying
            danmaku.updatePlayback(episode: String(episodeIndex), time: time)
            if duration > settings.intro + settings.outro + 1, settings.outro > 0, time >= duration - settings.outro, !handledEnd { finishEpisode() }
        }
        playback.onProgress = { seconds in
            guard !suspended, !playback.isSeeking, seconds.isFinite, seconds >= 0, resolved != nil, !resolving else { return }
            recordHistory()
        }
        playback.onEnd = { guard !suspended, !playback.isSeeking, resolved != nil, !resolving else { return }; finishEpisode() }
    }
    private func closeDetail() {
        guard !playback.hasPictureInPictureSession else { return }
        guard !suspended else { return }
        recordHistory()
        if playback.core != nil { time = playback.position.isFinite ? max(0, playback.position) : time }
        resumeAfterNavigation = playback.isPlaying
        suspended = true
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        resolveTask?.cancel(); resolveTask = nil; resolutionGeneration += 1; resolving = false
        downloadTask?.cancel(); downloadTask = nil
        backgroundPauseTask?.cancel(); backgroundPauseTask = nil
        temporaryRate(false)
        playerInteraction.cancel()
        playback.onTime = nil; playback.onProgress = nil; playback.onEnd = nil
        playback.stop(); danmaku.stop(); playing = false
    }
    private func loadDetail() async {
        guard !loading, !suspended else { return }
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
        let oldName = episode?.name
        let paused = playback.core != nil && !playback.playbackRequested
        recordHistory(); resolved = nil; sourceIndex = index; group = 0; selectedDownloads = []
        guard !episodes.isEmpty else { notice = "该线路没有可播放集数"; return }
        let target = episodes.firstIndex(where: { $0.name == oldName }) ?? min(oldIndex, max(0, episodes.count - 1))
        if oldIndex != target && episodes[target].name != oldName { notice = "该线路集数较少，已按集数范围匹配，请核对集名" }
        startEpisode(target, resume: oldTime, preferSuccessful: false, preservePaused: paused)
    }
    private var preferredSourceKey: String { "niuniu.preferredSource.\(videoID)" }
    private func startEpisode(_ index: Int, resume: Double = 0, continuingAttempts: Bool = false,
                              preferSuccessful: Bool = true, preservePaused: Bool = false) {
        guard episodes.indices.contains(index) else { return }
        recordHistory()
        var target = index
        if !continuingAttempts {
            attemptEpisodeName = episodes[index].name; attemptEpisodeIndex = index
            attemptResume = resume.isFinite ? max(0, resume) : 0
            attemptPaused = preservePaused
            triedSources = []; attemptDiagnostics = []
            if preferSuccessful, let video, let preferred = UserDefaults.standard.string(forKey: preferredSourceKey),
               let preferredIndex = video.sources.firstIndex(where: { $0.id == preferred && !$0.episodes.isEmpty }) {
                sourceIndex = preferredIndex
                target = episodes.firstIndex(where: { $0.name == attemptEpisodeName }) ?? min(index, episodes.count - 1)
            }
        }
        guard let source, source.episodes.indices.contains(target) else { return }
        resolveTask?.cancel(); resolutionGeneration += 1
        let generation = resolutionGeneration
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        loadedGeneration = nil; loadedSourceID = nil
        triedSources.insert(source.id)
        attemptStatus = "正在尝试线路 \(source.id)（\(triedSources.count)/\(video?.sources.filter { !$0.episodes.isEmpty }.count ?? 0)）"
        episodeIndex = target; group = (reversed ? episodes.count - 1 - target : target) / 50
        let episode = source.episodes[target]
        temporaryRate(false)
        playback.stop(); playback.error = nil; playing = false; handledEnd = false; failure = nil; resolved = nil; resolving = true
        time = 0; duration = 0; savedHistorySecond = -1
        danmaku.updatePlayback(episode: String(target), time: 0)
        armFirstFrameTimeout(generation: generation, sourceID: source.id)
        resolveTask = Task { @MainActor in
            do {
                let result = try await APIClient.shared.resolve(episode: episode, source: source.id)
                guard generation == resolutionGeneration, !Task.isCancelled else { return }
                resolved = result
                loadedGeneration = generation; loadedSourceID = source.id
                playback.setRate(settings.rate)
                introPending = resume <= 0 && settings.intro > 0
                playback.load(result.url, headers: result.headers, resume: resume.isFinite ? max(0, resume) : 0)
                if attemptPaused { playback.pause() }
                playback.setFill(fill)
                resolving = false
            } catch {
                guard generation == resolutionGeneration, !Task.isCancelled else { return }
                resolving = false
                failover(error.localizedDescription, generation: generation, sourceID: source.id)
            }
        }
    }
    private func armFirstFrameTimeout(generation: Int, sourceID: String) {
        firstFrameTimeout = Task { @MainActor in
            var activeSeconds = 0
            while activeSeconds < 30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !suspended, generation == resolutionGeneration,
                      source?.id == sourceID, !playback.hasRenderedFrame else { return }
                // Neither user pause nor background time counts as failed prepare.
                if scenePhase == .active && !attemptPaused && (resolving || playback.playbackRequested) { activeSeconds += 1 }
            }
            failover("阶段 prepare · 30 秒未收到真实首帧", generation: generation, sourceID: sourceID)
        }
    }
    private func failover(_ diagnostic: String, generation: Int, sourceID: String) {
        guard !suspended, generation == resolutionGeneration, source?.id == sourceID else { return }
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        // Invalidate synchronously, before another simultaneous error/timeout can advance twice.
        loadedGeneration = nil; loadedSourceID = nil
        resolutionGeneration += 1
        resolveTask?.cancel(); resolveTask = nil; resolving = false
        attemptDiagnostics.append("线路 \(sourceID)：\(diagnostic)")
        if playback.core != nil {
            // renderError pauses the native core for safety; that is NOT a user
            // pause and must not make the next source permanently paused.
            if playback.position.isFinite && playback.position > 0 { attemptResume = playback.position }
        }
        guard let video, let next = video.sources.firstIndex(where: { !triedSources.contains($0.id) && !$0.episodes.isEmpty }) else {
            playback.pause(); playing = false
            attemptStatus = nil
            failure = "可用线路均已尝试，未确认播放成功。\n" + attemptDiagnostics.joined(separator: "\n")
            return
        }
        recordHistory()
        resolved = nil // Never attribute the old source's URL/progress to the next source.
        sourceIndex = next; selectedDownloads = []
        let target = episodes.firstIndex(where: { $0.name == attemptEpisodeName }) ?? min(attemptEpisodeIndex, episodes.count - 1)
        startEpisode(target, resume: attemptResume, continuingAttempts: true, preferSuccessful: false)
    }
    private func seek(_ seconds: Double) {
        guard seconds.isFinite, resolved != nil, !resolving else { return }
        let rawDuration = playback.duration
        let limit = rawDuration.isFinite ? max(0, rawDuration) : 0
        let target = max(0, limit > 0 ? min(seconds, limit) : seconds)
        handledEnd = false
        playback.seek(seconds: target); time = target
        danmaku.updatePlayback(episode: String(episodeIndex), time: target)
    }
    private func togglePlay() {
        guard resolved != nil, !resolving else { return }
        if playback.playbackRequested { attemptPaused = true; playback.pause(); playing = false }
        else { attemptPaused = false; playback.setRate(settings.rate); playback.play(); playing = playback.isPlaying }
    }
    private func applyRate(_ value: Float) {
        guard value.isFinite, PlaybackPreferences.rates.contains(value) else { return }
        settings.rate = value; playback.setRate(value); playing = playback.isPlaying
    }
    private func finishEpisode() {
        guard !suspended, !handledEnd, !playback.isSeeking, resolved != nil, !resolving else { return }
        handledEnd = true; recordHistory()
        if settings.timerMode == -1 { settings.deadline = Date().addingTimeInterval(10); settings.countdown = 10; playback.pause(); playing = false; return }
        switch settings.mode {
        case "loop":
            let target = duration > settings.intro + settings.outro + 1 ? settings.intro : 0
            seek(target)
            playback.setRate(settings.rate); playback.play(); playing = playback.isPlaying
        case "continuous" where episodeIndex + 1 < episodes.count: startEpisode(episodeIndex + 1)
        default: playback.pause(); playing = false
        }
    }
    private func recordHistory() {
        let position = playback.position
        guard var saved = video?.saved, resolved != nil, !resolving, position.isFinite, position >= 0, position < Double(Int.max) else { return }
        let second = Int(position)
        let actualDuration = playback.duration
        let validDuration: Double? = actualDuration.isFinite && actualDuration > 0 ? actualDuration : nil
        guard second != savedHistorySecond || (validDuration != nil && library.history.first(where: { $0.id == saved.id })?.duration != validDuration) else { return }
        savedHistorySecond = second
        saved.source = source?.id ?? ""; saved.episode = String(episodeIndex); saved.position = position
        saved.playbackURL = resolved?.url.absoluteString ?? ""
        saved.duration = validDuration
        library.record(saved)
    }
    private func tickTimer() {
        guard let deadline = settings.deadline else { return }
        let interval = deadline.timeIntervalSinceNow
        guard interval.isFinite else { settings.cancelTimer(); return }
        let remaining = Int(min(86_400_000, max(-86_400_000, ceil(interval))))
        if remaining <= 10 { settings.countdown = max(0, remaining) }
        if remaining <= 0 { playback.pause(); playing = false; settings.cancelTimer(); notice = "定时停止已生效" }
    }
    private func backgroundChanged(_ phase: ScenePhase) {
        backgroundPauseTask?.cancel()
        if phase == .background {
            recordHistory()
            backgroundPauseTask = Task { @MainActor in
                // Normal background playback remains paused; active PiP owns IJK.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !playback.hasPictureInPictureSession else { return }
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
    private func formatTime(_ value: Double) -> String { let seconds = value.isFinite ? Int(min(86_400_000, max(0, value))) : 0; return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

private enum DetailSheet: String, Identifiable { case settings, composer, danmaku, episodes, downloads, share, dlna, cast, pip; var id: String { rawValue } }

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
