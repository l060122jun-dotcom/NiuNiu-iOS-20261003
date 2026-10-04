import SwiftUI
import UIKit

/// Strength controls the opaque surface backing,
/// not the system blur radius or the opacity of foreground content.
/// Overlay alpha means 0 = no solid cover, 1 = solid; the supported user range
/// starts at 0.15 to retain contrast. Material itself keeps its system behavior.
enum GlassAppearance {
    static let storageKey = "niuniu.glassOpacity"
    static let defaultOpacity = 0.40
    static let opacityRange = 0.15...1.0

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        return min(opacityRange.upperBound, max(opacityRange.lowerBound, value))
    }

    static func solidColor(dark: Bool) -> UIColor {
        UIColor(white: dark ? 0.12 : 0.98, alpha: 1)
    }

    /// Repair legacy/out-of-range/non-finite values without writing every frame.
    static func migrate(in defaults: UserDefaults = .standard) {
        guard let stored = defaults.object(forKey: storageKey) else { return }
        guard let number = stored as? NSNumber else {
            defaults.set(defaultOpacity, forKey: storageKey)
            return
        }
        let value = number.doubleValue
        let repaired = normalized(value)
        if !value.isFinite || value != repaired { defaults.set(repaired, forKey: storageKey) }
    }
}

/// Scene-owned configuration. Surfaces never read defaults or cache global state.
struct GlassConfiguration: Equatable {
    var opacity: Double = GlassAppearance.defaultOpacity
    var styleTint: Color? = nil
    var interactivity = false

    var normalizedOpacity: Double { GlassAppearance.normalized(opacity) }
}

private struct LiuyunGlassConfigurationKey: EnvironmentKey {
    static let defaultValue = GlassConfiguration()
}

extension EnvironmentValues {
    var liuyunGlassConfiguration: GlassConfiguration {
        get { self[LiuyunGlassConfigurationKey.self] }
        set { self[LiuyunGlassConfigurationKey.self] = newValue }
    }
}

/// Only this decorative background receives opacity; labels remain fully legible.
struct GlassSurface<SurfaceShape: Shape>: View {
    let shape: SurfaceShape
    var material: Material = .ultraThinMaterial
    var dark: Bool? = nil
    @Environment(\.liuyunGlassConfiguration) private var configuration
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let strength = reduceTransparency ? 1 : configuration.normalizedOpacity
        let solid = Color(uiColor: GlassAppearance.solidColor(dark: dark ?? (scheme == .dark)))
        ZStack {
            if strength < 1 {
                if #available(iOS 26.0, *) {
                    shape.fill(Color.clear)
                        .glassEffect(styleForShape(solid: solid), in: shape)
                } else {
                    // Material exists on iOS 16 too; retain the current deployment target.
                    shape.fill(material)
                    if let tint = configuration.styleTint { shape.fill(tint.opacity(0.12)) }
                }
            }
            // Glass.tint alpha is not absolute transparency. A separate shape cover
            // makes 15...100% visibly adjustable without fading labels or icons.
            shape.fill(solid.opacity(strength))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @available(iOS 26.0, *)
    private func styleForShape(solid: Color) -> Glass {
        .regular.tint(configuration.styleTint ?? solid.opacity(0.12))
            .interactive(configuration.interactivity)
    }
}

extension View {
    func liuyunGlass<S: Shape>(in shape: S, material: Material = .ultraThinMaterial, dark: Bool? = nil) -> some View {
        background { GlassSurface(shape: shape, material: material, dark: dark) }
    }

    /// Compatibility alias used by search, controls and selection indicators.
    func glassBackground<S: Shape>(in shape: S, material: Material = .ultraThinMaterial, dark: Bool? = nil) -> some View {
        liuyunGlass(in: shape, material: material, dark: dark)
    }
}
