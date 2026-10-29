import XCTest
@testable import DaylinCut

final class TimelineEditingTests: XCTestCase {

    func testSplitKeepsTotalDurationAndSourceRanges() throws {
        var t = Timeline(clips: [Fixtures.clip(4, transition: .dissolve), Fixtures.clip(3)])
        let before = t.duration
        let originalID = t.clips[0].id
        let rightID = try XCTUnwrap(t.split(at: 1.0))
        XCTAssertEqual(t.clips.count, 3)
        XCTAssertEqual(t.duration, before, accuracy: 1e-6)
        XCTAssertEqual(t.clips[0].id, originalID)
        XCTAssertEqual(t.clips[1].id, rightID)
        XCTAssertEqual(t.clips[0].sourceEnd, 1.0, accuracy: 1e-9)
        XCTAssertEqual(t.clips[1].sourceStart, 1.0, accuracy: 1e-9)
        // The cut itself is hard; the outgoing transition stays on the right half.
        XCTAssertEqual(t.clips[0].transition.type, .none)
        XCTAssertEqual(t.clips[1].transition.type, .dissolve)
    }

    func testSplitRespectsSpeed() throws {
        var t = Timeline(clips: [Fixtures.clip(4, speed: 2)]) // 2 s on the timeline
        _ = try XCTUnwrap(t.split(at: 0.5))
        XCTAssertEqual(t.clips[0].sourceEnd, 1.0, accuracy: 1e-9)
        XCTAssertEqual(t.duration, 2, accuracy: 1e-9)
    }

    func testSplitTooCloseToEdgeIsRejected() {
        var t = Timeline(clips: [Fixtures.clip(2)])
        XCTAssertNil(t.split(at: 0.01))
        XCTAssertEqual(t.clips.count, 1)
    }

    func testDeleteClampsTextToNewDuration() {
        var t = Timeline(clips: [Fixtures.clip(2), Fixtures.clip(2)])
        t.texts = [TextOverlay(text: "Hi", start: 1, duration: 2.5), TextOverlay(text: "Late", start: 3, duration: 1)]
        t.deleteClip(id: t.clips[1].id)
        XCTAssertEqual(t.duration, 2, accuracy: 1e-9)
        XCTAssertEqual(t.texts.count, 1)
        XCTAssertEqual(t.texts[0].duration, 1, accuracy: 1e-9)
    }

    func testDuplicateAndMove() throws {
        var t = Timeline(clips: [Fixtures.clip(1), Fixtures.clip(2), Fixtures.clip(3)])
        let ids = t.clips.map(\.id)
        let copy = try XCTUnwrap(t.duplicateClip(id: ids[0]))
        XCTAssertEqual(t.clips.map(\.id), [ids[0], copy, ids[1], ids[2]])
        t.moveClip(id: ids[2], by: -10)
        XCTAssertEqual(t.clips.first?.id, ids[2])
        t.moveClip(id: ids[2], by: 1)
        XCTAssertEqual(t.clips[1].id, ids[2])
    }

    func testMoveFromOffsets() {
        var t = Timeline(clips: [Fixtures.clip(1), Fixtures.clip(2), Fixtures.clip(3)])
        let ids = t.clips.map(\.id)
        t.moveClip(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(t.clips.map(\.id), [ids[1], ids[2], ids[0]])
        t.moveClip(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(t.clips.map(\.id), ids)
    }

    func testSetSpeedIsClamped() {
        var t = Timeline(clips: [Fixtures.clip(10)])
        t.setSpeed(100, clipID: t.clips[0].id)
        XCTAssertEqual(t.clips[0].speed, Clip.maxSpeed)
        XCTAssertEqual(t.duration, 1, accuracy: 1e-9)
        t.setSpeed(0, clipID: t.clips[0].id)
        XCTAssertEqual(t.clips[0].speed, Clip.minSpeed)
    }

    func testInsertAfterClipUnderPlayhead() {
        var t = Timeline(clips: [Fixtures.clip(2), Fixtures.clip(2)])
        let new = Fixtures.clip(1)
        t.insert([new], at: 0.5)
        XCTAssertEqual(t.clips[1].id, new.id)
        let last = Fixtures.clip(1)
        t.insert([last], at: nil)
        XCTAssertEqual(t.clips.last?.id, last.id)
    }

    func testRemoveRangeClosesGapAndShiftsItems() {
        var t = Timeline(clips: [Fixtures.clip(3), Fixtures.clip(3)])
        t.texts = [TextOverlay(text: "Before", start: 0.2, duration: 0.5),
                   TextOverlay(text: "Inside", start: 2.2, duration: 0.3),
                   TextOverlay(text: "After", start: 4.5, duration: 1)]
        t.captions = [Caption(text: "a", start: 0, end: 1),
                      Caption(text: "cut", start: 2, end: 3),
                      Caption(text: "b", start: 4, end: 5)]
        t.removeRange(start: 2, end: 3)
        XCTAssertEqual(t.duration, 5, accuracy: 1e-6)
        XCTAssertEqual(t.texts.map(\.text), ["Before", "After"])
        XCTAssertEqual(t.texts[1].start, 3.5, accuracy: 1e-6)
        XCTAssertEqual(t.captions.map(\.text), ["a", "b"])
        XCTAssertEqual(t.captions[1].start, 3, accuracy: 1e-6)
        XCTAssertEqual(t.captions[1].end, 4, accuracy: 1e-6)
    }

    func testRemoveRangeNeverDeletesEverything() {
        var t = Timeline(clips: [Fixtures.clip(3)])
        t.removeRange(start: 0, end: 3)
        XCTAssertEqual(t.clips.count, 1)
    }
}
