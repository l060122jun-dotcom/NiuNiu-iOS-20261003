import SwiftUI
import AVKit
import Combine

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published var error: String?
    @Published var isReady = false
    @Published var rate: Float = 1
    @Published var isPictureInPicture = false
    private var statusObserver: NSKeyValueObservation?
    private var failedObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var timer: Any?
    private var lastProgressTime = -Double.infinity
    var onProgress: ((Double) -> Void)?
    var onTime: ((Double) -> Void)?
    var onEnd: (() -> Void)?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.allowsExternalPlayback = true
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard time.seconds.isFinite else { return }
            self?.onTime?(time.seconds)
            guard let self else { return }
            if abs(time.seconds - self.lastProgressTime) >= 5 {
                self.lastProgressTime = time.seconds
                self.onProgress?(time.seconds)
            }
        }
    }

    func load(_ url: URL, headers: [String: String] = [:], resume: Double = 0) {
        error = nil
        isReady = false
        lastProgressTime = -Double.infinity
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed { self.error = item.error?.localizedDescription ?? "当前视频无法播放" }
                if item.status == .readyToPlay {
                    self.isReady = true
                    if resume > 0 { self.player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
                    self.player.playImmediately(atRate: self.rate)
                }
            }
        }
        failedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let description = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放连接中断"
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.error = description
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.onEnd?()
            }
        }
        player.replaceCurrentItem(with: item)
        player.playImmediately(atRate: rate)
    }

    func setRate(_ value: Float) { rate = value; player.rate = value }
    func pause() { player.pause() }

    deinit {
        if let timer { player.removeTimeObserver(timer) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var onPictureInPictureChanged: ((Bool) -> Void)? = nil
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onChanged: ((Bool) -> Void)?
        init(_ callback: ((Bool) -> Void)?) { onChanged = callback }
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { onChanged?(true) }
        func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) { onChanged?(false) }
        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) { onChanged?(true) }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) { onChanged?(false) }
        func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onPictureInPictureChanged) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.videoGravity = videoGravity
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onChanged = onPictureInPictureChanged
        controller.videoGravity = videoGravity
        if controller.player !== player { controller.player = player }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemGreen
        view.prioritizesVideoDevices = true
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
