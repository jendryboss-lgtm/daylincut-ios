import XCTest
@testable import ClipForge

final class TimelineLayoutTests: XCTestCase {

    func testBackToBackClipsWithoutTransitions() {
        let layout = TimelineLayout(clips: [Fixtures.clip(2), Fixtures.clip(3), Fixtures.clip(1.5)])
        XCTAssertEqual(layout.totalDuration, 6.5, accuracy: 1e-9)
        XCTAssertEqual(layout.clipStarts, [0, 2, 5])
        XCTAssertEqual(layout.placements.map(\.track), [0, 1, 0])
        XCTAssertEqual(layout.segments.count, 3)
        XCTAssertTrue(layout.isContiguous)
    }

    func testTransitionsOverlapNeighbours() {
        let clips = [Fixtures.clip(2, transition: .dissolve), Fixtures.clip(2, transition: .wipeLeft), Fixtures.clip(2)]
        let layout = TimelineLayout(clips: clips)
        // Two 0.5 s overlaps shorten the 6 s of footage to 5 s.
        XCTAssertEqual(layout.totalDuration, 5, accuracy: 1e-9)
        XCTAssertEqual(layout.placements[1].start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(layout.placements[2].start, 3.0, accuracy: 1e-9)
        XCTAssertEqual(layout.placements[1].transitionIn, 0.5, accuracy: 1e-9)
        XCTAssertEqual(layout.placements[1].transitionOut, 0.5, accuracy: 1e-9)
        // single, transition, single, transition, single
        XCTAssertEqual(layout.segments.count, 5)
        XCTAssertTrue(layout.isContiguous)
        if case .transition(let from, let to, let type) = layout.segments[1].kind {
            XCTAssertEqual(from, 0); XCTAssertEqual(to, 1); XCTAssertEqual(type, .dissolve)
        } else {
            XCTFail("Expected a transition segment")
        }
        // Overlapping clips must sit on different tracks.
        XCTAssertNotEqual(layout.placements[0].track, layout.placements[1].track)
    }

    func testTransitionIsClampedToHalfOfShortestNeighbour() {
        let clips = [Fixtures.clip(4, transition: .dissolve, transitionDuration: 3), Fixtures.clip(1)]
        let layout = TimelineLayout(clips: clips)
        XCTAssertEqual(layout.placements[0].transitionOut, 0.5, accuracy: 1e-9)
        XCTAssertEqual(layout.totalDuration, 4.5, accuracy: 1e-9)
        XCTAssertTrue(layout.isContiguous)
    }

    func testNoneTransitionHasNoOverlap() {
        let layout = TimelineLayout(clips: [Fixtures.clip(2, transition: .none, transitionDuration: 1), Fixtures.clip(2)])
        XCTAssertEqual(layout.totalDuration, 4, accuracy: 1e-9)
    }

    func testSpeedChangesTimelineDuration() {
        let layout = TimelineLayout(clips: [Fixtures.clip(4, speed: 2), Fixtures.clip(1, speed: 0.5)])
        XCTAssertEqual(layout.totalDuration, 4, accuracy: 1e-9)
    }

    func testClipIndexAtTime() {
        let layout = TimelineLayout(clips: [Fixtures.clip(2, transition: .dissolve, transitionDuration: 1), Fixtures.clip(2)])
        // Overlap is [1, 2): first half belongs to clip 0, second to clip 1.
        XCTAssertEqual(layout.clipIndex(at: 0.5), 0)
        XCTAssertEqual(layout.clipIndex(at: 1.2), 0)
        XCTAssertEqual(layout.clipIndex(at: 1.8), 1)
        XCTAssertEqual(layout.clipIndex(at: 2.5), 1)
        XCTAssertEqual(layout.clipIndex(at: -1), 0)
        XCTAssertEqual(layout.clipIndex(at: 99), 1)
        XCTAssertNil(TimelineLayout(clips: []).clipIndex(at: 0))
    }

    func testEmptyLayout() {
        let layout = TimelineLayout(clips: [])
        XCTAssertEqual(layout.totalDuration, 0)
        XCTAssertTrue(layout.isContiguous)
    }
}
