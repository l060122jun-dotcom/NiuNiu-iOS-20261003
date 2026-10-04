import SwiftUI
import UIKit
import MediaPlayer

// The control layer only accepts values and actions; it does not own a playback engine.
@MainActor final class AndroidPlayerInteraction: ObservableObject {
    @Published var visible = true
    @Published var feedback: String?
    @Published var interacting = false
    @Published private(set) var menuOpen = false
    private var hideTask: Task<Void, Never>?
    func show() { visible = true; scheduleHide() }
    func toggle() { guard !menuOpen else { return }; visible.toggle(); if visible { scheduleHide() } else { hideTask?.cancel() } }
    func begin() { interacting = true; hideTask?.cancel() }
    func end() { interacting = false; feedback = nil; scheduleHide() }
    // Menu ownership is independent of slider/gesture begin/end callbacks.
    func setMenuOpen(_ open: Bool) {
        menuOpen = open
        if open { visible = true; hideTask?.cancel() }
        else { scheduleHide() }
    }
    func scheduleHide() {
        hideTask?.cancel()
        guard visible, !interacting, !menuOpen else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, !self.interacting, !self.menuOpen else { return }
            self.visible = false
        }
    }
    func cancel() { hideTask?.cancel(); feedback = nil; interacting = false; menuOpen = false }
    deinit { hideTask?.cancel() }
}

@MainActor struct AndroidPlayerControls<More: View>: View {
    @ObservedObject var interaction: AndroidPlayerInteraction
    @Binding var locked: Bool
    let sessionID: String
    let title: String
    let time: Double
    let duration: Double
    let playing: Bool
    let fullScreen: Bool
    let wide: Bool
    let fill: Bool
    let canNext: Bool
    let rate: Float
    let rates: [Float]
    let danmakuShown: Bool
    let onBack: () -> Void
    let onPlay: () -> Void
    let onNext: () -> Void
    let onSeek: (Double) -> Void
    let onFullScreen: () -> Void
    let onFill: () -> Void
    let onSettings: () -> Void
    let onEpisodes: () -> Void
    let onDanmaku: () -> Void
    let onRate: (Float) -> Void
    let onCast: () -> Void
    // Supplied by the engine adapter only when a real PiP controller is available.
    var onPictureInPicture: (() -> Void)? = nil
    @ViewBuilder var more: () -> More
    @State private var scrubbing = false
    @State private var scrubTime: Double = 0
    @State private var openMenu: ControlMenu?
    @State private var menuExpanded = false
    @State private var menuClosing = false
    private enum ControlMenu: Equatable { case more, rate }
    private let menuAnimation = Animation.spring(response: 0.28, dampingFraction: 1)

    var body: some View {
        ZStack {
            if locked {
                if interaction.visible {
                    HStack {
                        icon("解锁", "lock.fill") { locked = false; interaction.show() }
                            .background(Color.black.opacity(0.5), in: Circle())
                        Spacer()
                    }.padding(.horizontal, 16)
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if fullScreen {
                        HStack {
                            icon("锁屏", "lock.open") { locked = true; interaction.show() }
                                .background(Color.black.opacity(0.35), in: Circle())
                            Spacer()
                            icon(fill ? "画面适应" : "画面填充", "arrow.up.left.and.down.right") { onFill(); interaction.show() }
                                .background(Color.black.opacity(0.35), in: Circle())
                        }.padding(.horizontal, 16)
                        Spacer(minLength: 0)
                    }
                    bottomBar
                }
                // Keep native Menu's presenter mounted while UIKit owns its
                // popup. Auto-hide changes visibility, not presenter identity.
                .opacity(interaction.visible ? 1 : 0)
                .allowsHitTesting(interaction.visible)
            }
            if let feedback = interaction.feedback, !locked {
                Text(feedback).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
        .overlayPreferenceValue(PlayerControlBoundsKey.self) { anchors in
            if let openMenu, !locked { menuOverlay(openMenu, anchors: anchors) }
        }
        .foregroundStyle(.white).buttonStyle(.plain)
        .onAppear { interaction.show() }
        .onDisappear { cancelScrubbing(); resetMenu(); interaction.cancel() }
        .onChange(of: sessionID) { _ in resetMenu(); scrubbing = false; scrubTime = 0; interaction.cancel() }
        .onChange(of: locked) { value in if value { cancelScrubbing(); resetMenu(); interaction.setMenuOpen(false) } }
        .onChange(of: fullScreen) { _ in cancelScrubbing() }
        .onChange(of: interaction.menuOpen) { open in if !open { resetMenu() } }
        .onChange(of: duration) { _ in scrubTime = safePosition(scrubTime) }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            icon(fullScreen ? "退出全屏" : "返回", "chevron.left", action: onBack)
            Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false)
            icon("电视投屏", "tv", action: onCast)
            if let onPictureInPicture { icon("画中画", "pip", action: onPictureInPicture) }
            icon("播放设置", "gearshape", action: onSettings)
            Menu { more() } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }
                .accessibilityLabel("更多播放功能")
                .simultaneousGesture(TapGesture().onEnded { interaction.show() })
        }
        .padding(.horizontal, wide ? 16 : 4).padding(.top, 4)
        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if wide {
                HStack(spacing: 12) {
                    icon("后退15秒", "gobackward.15") { onSeek(time - 15) }
                    icon("前进15秒", "goforward.15") { onSeek(time + 15) }
                    Spacer(minLength: 0)
                    icon(danmakuShown ? "关闭弹幕" : "打开弹幕", "text.bubble", action: onDanmaku)
                    Button("选集 / 换源") { interaction.show(); onEpisodes() }.font(.system(size: 14))
                    rateMenu
                }
            }
            HStack(spacing: 4) {
                icon(playing ? "暂停" : "播放", playing ? "pause.fill" : "play.fill", action: onPlay)
                icon("下一集", "forward.end.fill", action: onNext).disabled(!canNext)
                Text(Self.format(scrubbing ? scrubTime : time)).font(.system(size: 11)).monospacedDigit()
                    .allowsHitTesting(false)
                Slider(value: Binding(get: { safePosition(scrubbing ? scrubTime : time) }, set: { scrubTime = safePosition($0) }), in: 0...safeDuration, onEditingChanged: { active in
                    if active { scrubTime = safePosition(time); scrubbing = true; interaction.begin() }
                    else if scrubbing { onSeek(safePosition(scrubTime)); scrubbing = false; interaction.end() }
                }).tint(.green).disabled(!duration.isFinite || duration <= 0).accessibilityLabel("播放进度")
                Text(Self.format(duration)).font(.system(size: 11)).monospacedDigit().allowsHitTesting(false)
                icon(fullScreen ? "退出全屏" : "全屏", fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: onFullScreen)
            }
        }
        .padding(.horizontal, wide ? 16 : 4).padding(.bottom, 4)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        .anchorPreference(key: PlayerControlBoundsKey.self, value: .bounds) { [.bottomBar: $0] }
    }
    private var rateMenu: some View {
        Button { toggleMenu(.rate) } label: { Text(String(format: "%g×", rate)).font(.system(size: 14)).frame(minWidth: 44, minHeight: 40) }
            .accessibilityLabel("播放倍速")
            .anchorPreference(key: PlayerControlBoundsKey.self, value: .bounds) { [.rate: $0] }
    }
    private func toggleMenu(_ menu: ControlMenu) {
        if openMenu == menu, menuExpanded { closeMenu() }
        else {
            menuClosing = false
            menuExpanded = false
            openMenu = menu
            interaction.setMenuOpen(true)
            // Wait for the anchored surface to mount before animating it.
            Task { @MainActor in
                await Task.yield()
                guard openMenu == menu, interaction.menuOpen, !menuClosing else { return }
                withAnimation(menuAnimation) { menuExpanded = true }
            }
        }
    }
    private func closeMenu() {
        guard openMenu != nil, !menuClosing else { return }
        let wasExpanded = menuExpanded
        menuClosing = true
        withAnimation(menuAnimation) { menuExpanded = false }
        // A second tap can arrive before the opening animation mounts.
        if !wasExpanded { finishMenuClose() }
    }
    private func finishMenuClose() {
        guard menuClosing, !menuExpanded else { return }
        openMenu = nil
        menuClosing = false
        interaction.setMenuOpen(false)
    }
    private func resetMenu() {
        menuClosing = false
        menuExpanded = false
        openMenu = nil
    }
    private func menuOverlay(_ menu: ControlMenu, anchors: [PlayerControlAnchor: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            if let anchor = anchors[menu == .more ? .more : .rate] {
                let button = geometry[anchor]
                let bottom = anchors[.bottomBar].map { geometry[$0].minY } ?? geometry.size.height
                let width = min(280, max(1, geometry.size.width - 16))
                let x = min(max(8, button.maxX - width), max(8, geometry.size.width - width - 8))
                let top = menu == .more ? min(button.maxY + 4, max(8, bottom - 49)) : 8
                let availableHeight = max(1, bottom - top - 6)
                // The viewport must not depend on a preference measured inside
                // its own ScrollView: transient zero/row measurements collapse
                // the surface and can leave only the disabled first row visible.
                let preferredHeight: CGFloat = menu == .more ? 420 : CGFloat(rates.count) * 49
                let height = min(preferredHeight, availableHeight)
                let y = menu == .more ? top : max(8, button.minY - height - 4)
                // The usual origin is topTrailing, adjusted to the actual
                // ellipsis centre after clamping (also survives rotation).
                let origin = UnitPoint(x: (button.midX - x) / width, y: (button.midY - y) / height)
                ZStack(alignment: .topLeading) {
                // Only consume an outside tap while a menu is open. No pan/hold or
                // high-priority recognizers: system navigation edge gestures remain free.
                Color.clear.contentShape(Rectangle()).onTapGesture { closeMenu() }
                    .frame(width: geometry.size.width, height: max(0, bottom))
                VStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            if menu == .more {
                                more()
                            } else {
                                ForEach(rates, id: \.self) { value in
                                    Button(String(format: "%g×", value)) { onRate(value) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .buttonStyle(PlayerMenuActionStyle(close: closeMenu))
                    }
                }
                .foregroundStyle(Color.white.opacity(0.8)).tint(Color.white.opacity(0.8))
                .frame(width: width, height: height)
                .glassBackground(in: RoundedRectangle(cornerRadius: 26, style: .continuous), dark: true)
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
                .scaleEffect(menuExpanded ? 1 : 0.001, anchor: origin)
                .opacity(menuExpanded ? 1 : 0)
                .modifier(PlayerMenuAnimationCompletion(progress: menuExpanded ? 1 : 0, closing: menuClosing, completion: finishMenuClose))
                .offset(x: x, y: y)
                .allowsHitTesting(menuExpanded)
                }
            }
        }
    }
    private func icon(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button { closeMenu(); interaction.show(); action() } label: {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 40, height: 40)
        }.accessibilityLabel(title)
    }
    private func cancelScrubbing() {
        // View replacement/locking can cancel a native slider interaction
        // without delivering onEditingChanged(false). Never retain its preview.
        guard scrubbing else { return }
        scrubbing = false
        scrubTime = safePosition(time)
        interaction.end()
    }
    static func format(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(min(86_400_000, max(0, value))) : 0
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private var safeDuration: Double { duration.isFinite ? min(86_400_000, max(1, duration)) : 1 }
    private func safePosition(_ value: Double) -> Double { value.isFinite ? min(safeDuration, max(0, value)) : 0 }
}

// Executes the original generic more() action, then releases menu ownership.
// Explicit plain style on expandable submenus keeps their rows open for selection.
private struct PlayerMenuActionStyle: PrimitiveButtonStyle {
    let close: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button {
            close()
            configuration.trigger()
        } label: {
            configuration.label
                .font(.system(size: 17))
                .opacity(isEnabled ? 1 : 0.35)
                .frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
                .padding(.leading, 34).padding(.trailing, 18)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5).allowsHitTesting(false) }
        }.buttonStyle(.plain)
    }
}

private enum PlayerControlAnchor: Hashable { case more, rate, bottomBar }
private struct PlayerControlBoundsKey: PreferenceKey {
    static var defaultValue: [PlayerControlAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PlayerControlAnchor: Anchor<CGRect>], nextValue: () -> [PlayerControlAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// Observe the animatable value rather than using iOS 17's completion API or
// a fixed timer, so the auto-hide lock is released only after the reverse path.
private struct PlayerMenuAnimationCompletion: AnimatableModifier {
    var progress: Double
    let closing: Bool
    let completion: () -> Void
    var animatableData: Double {
        get { progress }
        set {
            progress = newValue
            if closing, newValue == 0 { DispatchQueue.main.async(execute: completion) }
        }
    }
    func body(content: Content) -> some View { content }
}

// Only the disclosure header bypasses the action style. Selecting a child
// still invokes its original action and closes the owning popover.
struct PlayerMenuDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.spring(response: 0.28, dampingFraction: 1)) { expanded.toggle() } } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
                .padding(.leading, 34).padding(.trailing, 18)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5).allowsHitTesting(false) }
            }.buttonStyle(.plain).accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded { content() }
        }
    }
}

// This surface sits BELOW interactive danmaku and control buttons, not above them.
// UIKit recognizers arbitrate tap/hold/pan so a slider never also starts a seek gesture.
@MainActor struct AndroidPlayerGestureSurface: UIViewRepresentable {
    let sessionID: String
    let enabled: Bool
    let locked: Bool
    let time: Double
    let duration: Double
    let holdRate: Float
    let interaction: AndroidPlayerInteraction
    let onPlay: () -> Void
    let onSeek: (Double) -> Void
    let onHold: (Bool) -> Void
    func makeUIView(context: Context) -> GestureView { GestureView() }
    func updateUIView(_ view: GestureView, context: Context) {
        if view.configuration?.sessionID != sessionID { view.cancelInteraction() }
        view.configuration = self
        if !enabled || locked { view.cancelInteraction() }
    }
    static func dismantleUIView(_ view: GestureView, coordinator: ()) { view.cancelInteraction() }

    final class GestureView: UIView {
        var configuration: AndroidPlayerGestureSurface?
        private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 80, height: 20))
        private var volumeSlider: UISlider? { volumeView.subviews.compactMap { $0 as? UISlider }.first }
        private var originTime = 0.0
        private var originBrightness: CGFloat = 0
        private var originVolume: Float = 0
        private var seekTarget: Double?
        private var mode = 0
        private var holding = false
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            volumeView.showsRouteButton = false
            addSubview(volumeView)
            let single = UITapGestureRecognizer(target: self, action: #selector(tap))
            let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap))
            double.numberOfTapsRequired = 2
            single.require(toFail: double)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
            hold.minimumPressDuration = 0.35; hold.allowableMovement = 12
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            single.require(toFail: hold); double.require(toFail: hold)
            [single, double, hold, pan].forEach { addGestureRecognizer($0) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func tap() { configuration?.interaction.toggle() }
        @objc private func doubleTap() {
            guard let config = configuration, config.enabled, !config.locked else { return }
            config.onPlay(); config.interaction.show()
        }
        @objc private func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let config = configuration else { return }
            if recognizer.state == .began, config.enabled, !config.locked {
                holding = true; config.interaction.begin(); config.onHold(true)
                config.interaction.feedback = String(format: "临时 %g× · 松手恢复", config.holdRate)
            } else if [.ended, .cancelled, .failed].contains(recognizer.state) { cancelInteraction() }
        }
        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let config = configuration, config.enabled, !config.locked, !holding else { return }
            let translation = recognizer.translation(in: self)
            if recognizer.state == .began {
                // Leave system navigation/home edge gestures alone.
                let point = recognizer.location(in: self)
                guard point.x > 20, point.x < bounds.width - 20, point.y > 12, point.y < bounds.height - 12 else { mode = 0; return }
                originTime = config.time.isFinite ? max(0, config.time) : 0; originBrightness = UIScreen.main.brightness
                originVolume = volumeSlider?.value ?? 0.5
                let velocity = recognizer.velocity(in: self)
                mode = abs(velocity.x) >= abs(velocity.y) ? 1 : (point.x < bounds.width / 2 ? 2 : 3)
                config.interaction.begin()
            }
            if recognizer.state == .changed {
                switch mode {
                case 1 where config.duration.isFinite && config.duration > 0:
                    let span = min(180, max(60, config.duration / 5))
                    let target = min(config.duration, max(0, originTime + Double(translation.x / max(1, bounds.width)) * span))
                    seekTarget = target
                    config.interaction.feedback = "\(AndroidPlayerControls<EmptyView>.format(target)) / \(AndroidPlayerControls<EmptyView>.format(config.duration))"
                case 2:
                    let brightness = min(1, max(0.05, originBrightness - translation.y / max(1, bounds.height)))
                    UIScreen.main.brightness = brightness
                    config.interaction.feedback = "亮度 \(Int(brightness * 100))%"
                case 3:
                    let volume = min(1, max(0, originVolume - Float(translation.y / max(1, bounds.height))))
                    volumeSlider?.setValue(volume, animated: false)
                    volumeSlider?.sendActions(for: .valueChanged)
                    config.interaction.feedback = "音量 \(Int(volume * 100))%"
                default: break
                }
            }
            if [.ended, .cancelled, .failed].contains(recognizer.state) {
                if recognizer.state == .ended, let seekTarget { config.onSeek(seekTarget) }
                seekTarget = nil; mode = 0; config.interaction.end()
            }
        }
        func cancelInteraction() {
            if holding { configuration?.onHold(false); holding = false }
            seekTarget = nil; mode = 0
            if configuration?.interaction.interacting == true { configuration?.interaction.end() }
        }
    }
}
