import Foundation

// MARK: - MediaKind

/// The kind of media a clip was created from. Photos are rendered into a short
/// still-video file at import time so the whole engine only deals with video tracks.
enum MediaKind: String, Codable, Hashable, Sendable {
    case video
    case photo
}

// MARK: - Clip

/// A single clip on the main video track.
///
/// All times are in seconds. `sourceStart`/`sourceEnd` are trim points inside the
/// media file; `speed` scales the trimmed range on the timeline.
struct Clip: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var mediaKind: MediaKind
    /// File name inside `MediaStore.directory`.
    var fileName: String
    /// Full duration of the underlying media file.
    var sourceDuration: Double
    var sourceStart: Double = 0
    var sourceEnd: Double
    var speed: Double = 1
    var volume: Float = 1
    var hasAudio: Bool = true
    /// Natural pixel size after applying the track's preferred transform.
    var displayWidth: Double = 1080
    var displayHeight: Double = 1920

    // MARK: Look
    var filter: FilterPreset = .none
    var filterIntensity: Double = 1
    var adjustments: Adjustments = Adjustments()
    var effect: VisualEffect = .none
    var autoEnhance: Bool = false
    var removeBackground: Bool = false
    var aiUltraHD: Bool = false

    // MARK: Transition into the next clip
    var transition: Transition = Transition()

    init(id: UUID = UUID(),
         mediaKind: MediaKind,
         fileName: String,
         sourceDuration: Double,
         sourceStart: Double = 0,
         sourceEnd: Double? = nil,
         speed: Double = 1,
         hasAudio: Bool = true,
         displayWidth: Double = 1080,
         displayHeight: Double = 1920) {
        self.id = id
        self.mediaKind = mediaKind
        self.fileName = fileName
        self.sourceDuration = sourceDuration
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd ?? sourceDuration
        self.speed = speed
        self.hasAudio = hasAudio
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }

    // MARK: Derived values

    /// Length of the trimmed range inside the source file.
    var trimmedDuration: Double { max(0, sourceEnd - sourceStart) }

    /// Length the clip occupies on the timeline after the speed change.
    var timelineDuration: Double {
        let s = max(Clip.minSpeed, min(Clip.maxSpeed, speed))
        return trimmedDuration / s
    }

    static let minSpeed: Double = 0.1
    static let maxSpeed: Double = 10
    static let minDuration: Double = 0.1

    /// Returns a copy trimmed to the given source range, clamped to the file.
    func trimmed(start: Double, end: Double) -> Clip {
        var copy = self
        let s = max(0, min(start, sourceDuration - Clip.minDuration))
        let e = min(sourceDuration, max(end, s + Clip.minDuration))
        copy.sourceStart = s
        copy.sourceEnd = e
        return copy
    }

    /// Splits the clip at a time measured from the clip's start on the timeline.
    /// Returns nil when the split point is too close to either edge.
    func split(atTimelineOffset offset: Double) -> (Clip, Clip)? {
        guard offset > Clip.minDuration, offset < timelineDuration - Clip.minDuration else { return nil }
        let sourceSplit = sourceStart + offset * speed
        var first = self
        first.sourceEnd = sourceSplit
        first.transition = Transition()
        var second = self
        second.id = UUID()
        second.sourceStart = sourceSplit
        return (first, second)
    }
}

// MARK: - Adjustments

/// Manual colour adjustments applied with `CIColorControls`, `CIExposureAdjust`
/// and `CITemperatureAndTint`.
struct Adjustments: Codable, Hashable, Sendable {
    var brightness: Double = 0      // -0.5 ... 0.5
    var contrast: Double = 1        // 0.5 ... 1.5
    var saturation: Double = 1      // 0 ... 2
    var exposure: Double = 0        // -2 ... 2
    var temperature: Double = 6500  // 3000 ... 10000
    var sharpness: Double = 0       // 0 ... 1
    var vignette: Double = 0        // 0 ... 2
    var zoom: Double = 1            // 1 ... 3 (crop zoom)

    var isIdentity: Bool { self == Adjustments() }
}
