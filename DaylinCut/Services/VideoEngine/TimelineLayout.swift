import Foundation

// MARK: - TimelineLayout

/// Pure timeline maths shared by the composition builder, the timeline UI and the tests.
///
/// Clips are laid out back to back. A transition of length `t` between clip `i`
/// and `i + 1` makes them overlap by `t`, so clip `i + 1` starts `t` seconds
/// before clip `i` ends. Clips alternate between track 0 and track 1 so the
/// overlapping frames come from different composition tracks.
struct TimelineLayout: Hashable, Sendable {

    struct Placement: Hashable, Sendable {
        var index: Int
        var start: Double
        var duration: Double
        /// Overlap with the previous clip.
        var transitionIn: Double
        /// Overlap with the next clip.
        var transitionOut: Double
        var track: Int
        var end: Double { start + duration }
    }

    struct Segment: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case single(clip: Int)
            case transition(from: Int, to: Int, type: TransitionType)
        }
        var kind: Kind
        var start: Double
        var end: Double
        var duration: Double { end - start }
    }

    private(set) var placements: [Placement] = []
    private(set) var segments: [Segment] = []
    private(set) var totalDuration: Double = 0

    init(clips: [Clip]) {
        let durations = clips.map { $0.timelineDuration }
        // Clamp every transition so it never takes more than half of either neighbour.
        var overlaps: [Double] = Array(repeating: 0, count: max(0, clips.count - 1))
        for i in overlaps.indices {
            let wanted = clips[i].transition.effectiveDuration
            let limit = min(durations[i], durations[i + 1]) / 2
            overlaps[i] = max(0, min(wanted, limit))
        }

        var cursor = 0.0
        for (i, d) in durations.enumerated() {
            let tin = i > 0 ? overlaps[i - 1] : 0
            let tout = i < overlaps.count ? overlaps[i] : 0
            if i > 0 { cursor -= tin }
            placements.append(Placement(index: i, start: cursor, duration: d, transitionIn: tin, transitionOut: tout, track: i % 2))
            cursor += d
        }
        totalDuration = max(0, cursor)

        // Build contiguous, non-overlapping render segments.
        for p in placements {
            let soloStart = p.start + p.transitionIn
            let soloEnd = p.end - p.transitionOut
            if soloEnd - soloStart > 1e-6 {
                segments.append(Segment(kind: .single(clip: p.index), start: soloStart, end: soloEnd))
            }
            if p.transitionOut > 1e-6, p.index + 1 < clips.count {
                segments.append(Segment(kind: .transition(from: p.index, to: p.index + 1, type: clips[p.index].transition.type),
                                        start: soloEnd, end: p.end))
            }
        }
    }

    /// The clip that is (mostly) visible at `time`.
    func clipIndex(at time: Double) -> Int? {
        guard !placements.isEmpty else { return nil }
        if time <= 0 { return 0 }
        if time >= totalDuration { return placements.count - 1 }
        for seg in segments where time >= seg.start && time < seg.end {
            switch seg.kind {
            case .single(let clip): return clip
            case .transition(let from, let to, _):
                return time < (seg.start + seg.end) / 2 ? from : to
            }
        }
        return placements.last?.index
    }

    /// Start time of every clip, convenient for the timeline UI.
    var clipStarts: [Double] { placements.map(\.start) }

    /// Converts a timeline time to an offset within clip `index` (timeline seconds).
    func localOffset(of time: Double, inClip index: Int) -> Double {
        guard placements.indices.contains(index) else { return 0 }
        return time - placements[index].start
    }

    /// Validates that segments are contiguous and cover the whole duration.
    var isContiguous: Bool {
        guard let first = segments.first, let last = segments.last else { return placements.isEmpty }
        if abs(first.start) > 1e-6 || abs(last.end - totalDuration) > 1e-6 { return false }
        for (a, b) in zip(segments, segments.dropFirst()) where abs(a.end - b.start) > 1e-6 { return false }
        return true
    }
}
