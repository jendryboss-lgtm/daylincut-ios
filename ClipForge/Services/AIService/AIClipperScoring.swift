import Foundation

// MARK: - AIClipper scoring

/// Finds the most interesting moments in long footage: Vision human detection +
/// frame-difference motion, scored per window. Also powers "Remove" (background
/// removal flag) since both use Vision.
enum AIClipper {

    struct Highlight: Hashable, Sendable, Identifiable {
        var id = UUID()
        var clipID: UUID
        var start: Double
        var end: Double
        var score: Double
    }

    /// Pure scoring/selection step (unit tested).
    static func select(samples: [(time: Double, people: Int, motion: Double)], duration: Double,
                       window: Double, count: Int) -> [(start: Double, end: Double, score: Double)] {
        guard duration > 0, window > 0, !samples.isEmpty else { return [] }
        var windows: [(start: Double, end: Double, score: Double)] = []
        var start = 0.0
        let step = window / 2
        while start < duration - 0.1 {
            let end = min(duration, start + window)
            let inside = samples.filter { $0.time >= start && $0.time < end }
            if !inside.isEmpty {
                let people = inside.map { min(3, Double($0.people)) / 3 }.reduce(0, +) / Double(inside.count)
                let motion = inside.map { min(1, $0.motion * 5) }.reduce(0, +) / Double(inside.count)
                windows.append((start, end, 0.55 * motion + 0.45 * people))
            }
            start += step
        }
        var chosen: [(start: Double, end: Double, score: Double)] = []
        for w in windows.sorted(by: { $0.score > $1.score }) where chosen.count < count {
            if !chosen.contains(where: { w.start < $0.end && $0.start < w.end }) { chosen.append(w) }
        }
        return chosen.sorted { $0.start < $1.start }
    }
}
