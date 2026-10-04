import SwiftUI
import UIKit

/// iOS 16 compatibility glass. Strength controls the opaque surface overlay,
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

/// Only this decorative background receives opacity; labels remain fully legible.
struct GlassSurface<SurfaceShape: Shape>: View {
    let shape: SurfaceShape
    var material: Material = .ultraThinMaterial
    var dark: Bool? = nil
    @AppStorage(GlassAppearance.storageKey) private var opacity = GlassAppearance.defaultOpacity
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let strength = reduceTransparency ? 1 : GlassAppearance.normalized(opacity)
        let solid = Color(uiColor: GlassAppearance.solidColor(dark: dark ?? (scheme == .dark)))
        ZStack {
            if strength < 1 { shape.fill(material) }
            shape.fill(solid.opacity(strength))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { GlassAppearance.migrate() }
        .onChange(of: opacity) { _ in GlassAppearance.migrate() }
    }
}

extension View {
    func glassBackground<S: Shape>(in shape: S, material: Material = .ultraThinMaterial, dark: Bool? = nil) -> some View {
        background { GlassSurface(shape: shape, material: material, dark: dark) }
    }
}
