import Foundation

// MARK: - Timeline editing operations

/// Pure, unit-tested editing operations used by the editor.
extension Timeline {

    /// Splits the clip under `time` into two. Returns the id of the new right half.
    @discardableResult
    mutating func split(at time: Double) -> UUID? {
        let layout = TimelineLayout(clips: clips)
        guard let index = layout.clipIndex(at: time) else { return nil }
        let offset = time - layout.placements[index].start
        guard let (a, b) = clips[index].split(atTimelineOffset: offset) else { return nil }
        var right = b
        right.transition = clips[index].transition
        clips[index] = a
        clips.insert(right, at: index + 1)
        return right.id
    }

    mutating func deleteClip(id: UUID) {
        clips.removeAll { $0.id == id }
        clampToDuration()
    }

    @discardableResult
    mutating func duplicateClip(id: UUID) -> UUID? {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = clips[i]
        copy.id = UUID()
        clips.insert(copy, at: i + 1)
        return copy.id
    }

    mutating func moveClip(id: UUID, by delta: Int) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(clips.count - 1, i + delta))
        guard i != j else { return }
        let clip = clips.remove(at: i)
        clips.insert(clip, at: j)
    }

    mutating func moveClip(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { clips[$0] }
        var remaining = clips.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        let target = max(0, min(remaining.count, destination - before))
        remaining.insert(contentsOf: moving, at: target)
        clips = remaining
    }

    /// Removes `[start, end)` from the video and closes the gap; everything after
    /// shifts left. Text, captions, audio and overlays inside the range are removed
    /// or trimmed. Used by transcript editing ("cut this sentence").
    mutating func removeRange(start rawStart: Double, end rawEnd: Double) {
        let total = duration
        let start = max(0, min(rawStart, total))
        let end = max(start, min(rawEnd, total))
        guard end - start > 0.05 else { return }
        // Transitions make overlapping ranges ambiguous; hard-cut the boundaries.
        if end < total - 0.05 { split(at: end) }
        if start > 0.05 { split(at: start) }
        let layout = TimelineLayout(clips: clips)
        let removeIDs = Set(layout.placements.filter { p in
            p.start >= start - 0.06 && p.end <= end + 0.06
        }.map { clips[$0.index].id })
        guard !removeIDs.isEmpty, removeIDs.count < clips.count else { return }
        clips.removeAll { removeIDs.contains($0.id) }
        let removed = total - duration

        func shift(_ s: Double) -> Double? {
            if s >= end - 1e-6 { return s - removed }
            if s < start { return s }
            return nil
        }
        texts = texts.compactMap { t in
            if let s = shift(t.start) { var t = t; t.start = s; return t }
            if t.end > end { var t = t; t.duration = t.end - end; t.start = start; return t }
            return nil
        }
        captions = captions.compactMap { c in
            if c.end <= start + 1e-6 { return c }
            guard c.start >= end - 1e-6 else { return nil }
            var c = c
            c.start -= removed
            c.end -= removed
            return c
        }
        overlays = overlays.compactMap { o in
            guard let s = shift(o.start) else { return nil }
            var o = o; o.start = s; return o
        }
        audio = audio.map { a in
            guard a.start >= end - 1e-6 else { return a }
            var a = a; a.start -= removed; return a
        }
        clampToDuration()
    }

    /// Applies `edit` to the clip with `id`.
    mutating func updateClip(id: UUID, _ edit: (inout Clip) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        edit(&clips[i])
    }

    /// Speed change keeping speed within limits.
    mutating func setSpeed(_ speed: Double, clipID: UUID) {
        updateClip(id: clipID) { $0.speed = max(Clip.minSpeed, min(Clip.maxSpeed, speed)) }
        clampToDuration()
    }

    /// Inserts clips after the clip under `time` (or at the end).
    mutating func insert(_ newClips: [Clip], at time: Double?) {
        guard let time, let i = TimelineLayout(clips: clips).clipIndex(at: time) else {
            clips.append(contentsOf: newClips)
            return
        }
        clips.insert(contentsOf: newClips, at: i + 1)
    }
}

// MARK: - Ending card

extension Timeline {
    static let endingTitle = "Thanks for watching"
    static let endingDuration: Double = 2.5

    /// Appends an end-card clip: the previous clip fades to black into it and
    /// a title is laid over the card.
    mutating func appendEnding(_ card: Clip, title: String = Timeline.endingTitle) {
        var card = card
        card.transition = Transition()
        if !clips.isEmpty {
            clips[clips.count - 1].transition = Transition(type: .fadeBlack, duration: 0.5)
        }
        clips.append(card)
        let layout = TimelineLayout(clips: clips)
        let cardStart = layout.placements.last?.start ?? 0
        texts.append(TextOverlay(text: title, start: cardStart, duration: layout.placements.last?.duration ?? card.timelineDuration,
                                 centerY: 0.5, fontScale: 0.06, style: .neon, animation: .pop))
        clampToDuration()
    }
}
