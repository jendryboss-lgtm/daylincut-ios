import Foundation

// Pure AI value types and story planning (Foundation-only, unit tested).

struct StoryScene: Hashable, Sendable, Identifiable {
    var id = UUID()
    var title: String
    var narration: String
    var palette: [String]
    var duration: Double
}

enum AvatarLook: String, CaseIterable, Identifiable, Hashable, Sendable {
    case nova, blaze, mint, mono
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var skinHex: String {
        switch self {
        case .nova: return "#F2C7A5"
        case .blaze: return "#C68863"
        case .mint: return "#8A5A44"
        case .mono: return "#E0E0E0"
        }
    }
    var backgroundHex: [String] {
        switch self {
        case .nova: return ["#3A1C71", "#D76D77"]
        case .blaze: return ["#F12711", "#F5AF19"]
        case .mint: return ["#11998E", "#38EF7D"]
        case .mono: return ["#232526", "#414345"]
        }
    }
}

enum PhotoOperation: String, CaseIterable, Identifiable, Hashable, Sendable {
    case autoEnhance, retouch, removeBackground, cartoon, cinematic, vivid, mono, sketch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .autoEnhance: return "Auto enhance"
        case .retouch: return "Retouch"
        case .removeBackground: return "Remove BG"
        case .cartoon: return "Cartoon"
        case .cinematic: return "Cinematic"
        case .vivid: return "Vivid"
        case .mono: return "B&W"
        case .sketch: return "Sketch"
        }
    }
    var symbol: String {
        switch self {
        case .autoEnhance: return "wand.and.stars"
        case .retouch: return "face.smiling"
        case .removeBackground: return "person.crop.rectangle.badge.plus"
        case .cartoon: return "paintpalette.fill"
        case .cinematic: return "film"
        case .vivid: return "sun.max.fill"
        case .mono: return "circle.lefthalf.filled"
        case .sketch: return "pencil.and.scribble"
        }
    }
    var requiresPro: Bool { self == .cartoon || self == .sketch }
}

// MARK: - Story planning (pure, testable)

enum StoryPlanner {
    static let palettes: [[String]] = [
        ["#0F2027", "#2C5364"], ["#FF512F", "#DD2476"], ["#1D976C", "#93F9B9"],
        ["#4776E6", "#8E54E9"], ["#F7971E", "#FFD200"], ["#283C86", "#45A247"],
        ["#C33764", "#1D2671"], ["#ED4264", "#FFEDBC"]
    ]

    /// Splits a prompt into narrated scenes. Sentences become scenes; a single short
    /// prompt is expanded into a classic hook → story → payoff arc.
    static func scenes(for prompt: String, sceneCount: Int = 4) -> [StoryScene] {
        let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = cleaned.isEmpty ? "a day to remember" : cleaned
        var sentences: [String] = []
        // Portable sentence split: a terminator followed by whitespace (or the end) ends a sentence.
        var current = ""
        let chars = Array(topic)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let isTerminator = ".!?".contains(ch)
            let nextIsBreak = i + 1 == chars.count || chars[i + 1].isWhitespace
            if isTerminator && nextIsBreak {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        if sentences.count < 2 {
            let t = topic.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            sentences = [
                "Here is the story of \(t).",
                "It started with a simple idea.",
                "Step by step, \(t) came to life.",
                "And that is how \(t) changed everything."
            ]
        }
        let count = max(1, min(8, max(sceneCount, sentences.count)))
        let used = Array(sentences.prefix(count))
        return used.enumerated().map { i, sentence in
            let words = sentence.split(separator: " ")
            let title = words.prefix(4).joined(separator: " ")
            let duration = min(6, max(2.5, Double(words.count) * 0.42 + 0.8))
            return StoryScene(title: title, narration: sentence, palette: palettes[i % palettes.count], duration: duration)
        }
    }

    /// Amplitude envelope (0...1) per video frame, used for avatar lip-sync.
    static func envelope(samples: [Float], sampleRate: Double, fps: Int) -> [Double] {
        guard sampleRate > 0, fps > 0, !samples.isEmpty else { return [] }
        let hop = max(1, Int(sampleRate / Double(fps)))
        var values: [Double] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + hop)
            var sum: Double = 0
            for j in i..<end { sum += Double(samples[j] * samples[j]) }
            values.append((sum / Double(end - i)).squareRoot())
            i = end
        }
        let peak = max(values.max() ?? 0, 1e-4)
        return values.map { min(1, $0 / peak * 1.3) }
    }
}
