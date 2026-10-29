import Foundation

// MARK: - AutoCutArranger

/// Turns analysed footage (+ optional beat grid) into an edited clip list.
/// Pure logic: the async `AutoCutEngine` does the media analysis and calls this.
struct AutoCutArranger: Sendable {

    struct Output: Hashable, Sendable {
        var clips: [Clip]
        var shotLengths: [Double]
        var totalDuration: Double
    }

    /// Computes the list of shot lengths that sum to (at most) `target`.
    static func shotLengths(target: Double,
                            beats: [Double],
                            settings: AutoCutSettings,
                            scenes: [SceneRange]) -> [Double] {
        guard target > 0 else { return [] }
        let base = settings.pacing.baseShotLength
        let minShot = 0.4
        var lengths: [Double] = []

        let useBeats = settings.mode != .scene && beats.count >= 3
        if useBeats {
            let n = settings.pacing.beatsPerShot
            // Beat-to-beat interval; keep at least `minShot` per shot.
            var grid: [Double] = []
            var idx = 0
            while idx < beats.count {
                grid.append(beats[idx])
                idx += n
            }
            var previous = 0.0
            for t in grid where t > previous + 1e-6 {
                let length = t - previous
                if length < minShot { continue }
                lengths.append(length)
                previous = t
                if previous >= target { break }
            }
            // Extend with the average beat-group length if the music was shorter than the target.
            let avg = lengths.isEmpty ? base : lengths.reduce(0, +) / Double(lengths.count)
            while lengths.reduce(0, +) < target - 1e-6 { lengths.append(max(minShot, avg)) }

            if settings.mode == .hybrid {
                // Hybrid: alternate between beat-length shots and doubled shots for long calm scenes.
                let calm = scenes.filter { $0.score < 0.35 && $0.duration > base * 2 }.count
                if calm > 0 {
                    var merged: [Double] = []
                    var i = 0
                    while i < lengths.count {
                        if i % 4 == 3, i + 1 < lengths.count {
                            merged.append(lengths[i] + lengths[i + 1])
                            i += 2
                        } else {
                            merged.append(lengths[i])
                            i += 1
                        }
                    }
                    lengths = merged
                }
            }
        } else {
            // Scene mode: one shot per scene, clamped around the pacing base length.
            let sensitivityScale = 1.25 - 0.5 * settings.sensitivity
            let lower = max(minShot, base * 0.6 * sensitivityScale)
            let upper = base * 2.2 * sensitivityScale
            for scene in scenes {
                lengths.append(min(upper, max(lower, scene.duration)))
                if lengths.reduce(0, +) >= target { break }
            }
            let fallback = base * sensitivityScale
            while lengths.reduce(0, +) < target - 1e-6 { lengths.append(max(minShot, fallback)) }
        }

        // Trim the tail so the total equals the target exactly.
        var total = 0.0
        var result: [Double] = []
        for l in lengths {
            if total + l >= target - 1e-6 {
                let rest = target - total
                if rest >= minShot || result.isEmpty {
                    result.append(rest)
                } else if !result.isEmpty {
                    result[result.count - 1] += rest
                }
                total = target
                break
            }
            result.append(l)
            total += l
        }
        return result
    }

    /// Arranges the sources into clips following the computed shot lengths.
    static func arrange(sources: [AutoCutSource], beats: [Double], settings: AutoCutSettings) -> Output {
        guard !sources.isEmpty else { return Output(clips: [], shotLengths: [], totalDuration: 0) }

        // Flatten scenes in chronological (source) order.
        struct Candidate {
            var sourceIndex: Int
            var scene: SceneRange
            var cursor: Double
            var order: Int
        }
        var candidates: [Candidate] = []
        for (si, source) in sources.enumerated() {
            let fullDuration = source.template.sourceDuration
            let scenes = source.scenes.isEmpty
                ? [SceneRange(start: 0, end: source.template.mediaKind == .photo ? min(fullDuration, 4) : fullDuration, score: 0.5)]
                : source.scenes
            for scene in scenes where scene.duration >= 0.3 {
                candidates.append(Candidate(sourceIndex: si, scene: scene, cursor: scene.start, order: candidates.count))
            }
        }
        guard !candidates.isEmpty else { return Output(clips: [], shotLengths: [], totalDuration: 0) }

        // Never ask for more footage than exists (photos can be reused as long as needed).
        let available = candidates.reduce(0.0) { acc, c in
            sources[c.sourceIndex].template.mediaKind == .photo ? acc + max(c.scene.duration, 4) : acc + c.scene.duration
        }
        let target = min(settings.targetDuration, available)
        let allScenes = candidates.map(\.scene)
        let lengths = shotLengths(target: target, beats: beats, settings: settings, scenes: allScenes)

        // If there are more scenes than shots, keep the best ones but stay chronological.
        if candidates.count > lengths.count {
            let best = candidates.sorted { $0.scene.score > $1.scene.score }.prefix(lengths.count)
            candidates = best.sorted { $0.order < $1.order }
        }

        var clips: [Clip] = []
        var produced: [Double] = []
        var pointer = 0
        for length in lengths {
            var attempts = 0
            var placed = false
            while attempts < candidates.count {
                let ci = (pointer + attempts) % candidates.count
                var c = candidates[ci]
                let template = sources[c.sourceIndex].template
                let isPhoto = template.mediaKind == .photo
                let remaining = isPhoto ? length : c.scene.end - c.cursor
                if remaining >= min(length, 0.4) {
                    let take = min(length, remaining)
                    var clip = template
                    clip.id = UUID()
                    clip.speed = 1
                    if isPhoto {
                        clip.sourceStart = 0
                        clip.sourceEnd = min(template.sourceDuration, take)
                    } else {
                        // Centre the window inside a fresh scene, then walk forward.
                        var start = c.cursor
                        if c.cursor == c.scene.start && c.scene.duration > take * 1.6 && candidates.count >= lengths.count {
                            start = c.scene.start + (c.scene.duration - take) / 2
                        }
                        clip.sourceStart = start
                        clip.sourceEnd = min(template.sourceDuration, start + take)
                        c.cursor = clip.sourceEnd + take * 0.5
                    }
                    clip.transition = Transition()
                    if settings.applyStyleLook {
                        clip.filter = settings.style.filter
                        clip.effect = settings.style.effect
                    }
                    candidates[ci] = c
                    clips.append(clip)
                    produced.append(clip.timelineDuration)
                    pointer = ci + 1
                    placed = true
                    break
                }
                attempts += 1
            }
            if !placed { break }
        }

        // Style transitions on every n-th cut.
        if settings.applyStyleLook, clips.count > 1 {
            let every = max(1, settings.style.transitionEvery)
            for i in 0..<(clips.count - 1) where (i + 1) % every == 0 {
                let shortest = min(clips[i].timelineDuration, clips[i + 1].timelineDuration)
                clips[i].transition = Transition(type: settings.style.transition, duration: min(0.4, shortest / 3))
            }
        }

        let total = TimelineLayout(clips: clips).totalDuration
        return Output(clips: clips, shotLengths: produced, totalDuration: total)
    }
}
