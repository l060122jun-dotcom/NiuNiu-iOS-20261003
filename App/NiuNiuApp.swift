import SwiftUI
import UIKit

@MainActor
final class NiuNiuApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PlaybackController.releasePlaybackResource = { url in
            SpecialSourceResolver.shared.releasePlayback(url: url)
        }
        return true
    }
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if !DownloadsStore.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler) {
            completionHandler()
        }
    }
}

@main
@MainActor
struct NiuNiuApp: App {
    @UIApplicationDelegateAdaptor(NiuNiuApplicationDelegate.self) private var applicationDelegate
    @StateObject private var library = LibraryStore()
    @StateObject private var catalog = BrowseCatalog()
    @StateObject private var account = AccountStore.shared
    @AppStorage("niuniu.appearance") private var appearance = "system"
    @AppStorage(GlassAppearance.storageKey) private var glassOpacity = GlassAppearance.defaultOpacity

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(library)
                .environmentObject(catalog)
                .environmentObject(account)
                .tint(BrowseTheme.accent)
                .background(BrowseTheme.background)
                .preferredColorScheme(colorScheme)
                .environment(\.liuyunGlassConfiguration, GlassConfiguration(opacity: GlassAppearance.normalized(glassOpacity)))
                .onAppear { GlassAppearance.migrate() }
                .onChange(of: glassOpacity) { _ in GlassAppearance.migrate() }
                .task { await catalog.load() }
        }
    }
}
