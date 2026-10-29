import Foundation

// MARK: - AutoCut configuration

enum AutoCutStyle: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case cinematic, travel, vlog, energetic, gaming, fitness, productAd, socialMedia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cinematic: return "Cinematic"
        case .travel: return "Travel"
        case .vlog: return "Vlog"
        case .energetic: return "Energetic"
        case .gaming: return "Gaming"
        case .fitness: return "Fitness"
        case .productAd: return "Product Ad"
        case .socialMedia: return "Social Media"
        }
    }

    var symbol: String {
        switch self {
        case .cinematic: return "film.fill"
        case .travel: return "airplane"
        case .vlog: return "person.crop.square.fill"
        case .energetic: return "bolt.fill"
        case .gaming: return "gamecontroller.fill"
        case .fitness: return "figure.run"
        case .productAd: return "bag.fill"
        case .socialMedia: return "heart.fill"
        }
    }

    var filter: FilterPreset {
        switch self {
        case .cinematic: return .cinematic
        case .travel: return .vivid
        case .vlog: return .warm
        case .energetic: return .dramatic
        case .gaming: return .cool
        case .fitness: return .chrome
        case .productAd: return .pastel
        case .socialMedia: return .vivid
        }
    }

    var transition: TransitionType {
        switch self {
        case .cinematic: return .fadeBlack
        case .travel: return .slideLeft
        case .vlog: return .dissolve
        case .energetic: return .fadeWhite
        case .gaming: return .glitch
        case .fitness: return .zoomIn
        case .productAd: return .circle
        case .socialMedia: return .wipeLeft
        }
    }

    var effect: VisualEffect {
        switch self {
        case .cinematic: return .kenBurns
        case .travel: return .kenBurns
        case .vlog: return .none
        case .energetic: return .shake
        case .gaming: return .rgbSplit
        case .fitness: return .flash
        case .productAd: return .bloom
        case .socialMedia: return .none
        }
    }

    var defaultPacing: AutoCutPacing {
        switch self {
        case .cinematic, .productAd: return .slow
        case .travel, .vlog, .socialMedia: return .medium
        case .energetic, .gaming, .fitness: return .fast
        }
    }

    /// Tempo used when AutoCut has to generate its own beat track.
    var bpm: Double {
        switch self {
        case .cinematic: return 80
        case .travel: return 105
        case .vlog: return 96
        case .energetic: return 128
        case .gaming: return 140
        case .fitness: return 132
        case .productAd: return 100
        case .socialMedia: return 118
        }
    }

    /// How often a style transition is used (every n-th cut). Others are hard cuts.
    var transitionEvery: Int {
        switch self {
        case .cinematic, .productAd: return 1
        case .travel, .vlog: return 2
        default: return 3
        }
    }
}

enum AutoCutMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case music, scene, hybrid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: return "Music beats"
        case .scene: return "Scene change"
        case .hybrid: return "Hybrid"
        }
    }
}

enum AutoCutPacing: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case slow, medium, fast
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Base shot length in seconds when no beat grid is available.
    var baseShotLength: Double {
        switch self {
        case .slow: return 2.4
        case .medium: return 1.4
        case .fast: return 0.75
        }
    }

    /// How many beats one shot lasts on a beat grid.
    var beatsPerShot: Int {
        switch self {
        case .slow: return 4
        case .medium: return 2
        case .fast: return 1
        }
    }
}

struct AutoCutSettings: Codable, Hashable, Sendable {
    static let presetDurations: [Double] = [10, 15, 30, 60]

    var style: AutoCutStyle = .socialMedia
    var mode: AutoCutMode = .hybrid
    /// Target length in seconds.
    var targetDuration: Double = 15
    var isCustomDuration: Bool = false
    var aspectRatio: AspectRatio = .portrait9x16
    /// 0 (few cuts) ... 1 (many cuts)
    var sensitivity: Double = 0.5
    var pacing: AutoCutPacing = .medium
    var applyStyleLook: Bool = true
}

// MARK: - Analysis inputs

/// A detected scene inside one source with an "interest" score (0...1).
struct SceneRange: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var score: Double
    var duration: Double { end - start }
}

/// One source clip handed to the arranger.
struct AutoCutSource: Hashable, Sendable {
    var template: Clip
    var scenes: [SceneRange]
}
