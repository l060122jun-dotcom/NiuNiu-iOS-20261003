import SwiftUI

// iOS 16 material, not the iOS 26 glassEffect API. Keeping this layer in a
// safeAreaInset reserves its initial height, while the scroll's edge extends
// beneath it after scrolling (do not clip the scroll to its reduced bounds).
struct FloatingBrowseHeader: ViewModifier {
    func body(content: Content) -> some View {
        // Each control supplies its own material. Leave the gaps transparent;
        // never blur the header as a full-width rectangular block.
        content.background(Color.clear)
    }
}

/// A shared surface for both matched-geometry endpoints; no full-width header blur.
struct GlassSearchPill: View {
    var body: some View { GlassSurface(shape: Capsule(), material: .thinMaterial) }
}

private struct SearchMorphNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct BrowseContentActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var browseContentActive: Bool {
        get { self[BrowseContentActiveKey.self] }
        set { self[BrowseContentActiveKey.self] = newValue }
    }
    var searchMorphNamespace: Namespace.ID? {
        get { self[SearchMorphNamespaceKey.self] }
        set { self[SearchMorphNamespaceKey.self] = newValue }
    }
}

@MainActor
final class SearchMorphPresentation: ObservableObject {
    @Published private(set) var expanded = false
    @Published private(set) var hasOpened = false
    @Published var ready = false

    func open(reduceMotion: Bool) {
        guard !expanded, !opening else { return }
        // Mount once without animation, then transfer the geometry source.
        opening = true
        hasOpened = true
        ready = false
        Task { @MainActor in
            // The destination must participate in a layout before its geometry
            // source changes; otherwise first use can be an insertion-only fade.
            await Task.yield()
            guard opening else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.44, dampingFraction: 0.88)) {
                expanded = true
            }
            opening = false
        }
    }

    func close(reduceMotion: Bool) {
        opening = false
        ready = false
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.44, dampingFraction: 0.88)) {
            expanded = false
        }
    }
    private var opening = false
}

/// Search stays in the original NavigationStack: a result may push DetailView
/// normally, and popping it exposes the exact same search store/scroll instance.
/// The underlying Home/Rank subtree is never replaced or given a new .id.
@MainActor
struct SearchMorphHost: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace
    @StateObject private var presentation = SearchMorphPresentation()

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
                .environment(\.browseContentActive, !presentation.expanded)
                // Blur belongs to the transition backdrop, never the active
                // search content or its full-page background.
                .blur(radius: presentation.expanded && !presentation.ready && !reduceMotion ? 9 : 0)
                .allowsHitTesting(!presentation.expanded)
                .accessibilityHidden(presentation.expanded)
            Color.black.opacity(presentation.expanded && !presentation.ready ? 0.12 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            if presentation.hasOpened {
                SearchView(morphPresented: presentation.expanded,
                           morphReady: presentation.ready,
                           onCancel: { presentation.close(reduceMotion: reduceMotion) })
                    .opacity(presentation.expanded ? 1 : 0)
                    .allowsHitTesting(presentation.ready && presentation.expanded)
                    .accessibilityHidden(!presentation.expanded)
                    .zIndex(1)
            }
        }
        .environmentObject(presentation)
        .environment(\.searchMorphNamespace, namespace)
        // A single inline chrome is owned by the overlay, never a sheet or a
        // second navigation stack. Detail destinations retain their own toolbar.
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .preference(key: MainTabSearchExpandedKey.self, value: presentation.expanded)
        .task(id: presentation.expanded) {
            guard presentation.expanded else { return }
            do { try await Task.sleep(nanoseconds: reduceMotion ? 150_000_000 : 480_000_000) }
            catch { return }
            guard !Task.isCancelled, presentation.expanded else { return }
            presentation.ready = true
        }
    }
}
