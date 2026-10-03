import SwiftUI
import UIKit
import AVKit
import Combine
import IJKMediaFramework

/// The playback engine is Bilibili's IJKFFMoviePlayerController (FFmpeg), not AVPlayer.
@MainActor
final class PlaybackController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var core: IJKFFMoviePlayerController?
    var view: UIView? { core?.view }
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var rate: Float = 1
    @Published var error: String?
    @Published private(set) var isReady = false
    @Published private(set) var isSeeking = false
    @Published private(set) var stage = "idle"
    @Published private(set) var videoToolboxEnabled = true
    @Published private(set) var capabilityMessage: String?
    /// DAR of an actual displayed decoder frame, including SAR; nil until first frame.
    @Published private(set) var videoDisplayAspect: Double?
    @Published private(set) var hasRenderedFrame = false
    var playbackRequested: Bool { wantsToPlay }

    // An IJK OpenGL view is neither AVPlayerLayer nor an AVSampleBufferDisplayLayer.
    // Supporting PiP requires a new sample-buffer rendering pipeline, not a dummy AVPlayer.
    @Published private(set) var isPictureInPicture = false
    @Published private(set) var canStartPictureInPicture = false
    var pictureInPictureStatus: String { capabilityMessage ?? "画中画使用 IJK 真实解码帧；首帧显示且系统允许后可启动。" }
    var restorePictureInPictureUI: (() -> Bool)?
    private var renderer: IJKSampleBufferView?
    private var pip: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var pipStarting = false
    var hasPictureInPictureSession: Bool { isPictureInPicture || pipStarting }
    private var pipStartTimeout: Task<Void, Never>?
    private var skipCompletion: (() -> Void)?
    private var skipTimeout: Task<Void, Never>?
    private static var pipOwner: PlaybackController?
    let airPlayStatus = "系统路由按钮可选择音频设备；当前 IJK 未实现 AirPlay 视频远程投送。视频可使用系统屏幕镜像。"

    var onProgress: ((Double) -> Void)?
    var onTime: ((Double) -> Void)?
    var onEnd: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var pendingSeek: Double?
    private var seekTarget: Double?
    private var seekCompleted = false
    // One native seek in flight: IJK notifications contain target but no request
    // ID. Coalesce UI seeks until its notification; same-target A/B is unambiguous.
    private var nativeSeekTarget: Double?
    private var seekVideoSerial: Int32?
    private var seekFrameAcknowledged = false
    private var wantsToPlay = true
    private var didFinish = false
    private var fill = false
    private var lastProgressTime = -Double.infinity

    override init() {
        super.init()
        videoToolboxEnabled = UserDefaults.standard.object(forKey: "niuniu.hardwareDecode") as? Bool ?? true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            let failure = error as NSError
            self.error = "阶段 audio-session · domain \(failure.domain) · code \(failure.code)"
        }
    }

    func load(_ url: URL, headers: [String: String] = [:], resume: Double = 0) {
        releaseCore()
        error = nil
        capabilityMessage = nil
        position = 0
        duration = 0
        isReady = false
        isPlaying = false
        didFinish = false
        wantsToPlay = true
        stage = "configure"
        videoToolboxEnabled = UserDefaults.standard.object(forKey: "niuniu.hardwareDecode") as? Bool ?? true
        pendingSeek = resume.isFinite && resume > 0 ? resume : nil
        seekTarget = nil
        seekCompleted = false
        nativeSeekTarget = nil
        isSeeking = pendingSeek != nil
        lastProgressTime = -Double.infinity

        guard let headerOptions = Self.validatedHeaders(headers) else {
            error = "阶段 configure · domain HTTPHeaders · code invalid-header\n请求头含非法名称、控制字符或重复字段，已拒绝发送。"
            return
        }
        let options = IJKFFOptions.byDefault()!
        options.showHudView = false
        options.setPlayerOptionIntValue(videoToolboxEnabled ? 1 : 0, forKey: "videotoolbox")
        options.setPlayerOptionIntValue(1, forKey: "enable-accurate-seek")
        // Official software vout converts other AVFrame formats to this I420
        // output; the ObjC bridge interleaves the real chroma planes to NV12.
        options.setPlayerOptionIntValue(Int64(0x30323449), forKey: "overlay-format")
        options.setFormatOptionValue(headerOptions.userAgent, forKey: "user_agent")
        if !headerOptions.block.isEmpty {
            // FFmpeg HTTP AVOptions belong to FORMAT, never PLAYER or CODEC.
            options.setFormatOptionValue(headerOptions.block, forKey: "headers")
        }
        let output = IJKSampleBufferView(frame: .zero)
        guard let candidate = IJKSampleBufferView.makePlayer(url: url, options: options, renderer: output) else {
            error = "阶段 initialize · domain IJKMediaFramework · code initialization-failed"
            return
        }
        // The official initializer enables DEBUG logging; override it before prepare to avoid
        // dumping signed media URLs or request headers through FFmpeg logs.
        IJKFFMoviePlayerController.setLogReport(false)
        IJKFFMoviePlayerController.setLogLevel(IJKLogLevel(rawValue: 8))
        candidate.shouldShowHudView = false
        candidate.shouldAutoplay = false
        candidate.allowsMediaAirPlay = false
        candidate.setPauseInBackground(true)
        candidate.scalingMode = fill ? .aspectFill : .aspectFit
        candidate.playbackRate = rate
        renderer = output
        output.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        output.videoDisplayAspectChanged = { [weak self, weak output] aspect in
            guard let self, self.renderer === output, aspect.isFinite, aspect > 0 else { return }
            if self.videoDisplayAspect != aspect { self.videoDisplayAspect = aspect }
        }
        output.renderError = { [weak self, weak output] message in
            guard let self, self.renderer === output else { return }
            self.error = message
            self.pause()
            self.pip?.stopPictureInPicture()
        }
        output.seekFrameDisplayed = { [weak self, weak output] serial in
            guard let self, self.renderer === output, self.isSeeking,
                  self.nativeSeekTarget == nil, self.seekCompleted,
                  self.seekVideoSerial == serial else { return }
            self.seekFrameAcknowledged = true
            if let core = self.core { self.refresh(core) }
        }
        core = candidate
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: output.displayLayer, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            pip = controller
            pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self, weak controller] _, _ in
                DispatchQueue.main.async { [weak self, weak controller] in
                    guard let self, self.pip === controller else { return }
                    self.canStartPictureInPicture = controller?.isPictureInPicturePossible == true
                }
            }
        }
        observe(candidate)
        startTimer()
        stage = "prepare"
        candidate.prepareToPlay()
    }

    func play() {
        wantsToPlay = true
        guard let core, isReady, error == nil else { return }
        didFinish = false
        core.playbackRate = rate
        core.play()
        refresh(core)
    }

    func pause() {
        wantsToPlay = false
        guard let core else { return }
        core.pause()
        refresh(core)
        onProgress?(position)
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, let core else { return }
        // Pinned ffp_seek_to_l at >=duration emits COMPLETED without executing
        // a seek or issuing SEEK_COMPLETE. Never submit that special EOF path.
        let target = duration > 0 ? min(max(0, seconds), max(0, duration - 0.001)) : max(0, seconds)
        if !isReady {
            pendingSeek = target
            isSeeking = true
            return
        }
        didFinish = false
        seekTarget = target
        seekCompleted = false
        seekFrameAcknowledged = false
        seekVideoSerial = nil
        isSeeking = true
        stage = "seek"
        renderer?.beginSeek(to: target)
        if nativeSeekTarget == nil {
            nativeSeekTarget = target
            core.currentPlaybackTime = target
        }
        // Do not publish the requested target as actual progress; the timer reads IJK's clock.
    }

    func seek(seconds: Double) { seek(seconds) }

    func setRate(_ value: Float) {
        guard value.isFinite, value > 0 else { return }
        rate = min(max(value, 0.25), 4)
        core?.playbackRate = rate
        renderer?.updateClock(position, rate: isPlaying ? Double(rate) : 0)
    }

    func setFill(_ value: Bool) {
        fill = value
        core?.scalingMode = value ? .aspectFill : .aspectFit
        renderer?.contentMode = value ? .scaleAspectFill : .scaleAspectFit
    }

    /// Applies to the next load. Reload the current source explicitly to change decoders.
    func setVideoToolboxEnabled(_ value: Bool) {
        videoToolboxEnabled = value
    }

    func requestPictureInPicture() {
        guard let pip, pip.isPictureInPicturePossible, isReady, error == nil else {
            capabilityMessage = "系统尚不允许画中画：请等待真实首帧显示，或检查设备与播放状态。"
            return
        }
        guard !pipStarting, !isPictureInPicture else { return }
        capabilityMessage = nil
        pipStarting = true
        Self.pipOwner = self
        core?.setPauseInBackground(false)
        pip.startPictureInPicture()
        pipStartTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.pipStarting else { return }
            self.pip?.stopPictureInPicture()
            self.finishPictureInPicture()
            self.capabilityMessage = "画中画启动超时，已恢复普通后台暂停策略。"
        }
    }

    func stop() {
        let progress = position
        releaseCore()
        wantsToPlay = false
        isPlaying = false
        isReady = false
        position = 0
        duration = 0
        pendingSeek = nil
        seekTarget = nil
        seekCompleted = false
        isSeeking = false
        stage = "stopped"
        if progress.isFinite && progress > 0 { onProgress?(progress) }
    }

    private func observe(_ candidate: IJKFFMoviePlayerController) {
        let names: [Notification.Name] = [
            .IJKMPMediaPlaybackIsPreparedToPlayDidChange,
            .IJKMPMoviePlayerPlaybackStateDidChange,
            .IJKMPMoviePlayerLoadStateDidChange,
            .IJKMPMoviePlayerPlaybackDidFinish,
            .IJKMPMoviePlayerOpenInput,
            .IJKMPMoviePlayerFindStreamInfo,
            .IJKMPMoviePlayerComponentOpen,
            .IJKMPMoviePlayerFirstVideoFrameRendered,
            .IJKMPMoviePlayerDidSeekComplete
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: candidate, queue: .main
            ) { [weak self, weak candidate] note in
                Task { @MainActor [weak self, weak candidate] in
                    guard let self, let candidate, self.core === candidate,
                          let sender = note.object as? IJKFFMoviePlayerController,
                          sender === candidate else { return }
                    self.handle(note, core: candidate)
                }
            })
        }
    }

    private func handle(_ note: Notification, core candidate: IJKFFMoviePlayerController) {
        switch note.name {
        case .IJKMPMediaPlaybackIsPreparedToPlayDidChange:
            guard candidate.isPreparedToPlay, error == nil else { return }
            isReady = true
            stage = "prepared"
            duration = Self.validTime(candidate.duration)
            if let resume = pendingSeek {
                pendingSeek = nil
                seek(resume)
            }
            candidate.playbackRate = rate
            if wantsToPlay { candidate.play() }
        case .IJKMPMoviePlayerOpenInput:
            stage = "open-input"
        case .IJKMPMoviePlayerFindStreamInfo:
            stage = "find-stream-info"
        case .IJKMPMoviePlayerComponentOpen:
            stage = "open-codec"
        case .IJKMPMoviePlayerFirstVideoFrameRendered:
            hasRenderedFrame = true
            stage = "render"
        case .IJKMPMoviePlayerDidSeekComplete:
            guard isSeeking, let target = seekTarget, let submitted = nativeSeekTarget else { return }
            // One native request is in flight. Upstream arg1 is absolute stream
            // milliseconds (includes positive start_time), not our relative
            // submitted seconds; never reject the result by comparing these.
            nativeSeekTarget = nil
            if submitted != target {
                nativeSeekTarget = target
                candidate.currentPlaybackTime = target
                return // Never confirm the latest renderer gate with A's result.
            }
            let code = (note.userInfo?[IJKMPMoviePlayerDidSeekCompleteErrorKey] as? NSNumber)?.intValue ?? 0
            if code != 0 {
                isSeeking = false; seekTarget = nil
                seekCompleted = false
                renderer?.cancelSeek()
                completeSkip()
                capabilityMessage = Self.describe(stage: "seek", code: code, core: candidate)
                stage = "playback" // Recover existing playback, including same serial.
            } else {
                guard let serial = (note.userInfo?["IJKSeekVideoSerial"] as? NSNumber)?.int32Value else {
                    renderer?.cancelSeek()
                    isSeeking = false; seekTarget = nil
                    capabilityMessage = "seek 完成通知缺少真实队列 serial，请检查 framework 与 App 是否配套。"
                    completeSkip()
                    return
                }
                seekVideoSerial = serial
                seekFrameAcknowledged = serial < 0 // Audio-only stream has no video frame to acknowledge.
                if serial >= 0 { renderer?.confirmSeek(serial: serial) }
                seekCompleted = true
                stage = "playback"
            }
        case .IJKMPMoviePlayerPlaybackDidFinish:
            // Suppress only natural completion; decoder/network failures remain visible.
            let finishReason = (note.userInfo?[IJKMPMoviePlayerPlaybackDidFinishReasonUserInfoKey] as? NSNumber)?.intValue
            if isSeeking && finishReason == IJKMPMovieFinishReason.playbackEnded.rawValue {
                // A confirmed seek may legitimately land beyond the last video
                // frame. Settle without waiting for an impossible frame ack and
                // without treating an intermediate/old EOF as episode advance.
                if nativeSeekTarget == nil && seekCompleted {
                    renderer?.cancelSeek()
                    seekTarget = nil; isSeeking = false
                    wantsToPlay = false; isPlaying = false
                    candidate.pause()
                    position = Self.validTime(candidate.currentPlaybackTime)
                    renderer?.updateClock(position, rate: 0)
                    completeSkip()
                    stage = "seek-ended"
                }
                return
            }
            guard !didFinish else { return }
            didFinish = true
            wantsToPlay = false
            isPlaying = false
            let reason = (note.userInfo?[IJKMPMoviePlayerPlaybackDidFinishReasonUserInfoKey] as? NSNumber)?.intValue
            // Official FFP_MSG_ERROR supplies the numeric FFmpeg error under "error".
            // Error and user-exit are NOT natural completion and must not advance an episode.
            if reason == IJKMPMovieFinishReason.playbackError.rawValue {
                let code = (note.userInfo?["error"] as? NSNumber)?.intValue
                error = Self.describe(stage: stage, code: code, core: candidate)
                isReady = false
                stage = "failed"
                return
            }
            guard reason == IJKMPMovieFinishReason.playbackEnded.rawValue, error == nil else { return }
            refresh(candidate)
            guard core === candidate else { return }
            stage = "ended"
            onProgress?(position)
            guard core === candidate else { return }
            onEnd?()
            return
        default:
            break
        }
        refresh(candidate)
    }

    private func startTimer() {
        let tick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let core = self.core, self.error == nil else { return }
                self.refresh(core)
            }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
    }

    private func refresh(_ candidate: IJKFFMoviePlayerController) {
        guard core === candidate else { return }
        duration = Self.validTime(candidate.duration)
        isPlaying = !didFinish && candidate.isPlaying()
        let seconds = candidate.currentPlaybackTime
        guard seconds.isFinite, seconds >= 0 else { return }
        if isSeeking {
            guard isReady, seekCompleted, seekFrameAcknowledged else { return }
            seekTarget = nil
            isSeeking = false
        }
        position = seconds
        renderer?.updateClock(seconds, rate: isPlaying && !isSeeking ? Double(rate) : 0)
        pip?.invalidatePlaybackState()
        if !isSeeking { completeSkip() }
        onTime?(seconds)
        guard core === candidate, !isSeeking else { return }
        if isReady && abs(seconds - lastProgressTime) >= 5 {
            lastProgressTime = seconds
            onProgress?(seconds)
        }
    }

    private func releaseCore() {
        videoDisplayAspect = nil
        hasRenderedFrame = false
        nativeSeekTarget = nil
        seekVideoSerial = nil; seekFrameAcknowledged = false
        completeSkip()
        pipPossibleObservation = nil
        pipStartTimeout?.cancel(); pipStartTimeout = nil
        pip?.delegate = nil
        pip?.stopPictureInPicture()
        pip = nil
        pipStarting = false
        isPictureInPicture = false
        canStartPictureInPicture = false
        if Self.pipOwner === self { Self.pipOwner = nil }
        renderer?.close()
        renderer = nil
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        let previous = core
        core = nil // Invalidate identity before shutdown can enqueue any old notifications.
        previous?.view?.removeFromSuperview()
        previous?.stop()
        previous?.shutdown() // Official shutdown releases native FFmpeg threads asynchronously.
    }

    private func completeSkip() {
        skipTimeout?.cancel(); skipTimeout = nil
        let completion = skipCompletion; skipCompletion = nil
        completion?()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing { play() } else { pause() }
        renderer?.updateClock(position, rate: playing ? Double(rate) : 0)
        pictureInPictureController.invalidatePlaybackState()
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: duration > 0 ? CMTimeMakeWithSeconds(duration, preferredTimescale: 1000000) : .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { !isPlaying }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completeSkip()
        guard duration > 0, isReady, skipInterval.seconds.isFinite else { completionHandler(); return }
        skipCompletion = completionHandler
        seek(position + skipInterval.seconds)
        skipTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.completeSkip()
        }
    }
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipStarting = true; core?.setPauseInBackground(false)
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipStartTimeout?.cancel(); pipStartTimeout = nil
        pipStarting = false; isPictureInPicture = true
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        finishPictureInPicture()
        capabilityMessage = "画中画启动失败：\(error.localizedDescription)"
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { finishPictureInPicture() }
    private func finishPictureInPicture() {
        pipStartTimeout?.cancel(); pipStartTimeout = nil
        isPictureInPicture = false; pipStarting = false
        core?.setPauseInBackground(true)
        if UIApplication.shared.applicationState != .active { pause() }
        if Self.pipOwner === self { Self.pipOwner = nil }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if restorePictureInPictureUI?() == true { completionHandler(true); return }
        // A popped DetailView cannot honestly claim its @State change restores
        // navigation. Present the SAME controller/output in a real visible host.
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var host = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { completionHandler(false); return }
        while let presented = host.presentedViewController { host = presented }
        let restored = UIHostingController(rootView: RestoredPictureInPicturePlayer(controller: self))
        restored.modalPresentationStyle = .fullScreen
        host.present(restored, animated: true) { completionHandler(true) }
    }

    private static func validTime(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    private static func describe(stage: String, code: Int?, core: IJKFFMoviePlayerController) -> String {
        var parts = ["阶段 \(stage) · domain IJK/FFmpeg · code \(code.map(String.init) ?? "unavailable")"]
        if let monitor = core.monitor {
            if monitor.httpCode > 0 { parts.append("HTTP status \(monitor.httpCode)") }
            if monitor.httpError != 0 { parts.append("HTTP FFmpeg code \(monitor.httpError)") }
            if monitor.tcpError != 0 { parts.append("TCP code \(monitor.tcpError)") }
        }
        parts.append("请重试或更换播放源；诊断不包含签名 URL、Cookie 或请求头。")
        return parts.joined(separator: "\n")
    }

    private static func validatedHeaders(_ headers: [String: String]) -> (block: String, userAgent: String)? {
        let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
        var seen = Set<String>()
        var lines: [String] = []
        var userAgent = "IJKPlayer/0.8.8"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty, name.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte) ||
                (48...57).contains(byte) || punctuation.contains(byte)
            }), value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
                  seen.insert(name.lowercased()).inserted else { return nil }
            if name.lowercased() == "user-agent" {
                userAgent = value.trimmingCharacters(in: .whitespaces)
                guard !userAgent.isEmpty else { return nil }
            } else {
                lines.append("\(name): \(value)\r\n")
            }
        }
        return (lines.joined(), userAgent)
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        // Native teardown is performed explicitly by stop()/releaseCore() while
        // still MainActor-owned. Nonisolated deinit must not read published core.
    }
}

private struct RestoredPictureInPicturePlayer: View {
    @ObservedObject var controller: PlaybackController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            PlaybackSurface(controller: controller, fill: false)
            HStack {
                Button("后退15秒") { controller.seek(controller.position - 15) }
                Button(controller.isPlaying ? "暂停" : "播放") { if controller.isPlaying { controller.pause() } else { controller.play() } }
                Button("前进15秒") { controller.seek(controller.position + 15) }
                Button("关闭") { controller.stop(); dismiss() }
            }.padding()
        }.background(Color.black).foregroundStyle(.white)
    }
}

/// Video only. The SwiftUI controls are a transparent overlay owned by DetailView.
@MainActor struct PlaybackSurface: UIViewRepresentable {
    @ObservedObject var controller: PlaybackController
    var fill: Bool = false

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        controller.setFill(fill)
        guard let videoView = controller.view else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard videoView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        videoView.removeFromSuperview()
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.isUserInteractionEnabled = false
        container.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

typealias IJKPlaybackSurface = PlaybackSurface
typealias NativePlayer = PlaybackSurface

/// System route picker, not an implementation of remote video playback.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemGreen
        view.prioritizesVideoDevices = false
        view.accessibilityLabel = "选择系统音频输出设备"
        view.accessibilityHint = "当前 IJK 不支持直接 AirPlay 视频投送，视频可使用系统屏幕镜像"
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
