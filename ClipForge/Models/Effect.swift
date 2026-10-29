import Foundation

// MARK: - FilterPreset

/// Colour filters. Rendering lives in `FilterRenderer` (Core Image) so this type
/// stays Foundation-only and can be unit tested anywhere.
enum FilterPreset: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case none, vivid, warm, cool, cinematic, mono, noir, fade, chrome, instant, retro, sepia, dramatic, pastel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .vivid: return "Vivid"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .cinematic: return "Cinematic"
        case .mono: return "Mono"
        case .noir: return "Noir"
        case .fade: return "Fade"
        case .chrome: return "Chrome"
        case .instant: return "Instant"
        case .retro: return "Retro"
        case .sepia: return "Sepia"
        case .dramatic: return "Dramatic"
        case .pastel: return "Pastel"
        }
    }
}

// MARK: - TransitionType

enum TransitionType: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case none, dissolve, fadeBlack, fadeWhite, wipeLeft, wipeRight, slideLeft, slideUp, zoomIn, blur, circle, glitch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .dissolve: return "Dissolve"
        case .fadeBlack: return "Fade black"
        case .fadeWhite: return "Flash"
        case .wipeLeft: return "Wipe left"
        case .wipeRight: return "Wipe right"
        case .slideLeft: return "Slide"
        case .slideUp: return "Slide up"
        case .zoomIn: return "Zoom"
        case .blur: return "Blur"
        case .circle: return "Circle"
        case .glitch: return "Glitch"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "nosign"
        case .dissolve: return "circle.lefthalf.filled"
        case .fadeBlack: return "moon.fill"
        case .fadeWhite: return "sun.max.fill"
        case .wipeLeft: return "arrow.left.to.line"
        case .wipeRight: return "arrow.right.to.line"
        case .slideLeft: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .slideUp: return "arrow.up.square"
        case .zoomIn: return "plus.magnifyingglass"
        case .blur: return "aqi.medium"
        case .circle: return "circle.dashed"
        case .glitch: return "waveform.path"
        }
    }
}

// MARK: - Transition

struct Transition: Codable, Hashable, Sendable {
    var type: TransitionType = .none
    var duration: Double = 0.5

    /// The overlap this transition actually needs on the timeline.
    var effectiveDuration: Double { type == .none ? 0 : max(0, duration) }
}

// MARK: - VisualEffect

/// Animated per-clip effects (Effects tab).
enum VisualEffect: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case none, kenBurns, shake, rgbSplit, vignette, bloom, pixelate, comic, blurPulse, filmGrain, mirror, flash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .kenBurns: return "Zoom in"
        case .shake: return "Shake"
        case .rgbSplit: return "RGB split"
        case .vignette: return "Vignette"
        case .bloom: return "Glow"
        case .pixelate: return "Pixelate"
        case .comic: return "Comic"
        case .blurPulse: return "Blur pulse"
        case .filmGrain: return "Film grain"
        case .mirror: return "Mirror"
        case .flash: return "Flash beat"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "nosign"
        case .kenBurns: return "plus.magnifyingglass"
        case .shake: return "iphone.radiowaves.left.and.right"
        case .rgbSplit: return "square.3.layers.3d"
        case .vignette: return "circle.circle"
        case .bloom: return "sparkles"
        case .pixelate: return "square.grid.3x3.fill"
        case .comic: return "paintbrush.pointed.fill"
        case .blurPulse: return "drop.fill"
        case .filmGrain: return "film"
        case .mirror: return "rectangle.split.2x1"
        case .flash: return "bolt.fill"
        }
    }
}
