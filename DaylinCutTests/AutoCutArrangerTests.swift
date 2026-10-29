import XCTest
@testable import DaylinCut

final class AutoCutArrangerTests: XCTestCase {

    private func beats(bpm: Double, duration: Double) -> [Double] {
        stride(from: 0.0, to: duration, by: 60 / bpm).map { $0 }
    }

    func testMusicModeShotsLandOnBeatsAndHitTarget() {
        var settings = AutoCutSettings()
        settings.mode = .music
        settings.pacing = .medium // two beats per shot
        let grid = beats(bpm: 120, duration: 30) // 0.5 s per beat
        let lengths = AutoCutArranger.shotLengths(target: 10, beats: grid, settings: settings, scenes: [])
        XCTAssertEqual(lengths.reduce(0, +), 10, accuracy: 1e-6)
        for l in lengths.dropLast() { XCTAssertEqual(l, 1.0, accuracy: 1e-6) }
    }

    func testPacingChangesShotCount() {
        let grid = beats(bpm: 120, duration: 30)
        var counts: [AutoCutPacing: Int] = [:]
        for pacing in AutoCutPacing.allCases {
            var s = AutoCutSettings()
            s.mode = .music
            s.pacing = pacing
            counts[pacing] = AutoCutArranger.shotLengths(target: 12, beats: grid, settings: s, scenes: []).count
        }
        XCTAssertGreaterThan(counts[.fast]!, counts[.medium]!)
        XCTAssertGreaterThan(counts[.medium]!, counts[.slow]!)
    }

    func testMusicShorterThanTargetIsExtended() {
        var s = AutoCutSettings()
        s.mode = .music
        let lengths = AutoCutArranger.shotLengths(target: 20, beats: beats(bpm: 120, duration: 4), settings: s, scenes: [])
        XCTAssertEqual(lengths.reduce(0, +), 20, accuracy: 1e-6)
        XCTAssertTrue(lengths.allSatisfy { $0 >= 0.4 - 1e-9 })
    }

    func testSceneModeClampsShotsAndRespectsTarget() {
        var s = AutoCutSettings()
        s.mode = .scene
        s.pacing = .medium
        let scenes = [SceneRange(start: 0, end: 0.2, score: 0.5), SceneRange(start: 0.2, end: 10, score: 0.9),
                      SceneRange(start: 10, end: 12, score: 0.4)]
        let lengths = AutoCutArranger.shotLengths(target: 8, beats: [], settings: s, scenes: scenes)
        XCTAssertEqual(lengths.reduce(0, +), 8, accuracy: 1e-6)
        XCTAssertTrue(lengths.allSatisfy { $0 >= 0.4 - 1e-9 })
        XCTAssertTrue(lengths.allSatisfy { $0 <= 1.4 * 2.2 * 1.0 + 1e-6 })
    }

    func testZeroTargetProducesNothing() {
        XCTAssertTrue(AutoCutArranger.shotLengths(target: 0, beats: [], settings: AutoCutSettings(), scenes: []).isEmpty)
    }

    func testArrangeBuildsClipsWithinSourceBoundsAndAppliesStyle() {
        var s = AutoCutSettings()
        s.mode = .music
        s.style = .cinematic
        s.targetDuration = 8
        let a = Fixtures.clip(6), b = Fixtures.clip(6)
        let sources = [
            AutoCutSource(template: a, scenes: [SceneRange(start: 0, end: 3, score: 0.8), SceneRange(start: 3, end: 6, score: 0.6)]),
            AutoCutSource(template: b, scenes: [SceneRange(start: 0, end: 6, score: 0.7)])
        ]
        let out = AutoCutArranger.arrange(sources: sources, beats: beats(bpm: 100, duration: 20), settings: s)
        XCTAssertFalse(out.clips.isEmpty)
        for clip in out.clips {
            XCTAssertGreaterThanOrEqual(clip.sourceStart, 0)
            XCTAssertLessThanOrEqual(clip.sourceEnd, clip.sourceDuration + 1e-9)
            XCTAssertGreaterThan(clip.trimmedDuration, 0.3)
            XCTAssertEqual(clip.filter, AutoCutStyle.cinematic.filter)
            XCTAssertTrue([a.fileName, b.fileName].contains(clip.fileName))
        }
        XCTAssertEqual(Set(out.clips.map(\.id)).count, out.clips.count, "every clip gets a fresh id")
        // Cinematic puts a transition on every cut.
        XCTAssertTrue(out.clips.dropLast().allSatisfy { $0.transition.type == .fadeBlack })
        XCTAssertEqual(out.totalDuration, TimelineLayout(clips: out.clips).totalDuration, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(out.totalDuration, 8 + 1e-6)
    }

    func testArrangeNeverExceedsAvailableFootage() {
        var s = AutoCutSettings()
        s.mode = .scene
        s.targetDuration = 60
        s.applyStyleLook = false
        let out = AutoCutArranger.arrange(sources: [AutoCutSource(template: Fixtures.clip(5), scenes: [])], beats: [], settings: s)
        XCTAssertLessThanOrEqual(out.totalDuration, 5 + 1e-6)
        XCTAssertTrue(out.clips.allSatisfy { $0.transition.type == .none })
    }

    func testArrangeWithNoSources() {
        XCTAssertTrue(AutoCutArranger.arrange(sources: [], beats: [], settings: AutoCutSettings()).clips.isEmpty)
    }
}
