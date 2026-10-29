import Foundation

/// A template is a complete AutoCut recipe plus a title card; applying one to the
/// user's footage runs the real AutoCut engine with these settings.
struct TemplatePreset: Identifiable, Hashable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case trending = "Trending", travel = "Travel", vlog = "Vlog", business = "Business", fitness = "Fitness", gaming = "Gaming"
        var id: String { rawValue }
    }

    var id: String
    var title: String
    var subtitle: String
    var category: Category
    var style: AutoCutStyle
    var duration: Double
    var aspect: AspectRatio
    var pacing: AutoCutPacing
    var titleText: String
    var textStyle: TextStyle
    var textAnimation: TextAnimation
    var colors: [String]
    var symbol: String
    var isPro: Bool
    var uses: Int

    var settings: AutoCutSettings {
        var s = AutoCutSettings()
        s.style = style
        s.mode = .hybrid
        s.targetDuration = duration
        s.aspectRatio = aspect
        s.pacing = pacing
        s.sensitivity = 0.55
        s.applyStyleLook = true
        return s
    }

    /// Applies the title card on top of an AutoCut timeline.
    func decorate(_ timeline: Timeline) -> Timeline {
        var t = timeline
        guard !titleText.isEmpty else { return t }
        t.texts.append(TextOverlay(text: titleText, start: 0.15, duration: min(2.6, max(1, t.duration - 0.2)),
                                   centerX: 0.5, centerY: 0.42, fontScale: 0.07, colorHex: "#FFFFFF",
                                   style: textStyle, animation: textAnimation))
        return t
    }

    static let all: [TemplatePreset] = [
        .init(id: "summer-recap", title: "Summer Recap", subtitle: "Bright beat-synced memories", category: .trending, style: .socialMedia,
              duration: 15, aspect: .portrait9x16, pacing: .medium, titleText: "SUMMER '26", textStyle: .neon, textAnimation: .pop,
              colors: ["#F7971E", "#FFD200"], symbol: "sun.max.fill", isPro: false, uses: 182_000),
        .init(id: "cinema-trailer", title: "Cinema Trailer", subtitle: "Letterbox mood, slow fades", category: .trending, style: .cinematic,
              duration: 30, aspect: .landscape16x9, pacing: .slow, titleText: "COMING SOON", textStyle: .shadow, textAnimation: .fade,
              colors: ["#0F2027", "#2C5364"], symbol: "film.fill", isPro: true, uses: 96_400),
        .init(id: "wanderlust", title: "Wanderlust", subtitle: "Slide transitions for trips", category: .travel, style: .travel,
              duration: 30, aspect: .portrait9x16, pacing: .medium, titleText: "Wanderlust", textStyle: .outline, textAnimation: .slideUp,
              colors: ["#1D976C", "#93F9B9"], symbol: "airplane", isPro: false, uses: 74_100),
        .init(id: "city-hop", title: "City Hop", subtitle: "Fast cuts on every beat", category: .travel, style: .energetic,
              duration: 15, aspect: .portrait9x16, pacing: .fast, titleText: "CITY HOP", textStyle: .background, textAnimation: .pop,
              colors: ["#4776E6", "#8E54E9"], symbol: "building.2.fill", isPro: false, uses: 51_900),
        .init(id: "day-in-life", title: "Day in My Life", subtitle: "Warm vlog, soft dissolves", category: .vlog, style: .vlog,
              duration: 60, aspect: .portrait9x16, pacing: .medium, titleText: "a day in my life", textStyle: .plain, textAnimation: .typewriter,
              colors: ["#ED4264", "#FFEDBC"], symbol: "person.crop.square.fill", isPro: false, uses: 133_000),
        .init(id: "product-drop", title: "Product Drop", subtitle: "Clean reveal for your brand", category: .business, style: .productAd,
              duration: 15, aspect: .square1x1, pacing: .slow, titleText: "NEW DROP", textStyle: .background, textAnimation: .pop,
              colors: ["#232526", "#414345"], symbol: "bag.fill", isPro: true, uses: 38_700),
        .init(id: "promo-45", title: "Promo 4:5", subtitle: "Feed-ready promo cut", category: .business, style: .socialMedia,
              duration: 15, aspect: .portrait4x5, pacing: .medium, titleText: "LIMITED OFFER", textStyle: .outline, textAnimation: .slideUp,
              colors: ["#C33764", "#1D2671"], symbol: "megaphone.fill", isPro: false, uses: 22_300),
        .init(id: "beast-mode", title: "Beast Mode", subtitle: "Flash-beat workout edit", category: .fitness, style: .fitness,
              duration: 30, aspect: .portrait9x16, pacing: .fast, titleText: "BEAST MODE", textStyle: .outline, textAnimation: .pop,
              colors: ["#F12711", "#F5AF19"], symbol: "figure.strengthtraining.traditional", isPro: false, uses: 64_800),
        .init(id: "clutch", title: "Clutch Moments", subtitle: "Glitch cuts for gameplay", category: .gaming, style: .gaming,
              duration: 30, aspect: .landscape16x9, pacing: .fast, titleText: "CLUTCH", textStyle: .neon, textAnimation: .pop,
              colors: ["#283C86", "#45A247"], symbol: "gamecontroller.fill", isPro: false, uses: 88_200),
        .init(id: "montage-60", title: "Epic Montage", subtitle: "One-minute highlight reel", category: .gaming, style: .energetic,
              duration: 60, aspect: .portrait9x16, pacing: .fast, titleText: "", textStyle: .plain, textAnimation: .none,
              colors: ["#FF512F", "#DD2476"], symbol: "bolt.fill", isPro: true, uses: 41_500)
    ]
}
