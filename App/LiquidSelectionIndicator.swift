import SwiftUI
import UIKit

/// Shared deterministic envelope: travel, compression, exactly two rebounds.
enum LiquidSelectionMotion {
    static let duration: Double = 0.72
    static let travelEnd: Double = 0.45
    static let times: [Double] = [0, 0.23, 0.45, 0.52, 0.63, 0.72, 0.81, 0.90, 1]
    static let stretches: [CGFloat] = [0, 1, 0, 0, 0, 0, 0, 0, 0]
    static let scales: [CGFloat] = [1, 1, 1, 0.94, 1.045, 0.985, 1.022, 0.994, 1]

    static func sample(_ values: [CGFloat], at progress: Double) -> CGFloat {
        let progress = min(1, max(0, progress))
        for index in 1..<times.count where progress <= times[index] {
            let fraction = CGFloat((progress - times[index - 1]) / (times[index] - times[index - 1]))
            return values[index - 1] + (values[index] - values[index - 1]) * fraction
        }
        return values[values.count - 1]
    }

}

/// Original compatibility treatment, not iOS 26's native Liquid Glass.
struct LiquidCapsuleShape: Shape {
    var stretch: CGFloat
    var direction: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(stretch, direction) }
        set { stretch = newValue.first; direction = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let amount = min(16, max(0, stretch))
        let leading = direction >= 0 ? amount * 0.28 : amount
        let trailing = direction >= 0 ? amount : amount * 0.28
        let bounds = rect.insetBy(dx: -amount * 0.25, dy: amount * 0.08)
        let left = bounds.minX - leading * 0.25
        let right = bounds.maxX + trailing * 0.25
        let radius = min(bounds.height / 2, (right - left) / 2)
        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: bounds.minY))
        path.addLine(to: CGPoint(x: right - radius, y: bounds.minY))
        path.addCurve(to: CGPoint(x: right, y: bounds.midY),
                      control1: CGPoint(x: right - radius * 0.447715, y: bounds.minY),
                      control2: CGPoint(x: right, y: bounds.midY - radius * 0.552285))
        path.addCurve(to: CGPoint(x: right - radius, y: bounds.maxY),
                      control1: CGPoint(x: right, y: bounds.midY + radius * 0.552285),
                      control2: CGPoint(x: right - radius * 0.447715, y: bounds.maxY))
        path.addLine(to: CGPoint(x: left + radius, y: bounds.maxY))
        path.addCurve(to: CGPoint(x: left, y: bounds.midY),
                      control1: CGPoint(x: left + radius * 0.447715, y: bounds.maxY),
                      control2: CGPoint(x: left, y: bounds.midY + radius * 0.552285))
        path.addCurve(to: CGPoint(x: left + radius, y: bounds.minY),
                      control1: CGPoint(x: left, y: bounds.midY - radius * 0.552285),
                      control2: CGPoint(x: left + radius * 0.447715, y: bounds.minY))
        path.closeSubpath()
        return path
    }
}

struct LiquidChoiceCapsule: View {
    let start: Date
    let distance: CGFloat
    let moving: Bool
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
            let progress = moving ? min(1, max(0, timeline.date.timeIntervalSince(start) / LiquidSelectionMotion.duration)) : 1
            let scale = LiquidSelectionMotion.sample(LiquidSelectionMotion.scales, at: progress)
            let stretch = LiquidSelectionMotion.sample(LiquidSelectionMotion.stretches, at: progress)
            let shape = LiquidCapsuleShape(stretch: stretch * min(16, abs(distance) * 0.10),
                                           direction: distance >= 0 ? 1 : -1)
            ZStack {
                if opaque {
                    shape.fill(scheme == .dark ? Color(white: 0.22) : Color(white: 0.96))
                } else {
                    shape.fill(.regularMaterial)
                    shape.fill(BrowseTheme.green.opacity(scheme == .dark ? 0.24 : 0.18))
                }
                shape.strokeBorderCompat(Color.primary.opacity(opaque ? 0.14 : 0.12))
            }
            .scaleEffect(x: scale, y: 1 / scale)
            // Timeline samples are already interpolated; inherited selection
            // animation must not add its own spring or extra settling cycles.
            .transaction { $0.animation = nil }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Shape {
    func strokeBorderCompat(_ color: Color) -> some View { stroke(color, lineWidth: 0.75) }
}

struct ChoiceBoundsPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Owned decoration only. No tab item hierarchy inspection, touch interception,
/// delegate replacement, or control of native tab-bar visibility.
final class LiquidTabIndicatorView: UIView {
    private let indicator = CAShapeLayer()
    private var currentFrame: CGRect?
    private var currentSelection: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        layer.addSublayer(indicator)
    }
    required init?(coder: NSCoder) { return nil }

    func update(selection: Int, count: Int, dark: Bool, enabled: Bool, bottomInset: CGFloat) {
        let count = max(1, count)
        let slot = bounds.width / CGFloat(count)
        let itemHeight = max(32, min(50, bounds.height - bottomInset))
        let target = CGRect(x: slot * (CGFloat(min(max(0, selection), count - 1)) + 0.5) - (slot - 12) / 2,
                            y: max(2, (itemHeight - 40) / 2), width: max(24, slot - 12), height: min(40, itemHeight - 4))
        let opaque = UIAccessibility.isReduceTransparencyEnabled
        let fill = dark ? UIColor(white: 0.30, alpha: opaque ? 1 : 0.70)
            : UIColor(white: 1, alpha: opaque ? 1 : 0.72)
        let destination = LiquidCapsuleShape(stretch: 0, direction: 1)
            .path(in: CGRect(origin: .zero, size: target.size)).cgPath
        let old = currentFrame
        let changed = currentSelection != nil && currentSelection != selection
        let oldPosition = indicator.presentation()?.position ?? indicator.position
        let oldPath = indicator.presentation()?.path ?? indicator.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.bounds = CGRect(origin: .zero, size: target.size)
        indicator.position = CGPoint(x: target.midX, y: target.midY)
        indicator.path = destination
        indicator.fillColor = fill.cgColor
        indicator.strokeColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.12).cgColor
        indicator.lineWidth = 0.75
        indicator.isHidden = !enabled
        CATransaction.commit()
        if UIAccessibility.isReduceMotionEnabled {
            indicator.removeAnimation(forKey: "selection.position")
            indicator.removeAnimation(forKey: "selection.shape")
        }
        // Layout callbacks during an in-flight animation must not cancel it.
        guard old != target || currentSelection != selection else { return }
        indicator.removeAllAnimations()
        if changed, enabled, let old = old {
            if UIAccessibility.isReduceMotionEnabled {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.35; fade.toValue = 1; fade.duration = 0.18
                indicator.add(fade, forKey: "selection.fade")
            } else {
                let position = CAKeyframeAnimation(keyPath: "position")
                let finalPosition = NSValue(cgPoint: CGPoint(x: target.midX, y: target.midY))
                position.values = [NSValue(cgPoint: oldPosition), finalPosition, finalPosition]
                position.keyTimes = [0, NSNumber(value: LiquidSelectionMotion.travelEnd), 1]
                position.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
                position.duration = LiquidSelectionMotion.duration
                indicator.add(position, forKey: "selection.position")
                let direction: CGFloat = target.midX >= old.midX ? 1 : -1
                let amplitude = min(16, abs(target.midX - oldPosition.x) * 0.10)
                let morph = CAKeyframeAnimation(keyPath: "path")
                morph.values = LiquidSelectionMotion.times.indices.map { index -> CGPath in
                    if index == 0 { return oldPath ?? destination }
                    let rect = CGRect(origin: .zero, size: target.size)
                    let scale = LiquidSelectionMotion.scales[index]
                    let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: 1 / scale,
                                                      tx: rect.midX * (1 - scale), ty: rect.midY * (1 - 1 / scale))
                    return LiquidCapsuleShape(stretch: amplitude * LiquidSelectionMotion.stretches[index], direction: direction)
                        .path(in: rect).applying(transform).cgPath
                }
                morph.keyTimes = LiquidSelectionMotion.times.map { NSNumber(value: $0) }
                morph.duration = LiquidSelectionMotion.duration
                morph.calculationMode = .linear
                morph.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .linear), count: LiquidSelectionMotion.times.count - 1)
                indicator.add(morph, forKey: "selection.shape")
            }
        }
        currentFrame = target
        currentSelection = selection
    }
}
