import XCTest
@testable import DaylinCut

final class OnsetDetectorTests: XCTestCase {

    func testDetectsTempoOfSyntheticBeat() throws {
        let sampleRate = 22050.0
        let (samples, truth) = AudioSynth.beatSamples(bpm: 120, duration: 12, sampleRate: sampleRate)
        let result = OnsetDetector().analyze(samples: samples, sampleRate: sampleRate, sensitivity: 0.5)
        XCTAssertEqual(result.duration, 12, accuracy: 0.05)
        let bpm = try XCTUnwrap(result.bpm)
        // Accept the tempo or its double/half (octave errors are musically equivalent for cutting).
        let candidates = [bpm, bpm * 2, bpm / 2]
        XCTAssertTrue(candidates.contains { abs($0 - 120) < 6 }, "estimated \(bpm) BPM")
        XCTAssertGreaterThan(result.onsets.count, truth.count / 2)
        // Beats are sorted and inside the file.
        XCTAssertEqual(result.beats, result.beats.sorted())
        XCTAssertTrue(result.beats.allSatisfy { $0 >= 0 && $0 <= 12 })
    }

    func testSilenceHasNoOnsets() {
        let result = OnsetDetector().analyze(samples: [Float](repeating: 0, count: 44100 * 3), sampleRate: 44100)
        XCTAssertTrue(result.onsets.isEmpty)
    }
}

final class SceneChangeDetectorTests: XCTestCase {

    private func frame(_ t: Double, bin: Int, luma: Double = 0.5) -> SceneChangeDetector.Frame {
        var h = [Double](repeating: 0, count: 8)
        h[bin] = 1
        return .init(time: t, histogram: h, luma: luma)
    }

    func testFindsHardCut() {
        var frames: [SceneChangeDetector.Frame] = []
        for i in 0..<40 { let t = Double(i) * 0.25; frames.append(frame(t, bin: t < 5 ? 1 : 6)) }
        let scenes = SceneChangeDetector().scenes(frames: frames, duration: 10)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].end, 5, accuracy: 1e-9)
        XCTAssertEqual(scenes[1].end, 10, accuracy: 1e-9)
    }

    func testStaticShotIsOneScene() {
        let frames = (0..<20).map { frame(Double($0) * 0.5, bin: 3) }
        XCTAssertEqual(SceneChangeDetector().scenes(frames: frames, duration: 10).count, 1)
    }

    func testDarkScenesScoreLower() {
        var frames: [SceneChangeDetector.Frame] = []
        for i in 0..<40 {
            let t = Double(i) * 0.25
            frames.append(t < 5 ? frame(t, bin: 1, luma: 0.02) : frame(t, bin: 6, luma: 0.5))
        }
        let scenes = SceneChangeDetector().scenes(frames: frames, duration: 10)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertLessThan(scenes[0].score, scenes[1].score)
    }

    func testHistogramDistance() {
        XCTAssertEqual(SceneChangeDetector.distance([1, 0], [0, 1]), 1)
        XCTAssertEqual(SceneChangeDetector.distance([0.5, 0.5], [0.5, 0.5]), 0)
    }
}

final class CaptionGrouperTests: XCTestCase {

    private func words(_ text: String, start: Double = 0, step: Double = 0.3) -> [CaptionGrouper.Word] {
        text.split(separator: " ").enumerated().map { i, w in
            .init(text: String(w), start: start + Double(i) * step, duration: step * 0.9)
        }
    }

    func testSplitsOnWordLimitAndSilence() {
        let input = words("one two three four five six seven eight") + words("after pause", start: 5)
        let captions = CaptionGrouper.group(input, maxWords: 6)
        XCTAssertEqual(captions.map(\.text), ["one two three four five six", "seven eight", "after pause"])
        for (a, b) in zip(captions, captions.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-9) }
    }

    func testMaxDurationStartsNewLine() {
        let slow = words("a b c d", step: 1.2)
        XCTAssertGreaterThan(CaptionGrouper.group(slow, maxWords: 10, maxDuration: 2.8, gap: 5).count, 1)
    }

    func testEmptyInput() {
        XCTAssertTrue(CaptionGrouper.group([]).isEmpty)
    }
}

final class StoryPlannerTests: XCTestCase {

    func testMultiSentencePromptBecomesScenes() {
        let scenes = StoryPlanner.scenes(for: "A fox wakes up. It finds a map. It sails away.", sceneCount: 2)
        XCTAssertEqual(scenes.map(\.narration), ["A fox wakes up.", "It finds a map.", "It sails away."])
        XCTAssertTrue(scenes.allSatisfy { (2.5...6).contains($0.duration) && $0.palette.count == 2 })
    }

    func testShortPromptIsExpandedToArc() {
        let scenes = StoryPlanner.scenes(for: "my trip to Tokyo", sceneCount: 4)
        XCTAssertEqual(scenes.count, 4)
        XCTAssertTrue(scenes[0].narration.contains("my trip to Tokyo"))
    }

    func testEmptyPromptStillProducesStory() {
        XCTAssertFalse(StoryPlanner.scenes(for: "   ").isEmpty)
    }
}

final class AIClipperSelectionTests: XCTestCase {

    func testPicksBusiestWindowsWithoutOverlap() {
        var samples: [(time: Double, people: Int, motion: Double)] = []
        for i in 0..<60 {
            let t = Double(i) * 0.5
            let hot = (10..<14).contains(t) || (22..<26).contains(t)
            samples.append((t, hot ? 2 : 0, hot ? 0.8 : 0.05))
        }
        let picks = AIClipper.select(samples: samples, duration: 30, window: 4, count: 2)
        XCTAssertEqual(picks.count, 2)
        let sorted = picks.sorted { $0.start < $1.start }
        XCTAssertEqual(sorted[0].start, 10, accuracy: 2.01)
        XCTAssertEqual(sorted[1].start, 22, accuracy: 2.01)
        XCTAssertLessThanOrEqual(sorted[0].end, sorted[1].start + 1e-9)
    }

    func testNoSamples() {
        XCTAssertTrue(AIClipper.select(samples: [], duration: 10, window: 4, count: 3).isEmpty)
    }
}

final class ExportSettingsTests: XCTestCase {

    func testRenderSizesAreEvenAndMatchAspect() {
        var s = ExportSettings()
        s.resolution = .p1080
        XCTAssertTrue(s.renderSize(for: .portrait9x16) == (1080, 1920))
        XCTAssertTrue(s.renderSize(for: .landscape16x9) == (1920, 1080))
        XCTAssertTrue(s.renderSize(for: .square1x1) == (1080, 1080))
        XCTAssertTrue(s.renderSize(for: .portrait4x5) == (1080, 1350))
        s.resolution = .k4
        XCTAssertTrue(s.renderSize(for: .portrait9x16) == (2160, 3840))
        for r in ExportResolution.allCases {
            s.resolution = r
            for a in AspectRatio.allCases {
                let size = s.renderSize(for: a)
                XCTAssertEqual(size.width % 2, 0); XCTAssertEqual(size.height % 2, 0)
            }
        }
    }

    func testEstimatedSizeScalesWithBitrateAndDuration() {
        var s = ExportSettings()
        s.bitrateMbps = 8
        s.audioBitrateKbps = 0
        XCTAssertEqual(s.estimatedBytes(duration: 10), 8_000_000 * 10 / 8 * 1.02, accuracy: 1)
        XCTAssertEqual(s.estimatedSizeText(duration: 10), "10.2 MB")
        XCTAssertEqual(s.estimatedBytes(duration: -1), 0)
    }

    func testHighFrameRateRaisesRecommendedBitrate() {
        var s = ExportSettings()
        s.frameRate = 60
        s.resetBitrate()
        XCTAssertEqual(s.bitrateMbps, ExportResolution.p1080.recommendedBitrate * 1.5)
        XCTAssertEqual(ExportSettings.frameRates.first, 24)
        XCTAssertEqual(ExportSettings.frameRates.last, 60)
        XCTAssertTrue(ExportResolution.k4.requiresPro)
        XCTAssertFalse(ExportResolution.p1080.requiresPro)
    }
}
