import SwiftUI
import UIKit

/// Plain controls only. SwiftUI owns the glass background, layout and navigation
/// lifetime. Never attach a host or overlay to a native tab controller.
@MainActor
final class GlassTabContainer: UIViewController {
    var dark = false
    var selection = 0
    var badge: String?
    var active = true
    var onSelect: ((Int) -> Void)?
    private let indicator = LiquidTabIndicatorView()
    private let items = UIStackView()
    private var controls: [TabControl] = []
    private var observers: [NSObjectProtocol] = []

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
        view.accessibilityIdentifier = "liuyun.mainTab.controls"
        view.addSubview(indicator)
        view.addSubview(items)
        items.axis = .horizontal
        items.distribution = .fillEqually
        controls = zip(["首页", "榜单", "我"], ["MainTabHome", "MainTabRank", "MainTabMe"])
            .enumerated().map { index, pair in
                let control = TabControl(title: pair.0, image: Self.icon(pair.1))
                control.tag = index
                control.accessibilityIdentifier = "liuyun.mainTab.item.\(index)"
                control.addTarget(self, action: #selector(selectTab(_:)), for: .touchUpInside)
                items.addArrangedSubview(control)
                return control
            }
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification,
                     UIAccessibility.reduceTransparencyStatusDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let frame = view.bounds.insetBy(dx: 6, dy: 6)
        items.frame = frame
        indicator.frame = frame
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        view.isUserInteractionEnabled = active
        for (index, control) in controls.enumerated() {
            control.update(selected: index == selection, dark: dark, badge: index == 2 ? badge : nil)
        }
        indicator.update(selection: selection, count: 3, dark: dark, enabled: true, bottomInset: 0)
    }

    func dismantle() {
        onSelect = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    @objc private func selectTab(_ control: TabControl) {
        selection = control.tag
        onSelect?(control.tag)
        refresh()
    }

    /// UIControl adds no automatic iOS 26 glass or selected-item background.
    private final class TabControl: UIControl {
        private let icon = UIImageView()
        private let title = UILabel()
        private let badgeLabel = UILabel()

        init(title text: String, image: UIImage) {
            super.init(frame: .zero)
            backgroundColor = .clear
            icon.image = image
            icon.contentMode = .scaleAspectFit
            title.text = text
            title.font = .systemFont(ofSize: 10)
            title.textAlignment = .center
            badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
            badgeLabel.textAlignment = .center
            badgeLabel.textColor = .white
            badgeLabel.backgroundColor = .systemRed
            badgeLabel.layer.cornerRadius = 8
            badgeLabel.clipsToBounds = true
            badgeLabel.isHidden = true
            let children: [UIView] = [icon, title, badgeLabel]
            for child in children {
                child.isUserInteractionEnabled = false
                child.isAccessibilityElement = false
                addSubview(child)
            }
            isAccessibilityElement = true
            accessibilityLabel = text
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let center = bounds.midX
            let top = (bounds.height - 36) / 2
            icon.frame = CGRect(x: center - 10, y: top, width: 20, height: 20)
            title.frame = CGRect(x: 2, y: top + 23, width: max(0, bounds.width - 4), height: 13)
            let badgeWidth = max(16, min(34, badgeLabel.intrinsicContentSize.width + 8))
            badgeLabel.frame = CGRect(x: min(center + 6, bounds.width - badgeWidth - 2),
                                      y: max(1, top - 5), width: badgeWidth, height: 16)
        }

        func update(selected: Bool, dark: Bool, badge: String?) {
            isSelected = selected
            let active = dark ? UIColor(red: 151 / 255, green: 211 / 255, blue: 39 / 255, alpha: 1)
                : UIColor(red: 0.23, green: 0.38, blue: 0.04, alpha: 1)
            let color = selected ? active : UIColor(white: dark ? 0.75 : 0.38, alpha: 1)
            icon.tintColor = color
            title.textColor = color
            badgeLabel.text = badge
            badgeLabel.isHidden = badge == nil || badge?.isEmpty == true
            accessibilityTraits = selected ? [.button, .selected] : .button
            accessibilityValue = badgeLabel.isHidden ? nil : "\(badge ?? "") 条未读"
            setNeedsLayout()
        }
    }
}
