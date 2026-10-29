import Foundation

// MARK: - AspectRatio

enum AspectRatio: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case portrait9x16 = "9:16"
    case landscape16x9 = "16:9"
    case square1x1 = "1:1"
    case portrait4x5 = "4:5"
    case portrait3x4 = "3:4"

    var id: String { rawValue }
    var title: String { rawValue }

    /// width / height
    var value: Double {
        switch self {
        case .portrait9x16: return 9.0 / 16.0
        case .landscape16x9: return 16.0 / 9.0
        case .square1x1: return 1
        case .portrait4x5: return 4.0 / 5.0
        case .portrait3x4: return 3.0 / 4.0
        }
    }

    /// Render size whose *short* side equals `shortSide`. Both sides are rounded
    /// to even numbers because H.264/HEVC encoders require it.
    func renderSize(shortSide: Int) -> (width: Int, height: Int) {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if value >= 1 {
            return (even(Double(shortSide) * value), even(Double(shortSide)))
        } else {
            return (even(Double(shortSide)), even(Double(shortSide) / value))
        }
    }
}

// MARK: - CanvasBackground

enum CanvasBackground: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case blur, black, white, gradient
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blur: return "Blur"
        case .black: return "Black"
        case .white: return "White"
        case .gradient: return "Gradient"
        }
    }
}

// MARK: - AudioItem

/// A music, sound effect or voice-over item on its own audio track.
struct AudioItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case music, voiceover, effect, extracted }

    var id: UUID = UUID()
    var kind: Kind = .music
    var title: String
    var fileName: String
    var sourceDuration: Double
    /// Timeline start.
    var start: Double = 0
    /// Offset inside the file.
    var sourceStart: Double = 0
    var duration: Double
    var volume: Float = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    /// Beat times (seconds from the start of the file) found by the onset detector.
    var beats: [Double] = []

    var end: Double { start + duration }
}

// MARK: - OverlayItem

/// Picture-in-picture layer (Overlay tab).
struct OverlayItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var mediaKind: MediaKind = .video
    var fileName: String
    var sourceDuration: Double
    var start: Double = 0
    var sourceStart: Double = 0
    var duration: Double
    var centerX: Double = 0.7
    var centerY: Double = 0.3
    /// Width as a fraction of the canvas width.
    var widthScale: Double = 0.4
    var opacity: Double = 1
    var removeBackground: Bool = false
    var volume: Float = 0
    var displayWidth: Double = 1080
    var displayHeight: Double = 1920

    var end: Double { start + duration }
}

// MARK: - Timeline

/// The full editable document for a project. Stored as JSON inside the SwiftData
/// `Project` model so new fields can be added without a migration.
struct Timeline: Codable, Hashable, Sendable {
    var clips: [Clip] = []
    var texts: [TextOverlay] = []
    var captions: [Caption] = []
    var captionStyle: CaptionStyle = CaptionStyle()
    var audio: [AudioItem] = []
    var overlays: [OverlayItem] = []
    var aspectRatio: AspectRatio = .portrait9x16
    var background: CanvasBackground = .blur
    var muteOriginalAudio: Bool = false
    /// Name shown in the editor's music pill ("Original" when no music is used).
    var musicTitle: String { audio.first(where: { $0.kind == .music })?.title ?? "Original" }

    var duration: Double { TimelineLayout(clips: clips).totalDuration }

    var isEmpty: Bool { clips.isEmpty }

    init(clips: [Clip] = []) { self.clips = clips }

    // Tolerant decoding: missing keys fall back to defaults so older projects still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        texts = try c.decodeIfPresent([TextOverlay].self, forKey: .texts) ?? []
        captions = try c.decodeIfPresent([Caption].self, forKey: .captions) ?? []
        captionStyle = try c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle) ?? CaptionStyle()
        audio = try c.decodeIfPresent([AudioItem].self, forKey: .audio) ?? []
        overlays = try c.decodeIfPresent([OverlayItem].self, forKey: .overlays) ?? []
        aspectRatio = try c.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio) ?? .portrait9x16
        background = try c.decodeIfPresent(CanvasBackground.self, forKey: .background) ?? .blur
        muteOriginalAudio = try c.decodeIfPresent(Bool.self, forKey: .muteOriginalAudio) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case clips, texts, captions, captionStyle, audio, overlays, aspectRatio, background, muteOriginalAudio
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clips, forKey: .clips)
        try c.encode(texts, forKey: .texts)
        try c.encode(captions, forKey: .captions)
        try c.encode(captionStyle, forKey: .captionStyle)
        try c.encode(audio, forKey: .audio)
        try c.encode(overlays, forKey: .overlays)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encode(background, forKey: .background)
        try c.encode(muteOriginalAudio, forKey: .muteOriginalAudio)
    }

    // MARK: Lookup helpers

    func clipIndex(at time: Double) -> Int? {
        let layout = TimelineLayout(clips: clips)
        return layout.clipIndex(at: time)
    }

    /// All file names referenced by this timeline (used for cleanup).
    var referencedFiles: Set<String> {
        var files = Set(clips.map(\.fileName))
        files.formUnion(audio.map(\.fileName))
        files.formUnion(overlays.map(\.fileName))
        return files
    }

    /// Keeps text, captions, audio and overlays inside the timeline after edits.
    mutating func clampToDuration() {
        let total = duration
        texts = texts.compactMap { t in
            guard t.start < total else { return nil }
            var t = t
            t.duration = min(t.duration, total - t.start)
            return t.duration > 0.05 ? t : nil
        }
        captions = captions.compactMap { c in
            guard c.start < total else { return nil }
            var c = c
            c.end = min(c.end, total)
            return c
        }
        audio = audio.compactMap { a in
            guard a.start < total else { return nil }
            var a = a
            a.duration = min(a.duration, total - a.start, a.sourceDuration - a.sourceStart)
            return a.duration > 0.05 ? a : nil
        }
        overlays = overlays.compactMap { o in
            guard o.start < total else { return nil }
            var o = o
            o.duration = min(o.duration, total - o.start, o.sourceDuration - o.sourceStart)
            return o.duration > 0.05 ? o : nil
        }
    }
}
