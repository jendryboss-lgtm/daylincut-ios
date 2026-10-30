import Foundation

// MARK: - AutoCutPromptParser

/// Turns the picker's "What do you want to create?" prompt into AutoCut
/// settings: style keywords, a target length ("30s", "1 min", "short"),
/// an aspect ratio ("square", "landscape", "16:9") and pacing words.
enum AutoCutPromptParser {

    static func settings(for prompt: String, base: AutoCutSettings = AutoCutSettings()) -> AutoCutSettings {
        var s = base
        let text = prompt.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return s }
        let words = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })

        if let style = style(in: text, words: words) {
            s.style = style
            s.pacing = style.defaultPacing
        }
        if let pacing = pacing(in: text, words: words) { s.pacing = pacing }
        if let duration = duration(in: text, words: words) {
            s.targetDuration = duration
            s.isCustomDuration = !AutoCutSettings.presetDurations.contains(duration)
        }
        if let aspect = aspect(in: text, words: words) { s.aspectRatio = aspect }
        if words.contains("beat") || words.contains("beats") || words.contains("music") || words.contains("rhythm") {
            s.mode = .music
        } else if words.contains("scenes") || words.contains("story") || words.contains("documentary") {
            s.mode = .scene
        }
        return s
    }

    private static let styleKeywords: [(AutoCutStyle, [String])] = [
        (.travel, ["travel", "trip", "vacation", "holiday", "beach", "journey", "adventure", "road"]),
        (.vlog, ["vlog", "daily", "day", "life", "lifestyle", "diary", "weekend"]),
        (.cinematic, ["cinematic", "movie", "film", "epic", "dramatic", "trailer", "wedding"]),
        (.energetic, ["energetic", "hype", "party", "dance", "concert", "fast"]),
        (.gaming, ["gaming", "game", "gameplay", "roblox", "fortnite", "minecraft", "stream"]),
        (.fitness, ["fitness", "workout", "gym", "training", "run", "running", "sport", "sports"]),
        (.productAd, ["product", "ad", "advert", "promo", "promotion", "business", "shop", "sale", "brand"]),
        (.socialMedia, ["tiktok", "reel", "reels", "social", "instagram", "shorts", "viral"])
    ]

    static func style(in text: String, words: Set<String>) -> AutoCutStyle? {
        var best: (AutoCutStyle, Int)?
        for (style, keys) in styleKeywords {
            let hits = keys.filter { words.contains($0) }.count
            if hits > 0, hits > (best?.1 ?? 0) { best = (style, hits) }
        }
        return best?.0
    }

    static func pacing(in text: String, words: Set<String>) -> AutoCutPacing? {
        if words.contains("slow") || words.contains("calm") || words.contains("chill") || words.contains("relaxing") { return .slow }
        if words.contains("quick") || words.contains("fast") || words.contains("hype") || words.contains("energetic") { return .fast }
        return nil
    }

    /// "30s", "30 sec", "45 seconds", "1 min", "2 minutes", "short", "long".
    static func duration(in text: String, words: Set<String>) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let numberRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text),
           let value = Double(text[numberRange]) {
            let unit = text[unitRange]
            let seconds = unit.hasPrefix("m") ? value * 60 : value
            return min(180, max(5, seconds))
        }
        if words.contains("short") || words.contains("quick") { return 10 }
        if words.contains("long") { return 60 }
        return nil
    }

    static func aspect(in text: String, words: Set<String>) -> AspectRatio? {
        if text.contains("16:9") || words.contains("landscape") || words.contains("youtube") || words.contains("horizontal") || words.contains("widescreen") { return .landscape16x9 }
        if text.contains("1:1") || words.contains("square") { return .square1x1 }
        if text.contains("4:5") || words.contains("post") || words.contains("feed") { return .portrait4x5 }
        if text.contains("3:4") { return .portrait3x4 }
        if text.contains("9:16") || words.contains("vertical") || words.contains("portrait") || words.contains("tiktok") || words.contains("reel") || words.contains("story") { return .portrait9x16 }
        return nil
    }
}

// MARK: - PickForMe

/// "Pick for me": a reasonable set from recent media — short-to-medium videos
/// first (no screen-length recordings), topped up with photos, spread across
/// different moments rather than bursts from the same minute.
enum PickForMe {
    struct Candidate: Hashable, Sendable {
        var id: String
        var isVideo: Bool
        var duration: Double
        var date: Date
    }

    static func select(from candidates: [Candidate], maxVideos: Int = 6, minimumTotal: Int = 8, maximumTotal: Int = 12) -> [String] {
        let newestFirst = candidates.sorted { $0.date > $1.date }
        var picked: [Candidate] = []

        func farFromPicked(_ c: Candidate) -> Bool {
            picked.allSatisfy { abs($0.date.timeIntervalSince(c.date)) >= 60 }
        }

        for c in newestFirst where c.isVideo && c.duration >= 2 && c.duration <= 60 && farFromPicked(c) {
            guard picked.count < maxVideos else { break }
            picked.append(c)
        }
        for c in newestFirst where !c.isVideo && farFromPicked(c) {
            guard picked.count < minimumTotal else { break }
            picked.append(c)
        }
        // Still short (e.g. a burst-only library): relax the spacing rule.
        if picked.count < minimumTotal {
            for c in newestFirst where !picked.contains(c) && (!c.isVideo || (c.duration >= 1 && c.duration <= 90)) {
                guard picked.count < minimumTotal else { break }
                picked.append(c)
            }
        }
        return picked.prefix(maximumTotal).sorted { $0.date < $1.date }.map(\.id)
    }
}
