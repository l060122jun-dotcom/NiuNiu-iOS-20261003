import SwiftUI
import UIKit
import AVKit
import Combine
import IJKMediaFramework

/// The playback engine is Bilibili's IJKFFMoviePlayerController (FFmpeg), not AVPlayer.
@MainActor
final class PlaybackController: ObservableObject {
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

    // An IJK OpenGL view is neither AVPlayerLayer nor an AVSampleBufferDisplayLayer.
    // Supporting PiP requires a new sample-buffer rendering pipeline, not a dummy AVPlayer.
    let isPictureInPicture = false
    let canStartPictureInPicture = false
    let pictureInPictureStatus = "当前 IJK OpenGL 渲染不支持系统画中画；需要实现样本缓冲输出和 PiP 播放代理。"
    let airPlayStatus = "系统路由按钮可选择音频设备；当前 IJK 未实现 AirPlay 视频远程投送。视频可使用系统屏幕镜像。"

    var onProgress: ((Double) -> Void)?
    var onTime: ((Double) -> Void)?
    var onEnd: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var pendingSeek: Double?
    private var seekTarget: Double?
    private var seekCompleted = false
    private var wantsToPlay = true
    private var didFinish = false
    private var fill = false
    private var lastProgressTime = -Double.infinity

    init() {
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
        options.setFormatOptionValue(headerOptions.userAgent, forKey: "user_agent")
        if !headerOptions.block.isEmpty {
            // FFmpeg HTTP AVOptions belong to FORMAT, never PLAYER or CODEC.
            options.setFormatOptionValue(headerOptions.block, forKey: "headers")
        }
        guard let candidate = IJKFFMoviePlayerController(contentURL: url, with: options) else {
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
        core = candidate
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
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        if !isReady {
            pendingSeek = target
            isSeeking = true
            return
        }
        didFinish = false
        seekTarget = target
        seekCompleted = false
        isSeeking = true
        stage = "seek"
        core.currentPlaybackTime = target
        // Do not publish the requested target as actual progress; the timer reads IJK's clock.
    }

    func seek(seconds: Double) { seek(seconds) }

    func setRate(_ value: Float) {
        guard value.isFinite, value > 0 else { return }
        rate = min(max(value, 0.25), 4)
        core?.playbackRate = rate
    }

    func setFill(_ value: Bool) {
        fill = value
        core?.scalingMode = value ? .aspectFill : .aspectFit
    }

    /// Applies to the next load. Reload the current source explicitly to change decoders.
    func setVideoToolboxEnabled(_ value: Bool) {
        videoToolboxEnabled = value
    }

    func requestPictureInPicture() {
        capabilityMessage = pictureInPictureStatus
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
            IJKMPMediaPlaybackIsPreparedToPlayDidChangeNotification,
            IJKMPMoviePlayerPlaybackStateDidChangeNotification,
            IJKMPMoviePlayerLoadStateDidChangeNotification,
            IJKMPMoviePlayerPlaybackDidFinishNotification,
            IJKMPMoviePlayerOpenInputNotification,
            IJKMPMoviePlayerFindStreamInfoNotification,
            IJKMPMoviePlayerComponentOpenNotification,
            IJKMPMoviePlayerFirstVideoFrameRenderedNotification,
            IJKMPMoviePlayerDidSeekCompleteNotification
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
        case IJKMPMediaPlaybackIsPreparedToPlayDidChangeNotification:
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
        case IJKMPMoviePlayerOpenInputNotification:
            stage = "open-input"
        case IJKMPMoviePlayerFindStreamInfoNotification:
            stage = "find-stream-info"
        case IJKMPMoviePlayerComponentOpenNotification:
            stage = "open-codec"
        case IJKMPMoviePlayerFirstVideoFrameRenderedNotification:
            stage = "render"
        case IJKMPMoviePlayerDidSeekCompleteNotification:
            guard isSeeking, let target = seekTarget else { return }
            if let reported = (note.userInfo?[IJKMPMoviePlayerDidSeekCompleteTargetKey] as? NSNumber)?.doubleValue,
               abs(reported / 1000 - target) > 1 { return }
            let code = (note.userInfo?[IJKMPMoviePlayerDidSeekCompleteErrorKey] as? NSNumber)?.intValue ?? 0
            if code != 0 {
                isSeeking = false; seekTarget = nil
                error = Self.describe(stage: "seek", code: code, core: candidate)
            } else {
                seekCompleted = true
                stage = "playback"
            }
        case IJKMPMoviePlayerPlaybackDidFinishNotification:
            // Suppress only natural completion; decoder/network failures remain visible.
            let finishReason = (note.userInfo?[IJKMPMoviePlayerPlaybackDidFinishReasonUserInfoKey] as? NSNumber)?.intValue
            if isSeeking && finishReason == IJKMPMovieFinishReason.playbackEnded.rawValue { return }
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
            guard isReady, seekCompleted, let target = seekTarget, abs(seconds - target) <= 1 else { return }
            seekTarget = nil
            isSeeking = false
        }
        position = seconds
        onTime?(seconds)
        guard core === candidate, !isSeeking else { return }
        if isReady && abs(seconds - lastProgressTime) >= 5 {
            lastProgressTime = seconds
            onProgress?(seconds)
        }
    }

    private func releaseCore() {
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
