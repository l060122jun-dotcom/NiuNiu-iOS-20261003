import SwiftUI
import UIKit

/// An owned public UITabBar, not a painted capsule over a full-width touch surface.
/// The native TabView remains the navigation and toolbar visibility authority.
@MainActor
final class GlassTabContainer: UIViewController, UITabBarDelegate {
    var dark = false
    var selection = 0
    var badge: String?
    var active = true
    var onSelect: ((Int) -> Void)?
    private let capsule = UIView()
    private let glass = UIVisualEffectView()
    private let indicator = LiquidTabIndicatorView()
    private let compactBar = CompactTabBar()
    private let emptyMask = CALayer()
    private weak var nativeController: UITabBarController?
    private var originalInteraction = true
    private var originalAccessibilityHidden = false
    private var displayLink: CADisplayLink?
    private var appearanceKey = ""
    private var observers: [NSObjectProtocol] = []

    /// Rasterize to a 24pt image before UIKit measures it. @2x = 48px, @3x = 72px;
    /// renderingMode/template and UIImage.scale survive tabItem bridging.
    static func icon(_ name: String) -> UIImage {
        let size = CGSize(width: 24, height: 24)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let source = UIImage(named: name) ?? UIImage(systemName: "circle")!
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let ratio = min(size.width / max(1, source.size.width), size.height / max(1, source.size.height))
            let fitted = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
            source.draw(in: CGRect(x: (24 - fitted.width) / 2, y: (24 - fitted.height) / 2, width: fitted.width, height: fitted.height))
        }.withRenderingMode(.alwaysTemplate)
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        capsule.layer.cornerRadius = 32
        capsule.clipsToBounds = true
        capsule.isHidden = true
        glass.isUserInteractionEnabled = false
        indicator.isUserInteractionEnabled = false
        // Explicit sibling ordering: glass -> selection -> native item controls.
        capsule.addSubview(glass)
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
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    deinit {
        displayLink?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        capsule.removeFromSuperview()
        if let bar = nativeController?.tabBar, bar.layer.mask === emptyMask {
            bar.layer.mask = nil
            bar.isUserInteractionEnabled = originalInteraction
            bar.accessibilityElementsHidden = originalAccessibilityHidden
        }
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); refresh() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); refresh() }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        displayLink?.isPaused = !active
        var root: UIViewController = self
        while let parent = root.parent { root = parent }
        guard let owner = findTabController(root), owner.view.window != nil else {
            capsule.isHidden = true
            return
        }
        let native = owner.tabBar
        if nativeController !== owner {
            if let previous = nativeController?.tabBar, previous.layer.mask === emptyMask {
                previous.layer.mask = nil
                previous.isUserInteractionEnabled = originalInteraction
                previous.accessibilityElementsHidden = originalAccessibilityHidden
            }
            nativeController = owner
            originalInteraction = native.isUserInteractionEnabled
            originalAccessibilityHidden = native.accessibilityElementsHidden
        }
        // Empty public layer mask suppresses *all* native pixels, including its
        // full-width background, without changing isHidden/alpha visibility routing.
        native.layer.mask = emptyMask
        native.isUserInteractionEnabled = false
        native.accessibilityElementsHidden = true
        if capsule.superview !== owner.view { capsule.removeFromSuperview(); owner.view.addSubview(capsule) }

        let bounds = owner.view.bounds
        let safe = owner.view.safeAreaInsets
        let side: CGFloat = bounds.width < 360 ? 16 : 22
        let width = max(0, min(430, bounds.width - side * 2))
        capsule.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.maxY - safe.bottom - 10 - 64, width: width, height: 64)
        glass.frame = capsule.bounds
        // Bar and indicator share the same 50pt item coordinate space. The
        // existing indicator's 40pt capsule and two damped rebounds stay intact.
        let itemFrame = CGRect(x: 0, y: 7, width: width, height: 50)
        compactBar.frame = itemFrame
        indicator.frame = itemFrame
        let nativeFrame = native.layer.presentation()?.frame ?? native.frame
        let nativeVisible = !native.isHidden && native.alpha > 0.01 && nativeFrame.minY < bounds.maxY - 1
        // Poll public presentation geometry during interactive push/pop and
        // toolbar transitions too; no private item/background view inspection.
        capsule.isHidden = !nativeVisible
        capsule.isUserInteractionEnabled = nativeVisible
        capsule.accessibilityElementsHidden = !nativeVisible
        compactBar.selectedItem = compactBar.items?[min(2, max(0, selection))]
        compactBar.items?.last?.badgeValue = badge
        indicator.update(selection: selection, count: 3, dark: dark, enabled: nativeVisible, bottomInset: 0)

        let opaque = UIAccessibility.isReduceTransparencyEnabled
        let key = "\(dark)|\(opaque)"
        guard key != appearanceKey else { return }
        appearanceKey = key
        glass.effect = opaque ? nil : UIBlurEffect(style: dark ? .systemMaterialDark : .systemMaterialLight)
        glass.contentView.backgroundColor = (dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.98, alpha: 1)).withAlphaComponent(opaque ? 1 : 0.25)
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

    private final class TickProxy: NSObject {
        weak var owner: GlassTabContainer?
        init(_ owner: GlassTabContainer) { self.owner = owner }
        @objc func tick() { owner?.refresh() }
    }

    /// Detached from the system bottom edge: these are item coordinates, not
    /// a home-indicator safe-area extension. No KVC or private UIKit override.
    private final class CompactTabBar: UITabBar {
        override var safeAreaInsets: UIEdgeInsets { .zero }
    }
}
