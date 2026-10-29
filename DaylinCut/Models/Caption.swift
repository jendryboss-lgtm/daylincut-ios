import Foundation

// MARK: - TextStyle

enum TextStyle: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case plain, outline, background, neon, shadow

    var id: String { rawValue }
    var title: String {
        switch self {
        case .plain: return "Plain"
        case .outline: return "Outline"
        case .background: return "Label"
        case .neon: return "Neon"
        case .shadow: return "Shadow"
        }
    }
}

enum TextAnimation: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case none, fade, pop, slideUp, typewriter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .pop: return "Pop"
        case .slideUp: return "Rise"
        case .typewriter: return "Typewriter"
        }
    }
}

// MARK: - TextOverlay

/// A timed text layer drawn on top of the video.
struct TextOverlay: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var start: Double
    var duration: Double
    /// Normalised centre position (0...1, origin top-left).
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Font size as a fraction of the render height.
    var fontScale: Double = 0.05
    var colorHex: String = "#FFFFFF"
    var style: TextStyle = .outline
    var animation: TextAnimation = .fade
    var fontName: String = "AvenirNext-Heavy"

    var end: Double { start + duration }

    func isVisible(at time: Double) -> Bool { time >= start && time < end }
}

// MARK: - Caption

/// A caption generated from speech recognition (or typed by the user).
struct Caption: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
    func isVisible(at time: Double) -> Bool { time >= start && time < end }
}

/// Caption styling shared by every caption in a project.
struct CaptionStyle: Codable, Hashable, Sendable {
    var style: TextStyle = .background
    var colorHex: String = "#FFFFFF"
    var fontScale: Double = 0.042
    var centerY: Double = 0.78
    var uppercase: Bool = false
}

// MARK: - Caption grouping

enum CaptionGrouper {
    /// A recognised word with timing.
    struct Word: Hashable, Sendable {
        var text: String
        var start: Double
        var duration: Double
    }

    /// Groups recognised words into readable caption lines.
    /// - Parameters:
    ///   - maxWords: maximum words per line.
    ///   - maxDuration: maximum seconds a caption stays on screen.
    ///   - gap: a silence longer than this starts a new caption.
    static func group(_ words: [Word], maxWords: Int = 6, maxDuration: Double = 2.8, gap: Double = 0.7) -> [Caption] {
        var result: [Caption] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            result.append(Caption(text: text, start: first.start, end: last.start + max(last.duration, 0.2)))
            current.removeAll()
        }

        for word in words.sorted(by: { $0.start < $1.start }) {
            if let first = current.first, let last = current.last {
                let silence = word.start - (last.start + last.duration)
                let span = word.start + word.duration - first.start
                if current.count >= maxWords || silence > gap || span > maxDuration {
                    flush()
                }
            }
            current.append(word)
        }
        flush()

        // Make sure captions never overlap.
        for i in result.indices.dropLast() where result[i].end > result[i + 1].start {
            result[i].end = result[i + 1].start
        }
        return result
    }
}
