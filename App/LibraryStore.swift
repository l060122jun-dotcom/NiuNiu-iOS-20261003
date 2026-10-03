import Foundation
import Combine

struct SavedVideo: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var poster: String
    var detailURL: String = ""
    var source: String = ""
    var episode: String = ""
    var playbackURL: String = ""
    var position: Double = 0
    var updated: Date = Date()
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var favorites: [SavedVideo] = []
    @Published private(set) var history: [SavedVideo] = []
    @Published private(set) var searches: [String] = []
    private let defaults = UserDefaults.standard

    init() {
        favorites = load("favorites", fallback: [])
        history = load("history", fallback: [])
        searches = load("searches", fallback: [])
    }

    private func load<T: Decodable>(_ key: String, fallback: T) -> T {
        guard let data = defaults.data(forKey: "niuniu.\(key)"),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "niuniu.\(key)") }
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ video: SavedVideo) {
        if isFavorite(video.id) { favorites.removeAll { $0.id == video.id } }
        else { favorites.insert(video, at: 0) }
        save(favorites, key: "favorites")
    }

    func record(_ video: SavedVideo) {
        guard !defaults.bool(forKey: "niuniu.incognito") else { return }
        var entry = video
        entry.updated = Date()
        history.removeAll { $0.id == video.id }
        history.insert(entry, at: 0)
        history = Array(history.prefix(50))
        save(history, key: "history")
    }

    func removeHistory(_ id: String) {
        history.removeAll { $0.id == id }
        save(history, key: "history")
    }

    func clearHistory() { history = []; save(history, key: "history") }

    func rememberSearch(_ text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searches.removeAll { $0 == term }
        searches.insert(term, at: 0)
        searches = Array(searches.prefix(10))
        save(searches, key: "searches")
    }

    func clearSearches() { searches = []; save(searches, key: "searches") }
}
