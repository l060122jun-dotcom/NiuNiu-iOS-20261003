import SwiftUI
import UIKit

/// An owned public UITabBar, not a painted capsule over a full-width touch surface.
/// The native TabView remains the navigation and toolbar visibility authority.
@MainActor
final class GlassTabContainer: UIViewController, UITabBarDelegate {
    var dark = false
    var glassConfiguration = GlassConfiguration()
    var selection = 0
    var badge: String?
    var active = true { didSet { if oldValue != active { refresh() } } }
    var onSelect: ((Int) -> Void)?
    private let capsule = UIView()
    private let glass = UIHostingController(rootView: GlassTabSurface(configuration: GlassConfiguration(), dark: false))
    private var appliedGlassConfiguration: GlassConfiguration?
    private let indicator = LiquidTabIndicatorView()
    private let compactBar = CompactTabBar()
    private let emptyMask = CALayer()
    private weak var nativeController: UITabBarController?
    private weak var cachedRoot: UIViewController?
    private var originalInteraction = true
    private var originalAccessibilityHidden = false
    private var originalMask: CALayer?
    private var refreshPending = false
    private var refreshing = false
    private var invalidated = false
    private var displayLink: CADisplayLink?
    private var idleTimer: Timer?
    private var visibilityObservers: [NSKeyValueObservation] = []
    private var burstDeadline: CFTimeInterval = 0
    private weak var lastTransition: AnyObject?
    private var layoutFrame: CGRect?
    private var itemState: ItemState?
    private struct ItemState: Equatable {
        let selection: Int
        let badge: String?
        let dark: Bool
        let visible: Bool
        let opaque: Bool
        let reduceMotion: Bool
        let bounds: CGRect
    }
    private var appearanceKey = ""
    private var observers: [NSObjectProtocol] = []

    /// Rasterize to a 20pt image before UIKit measures it. @2x = 40px, @3x = 60px;
    /// renderingMode/template and UIImage.scale survive tabItem bridging.
    static func icon(_ name: String) -> UIImage {
        let size = CGSize(width: 20, height: 20)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let source = UIImage(named: name) ?? UIImage(systemName: "circle")!
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let ratio = min(size.width / max(1, source.size.width), size.height / max(1, source.size.height))
            let fitted = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
            source.draw(in: CGRect(x: (20 - fitted.width) / 2, y: (20 - fitted.height) / 2, width: fitted.width, height: fitted.height))
        }.withRenderingMode(.alwaysTemplate)
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        capsule.layer.cornerRadius = 35
        capsule.clipsToBounds = true
        capsule.isHidden = true
        glass.view.backgroundColor = .clear
        glass.view.isUserInteractionEnabled = false
        glass.view.accessibilityElementsHidden = true
        indicator.isUserInteractionEnabled = false
        // Explicit sibling ordering: glass -> selection -> native item controls.
        // The hosting view is mounted only after addChild, in refreshNow().
        capsule.addSubview(indicator)
        capsule.addSubview(compactBar)
        compactBar.delegate = self
        compactBar.itemPositioning = .fill
        compactBar.items = zip(["首页", "榜单", "我"], ["MainTabHome", "MainTabRank", "MainTabMe"])
            .enumerated().map { index, pair in UITabBarItem(title: pair.0, image: Self.icon(pair.1), tag: index) }
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification,
                     UIAccessibility.reduceTransparencyStatusDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        let link = CADisplayLink(target: TickProxy(self), selector: #selector(TickProxy.tick))
        link.preferredFramesPerSecond = 30
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Public visibility KVO and layout callbacks are the primary signals.
        // A 3Hz fallback catches presentation-only changes without per-tick Tasks.
        idleTimer = Timer.scheduledTimer(timeInterval: 1.0 / 3.0, target: TickProxy(self),
                                        selector: #selector(TickProxy.idle), userInfo: nil, repeats: true)
        if let idleTimer = idleTimer { RunLoop.main.add(idleTimer, forMode: .common) }
    }

    deinit {
        displayLink?.invalidate()
        idleTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        // The normal path is dismantle() on MainActor. Keep a fallback that
        // does not call UIKit from a potentially nonisolated deinitializer.
        let host = glass
        let overlay = capsule
        let owner = nativeController
        let mask = emptyMask
        let savedMask = originalMask
        let interaction = originalInteraction
        let accessibilityHidden = originalAccessibilityHidden
        DispatchQueue.main.async {
            if host.parent != nil { host.willMove(toParent: nil) }
            host.viewIfLoaded?.removeFromSuperview()
            if host.parent != nil { host.removeFromParent() }
            overlay.removeFromSuperview()
            if let bar = owner?.tabBar, bar.layer.mask === mask {
                bar.layer.mask = savedMask
                bar.isUserInteractionEnabled = interaction
                bar.accessibilityElementsHidden = accessibilityHidden
            }
        }
    }

    override func willMove(toParent parent: UIViewController?) {
        if parent == nil { unmount() }
        super.willMove(toParent: parent)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil { refresh() }
    }

    /// SwiftUI owns this bridge, but UIKit owns the mounted decorative child.
    /// Explicit teardown is required before the bridge itself is released.
    func dismantle() {
        guard !invalidated else { return }
        invalidated = true
        onSelect = nil
        displayLink?.invalidate()
        displayLink = nil
        idleTimer?.invalidate()
        idleTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        unmount()
    }

    private func unmount() {
        visibilityObservers.removeAll()
        if glass.parent != nil { glass.willMove(toParent: nil) }
        glass.viewIfLoaded?.removeFromSuperview()
        if glass.parent != nil { glass.removeFromParent() }
        capsule.removeFromSuperview()
        capsule.isHidden = true
        capsule.isUserInteractionEnabled = false
        if let bar = nativeController?.tabBar, bar.layer.mask === emptyMask {
            bar.layer.mask = originalMask
            bar.isUserInteractionEnabled = originalInteraction
            bar.accessibilityElementsHidden = originalAccessibilityHidden
        }
        nativeController = nil
        cachedRoot = nil
        originalMask = nil
        layoutFrame = nil
        itemState = nil
        lastTransition = nil
        displayLink?.isPaused = true
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); startBurst(); refresh() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); startBurst(); refresh() }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refresh()
    }

    func refresh() {
        // MainActor alone does not prevent SwiftUI update-transaction reentry.
        // Coalesce all signals and mutate containment/rootView on the next turn.
        guard !invalidated, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refreshNow()
        }
    }

    private func refreshNow() {
        guard !invalidated, isViewLoaded else { return }
        guard !refreshing else { refresh(); return }
        refreshing = true
        defer { refreshing = false }
        guard parent != nil, viewIfLoaded?.window != nil else { unmount(); return }
        guard active else {
            capsule.isHidden = true
            capsule.isUserInteractionEnabled = false
            itemState = nil
            displayLink?.isPaused = true
            return
        }
        var root: UIViewController = self
        while let parent = root.parent { root = parent }
        let owner: UITabBarController?
        if let cached = nativeController, cachedRoot === root, cached.viewIfLoaded?.window != nil,
           belongsToRoot(cached, root: root) {
            owner = cached
        } else {
            owner = findTabController(root)
        }
        guard let owner = owner, owner.viewIfLoaded?.window != nil else {
            unmount()
            return
        }
        let native = owner.tabBar
        if nativeController !== owner {
            unmount()
            nativeController = owner
            cachedRoot = root
            layoutFrame = nil
            itemState = nil
            originalInteraction = native.isUserInteractionEnabled
            originalAccessibilityHidden = native.accessibilityElementsHidden
            originalMask = native.layer.mask
            visibilityObservers = [
                native.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.nativeVisibilityChanged() }
                },
                native.observe(\.alpha, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.nativeVisibilityChanged() }
                }
            ]
        }
        cachedRoot = root
        // Empty public layer mask suppresses *all* native pixels, including its
        // full-width background, without changing isHidden/alpha visibility routing.
        if native.layer.mask !== emptyMask { native.layer.mask = emptyMask }
        if native.isUserInteractionEnabled { native.isUserInteractionEnabled = false }
        if !native.accessibilityElementsHidden { native.accessibilityElementsHidden = true }
        // The hosting controller must belong to the same controller whose view
        // contains its root view. UIKit 26 enforces this during window attachment.
        if glass.parent !== owner || capsule.superview !== owner.view || glass.view.superview !== capsule {
            if glass.parent != nil {
                glass.willMove(toParent: nil)
                glass.view.removeFromSuperview()
                glass.removeFromParent()
            }
            capsule.removeFromSuperview()
            owner.addChild(glass)
            capsule.insertSubview(glass.view, at: 0)
            owner.view.addSubview(capsule)
            glass.didMove(toParent: owner)
            layoutFrame = nil
            itemState = nil
        }

        let bounds = owner.view.bounds
        let safe = owner.view.safeAreaInsets
        let width = max(0, min(280, bounds.width - 88))
        let frame = CGRect(x: (bounds.width - width) / 2, y: bounds.maxY - safe.bottom - 10 - 70, width: width, height: 70)
        if layoutFrame != frame {
            layoutFrame = frame
            capsule.frame = frame
            glass.view.frame = capsule.bounds
            // The complete icon/title stack and selection share 58pt coordinates.
            let itemFrame = CGRect(x: 6, y: 6, width: max(0, width - 12), height: 58)
            compactBar.frame = itemFrame
            indicator.frame = itemFrame
        }
        observeTransition(owner)
        let nativeFrame = native.layer.presentation()?.frame ?? native.frame
        let nativeVisible = !native.isHidden && native.alpha > 0.01 && nativeFrame.minY < bounds.maxY - 1
        // Poll public presentation geometry during interactive push/pop and
        // toolbar transitions too; no private item/background view inspection.
        let opaque = UIAccessibility.isReduceTransparencyEnabled
        let state = ItemState(selection: min(2, max(0, selection)), badge: badge, dark: dark,
                              visible: nativeVisible, opaque: opaque,
                              reduceMotion: UIAccessibility.isReduceMotionEnabled, bounds: indicator.bounds)
        if state != itemState {
            if itemState?.visible != nativeVisible {
                capsule.isHidden = !nativeVisible
                capsule.isUserInteractionEnabled = nativeVisible
                capsule.accessibilityElementsHidden = !nativeVisible
            }
            if itemState?.selection != state.selection { compactBar.selectedItem = compactBar.items?[state.selection] }
            if itemState == nil || itemState?.badge != badge { compactBar.items?.last?.badgeValue = badge }
            indicator.update(selection: state.selection, count: 3, dark: dark, enabled: nativeVisible, bottomInset: 0)
            itemState = state
        }
        displayLink?.isPaused = CACurrentMediaTime() >= burstDeadline
        let opacity = opaque ? 1 : glassConfiguration.normalizedOpacity
        let key = "\(dark)|\(opaque)|\(opacity)"
        guard key != appearanceKey || appliedGlassConfiguration != glassConfiguration else { return }
        appearanceKey = key
        appliedGlassConfiguration = glassConfiguration
        glass.rootView = GlassTabSurface(configuration: glassConfiguration, dark: dark)
        capsule.layer.borderWidth = 0.75
        capsule.layer.borderColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.12).cgColor
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = nil
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        let active = dark ? UIColor(red: 151 / 255, green: 211 / 255, blue: 39 / 255, alpha: 1) : UIColor(red: 0.23, green: 0.38, blue: 0.04, alpha: 1)
        let inactive = UIColor(white: dark ? 0.75 : 0.38, alpha: 1)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.iconColor = inactive
            item.selected.iconColor = active
            item.normal.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: inactive]
            item.selected.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: active]
            item.normal.badgeBackgroundColor = .systemRed
            item.selected.badgeBackgroundColor = .systemRed
        }
        compactBar.standardAppearance = appearance
        compactBar.scrollEdgeAppearance = appearance
        compactBar.tintColor = active
        compactBar.unselectedItemTintColor = inactive
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        selection = item.tag
        onSelect?(item.tag)
        refresh()
    }

    private func findTabController(_ controller: UIViewController) -> UITabBarController? {
        if let tab = controller as? UITabBarController { return tab }
        for child in controller.children {
            if let tab = findTabController(child) { return tab }
        }
        return nil
    }

    private func belongsToRoot(_ controller: UIViewController, root: UIViewController) -> Bool {
        var ancestor: UIViewController = controller
        while let parent = ancestor.parent { ancestor = parent }
        return ancestor === root
    }

    private func startBurst(duration: CFTimeInterval = 0.5) {
        guard active, !invalidated else { return }
        burstDeadline = max(burstDeadline, CACurrentMediaTime() + duration)
        displayLink?.isPaused = false
    }

    private func nativeVisibilityChanged() {
        startBurst()
        refresh()
    }

    private func observeTransition(_ owner: UITabBarController) {
        let navigation = owner.selectedViewController as? UINavigationController
        let coordinator = navigation?.topViewController?.transitionCoordinator
            ?? owner.selectedViewController?.transitionCoordinator ?? owner.transitionCoordinator
        guard let coordinator = coordinator else { lastTransition = nil; return }
        if lastTransition !== (coordinator as AnyObject) {
            lastTransition = coordinator as AnyObject
            startBurst(duration: max(0.5, coordinator.transitionDuration + 0.1))
        }
        // Interactive gestures can outlast the nominal transition duration.
        if coordinator.isInteractive { startBurst() }
    }

    @MainActor
    private final class TickProxy: NSObject {
        weak var owner: GlassTabContainer?
        init(_ owner: GlassTabContainer) { self.owner = owner }
        @objc func tick() {
            // Installed only on RunLoop.main; no asynchronous Task per frame.
            owner?.refresh()
        }
        @objc func idle() {
            guard let owner = owner, owner.active, owner.displayLink?.isPaused != false else { return }
            owner.refresh()
        }
    }

    /// Detached from the system bottom edge: these are item coordinates, not
    /// a home-indicator safe-area extension. No KVC or private UIKit override.
    private final class CompactTabBar: UITabBar {
        override var safeAreaInsets: UIEdgeInsets { .zero }
    }
}

/// Explicit UIKit -> SwiftUI bridge. Only the capsule's decorative background is
/// hosted; UITabBar controls, indicator, navigation and polling stay UIKit-owned.
private struct GlassTabSurface: View {
    let configuration: GlassConfiguration
    let dark: Bool

    var body: some View {
        GlassSurface(shape: Capsule(), material: .regularMaterial, dark: dark)
            .environment(\.liuyunGlassConfiguration, configuration)
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}
