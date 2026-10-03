import Foundation

extension Dictionary where Key == String, Value == Any {
    func text(_ key: String) -> String {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return ""
    }
}

struct Episode: Identifiable, Hashable {
    var name: String
    var url: String
    var id: String { name + "|" + url }
    init(_ data: [String: Any]) { name = data.text("name"); url = data.text("url") }
}

struct VideoSource: Identifiable, Hashable {
    var id: String
    var episodes: [Episode]
    init(_ data: [String: Any]) {
        id = data.text("player_id")
        episodes = (data["episodes"] as? [[String: Any]] ?? []).map(Episode.init)
    }
}

struct Video: Identifiable, Hashable {
    var id: String
    var name: String
    var poster: String
    var remark: String
    var score: String
    var year: String
    var area: String
    var category: String
    var actor: String
    var director: String
    var introduction: String
    var sources: [VideoSource]

    init(_ data: [String: Any]) {
        id = data.text("vod_id")
        name = data.text("vod_name")
        poster = data.text("vod_pic")
        remark = data.text("vod_remarks")
        score = data.text("vod_douban_score")
        year = data.text("vod_year")
        area = data.text("vod_area")
        category = data.text("vod_class")
        actor = data.text("vod_actor")
        director = data.text("vod_director")
        let content = data.text("vod_content")
        introduction = (content.isEmpty ? data.text("vod_blurb") : content)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        sources = (data["sources"] as? [[String: Any]] ?? []).map(VideoSource.init).filter { !$0.episodes.isEmpty }
    }

    var saved: SavedVideo { SavedVideo(id: id, title: name, poster: poster) }
}

struct VideoCategory: Identifiable, Hashable {
    var id: String
    var name: String
    var filters: [String: String]
    init(_ data: [String: Any]) {
        id = data.text("type_id")
        name = data.text("type_name")
        filters = (data["type_extend"] as? [String: String]) ?? [:]
    }
}

struct Recommendation: Identifiable {
    var id: String
    var title: String
    var videos: [Video]
}

struct ResolvedVideo {
    var url: URL
    var headers: [String: String] = [:]
}
