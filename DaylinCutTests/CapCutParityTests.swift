import XCTest
@testable import DaylinCut

final class ExportOptionsTests: XCTestCase {

    func testBitrateStopsSnapToNearestOption() {
        XCTAssertEqual(ExportSettings.nearestBitrateOption(to: 9), 10)
        XCTAssertEqual(ExportSettings.nearestBitrateOption(to: 40), 50)
        XCTAssertEqual(ExportSettings.nearestBitrateOption(to: 1), 5)
        XCTAssertEqual(ExportSettings.nearestBitrateOption(to: 500), 100)
        var s = ExportSettings()
        s.resolution = .p1080
        s.frameRate = 30
        XCTAssertEqual(s.recommendedBitrateOption, 10)
        s.bitrateMbps = 50
        XCTAssertEqual(s.bitrateOptionIndex, ExportSettings.bitrateOptions.firstIndex(of: 50))
        XCTAssertEqual(s.bitsPerSecond, 50_000_000)
    }

    func testCodecChoice() {
        var s = ExportSettings()
        XCTAssertFalse(s.usesHEVC(width: 1080, height: 1920))
        XCTAssertTrue(s.usesHEVC(width: 2160, height: 3840))
        s.codec = .h264
        XCTAssertFalse(s.usesHEVC(width: 2160, height: 3840))
        s.codec = .hevc
        XCTAssertTrue(s.usesHEVC(width: 480, height: 854))
    }

    func testGIFEstimateScalesWithFrameRateAndSize() {
        var s = ExportSettings()
        s.format = .gif
        s.gifFrameRate = 10
        s.gifShortSide = 240
        let small = s.estimatedGIFBytes(duration: 4, aspect: .portrait9x16)
        XCTAssertGreaterThan(small, 0)
        s.gifFrameRate = 20
        XCTAssertEqual(s.estimatedGIFBytes(duration: 4, aspect: .portrait9x16), small * 2, accuracy: 1)
        s.gifShortSide = 480
        XCTAssertGreaterThan(s.estimatedGIFBytes(duration: 4, aspect: .portrait9x16), small * 2)
        XCTAssertEqual(s.gifRenderSize(for: .square1x1).width, 480)
        XCTAssertTrue(s.estimatedSizeText(duration: 4, aspect: .portrait9x16).hasSuffix("MB"))
        XCTAssertEqual(s.estimatedGIFBytes(duration: -3, aspect: .portrait9x16), 0)
    }

    func testDecodingOlderSettingsKeepsValuesAndDefaultsNewFields() throws {
        let json = #"{"resolution":720,"frameRate":60,"bitrateMbps":20,"smartHDR":true,"unknownKey":1,"codec":"bogus"}"#
        let s = try JSONDecoder().decode(ExportSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.resolution, .p720)
        XCTAssertEqual(s.frameRate, 60)
        XCTAssertEqual(s.bitrateMbps, 20)
        XCTAssertTrue(s.smartHDR)
        XCTAssertEqual(s.format, .video)
        XCTAssertEqual(s.codec, .automatic)
        XCTAssertEqual(s.gifFrameRate, 15)

        var round = ExportSettings()
        round.format = .gif
        round.gifShortSide = 480
        let back = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(round))
        XCTAssertEqual(back, round)
    }

    func testGIFFrameTimes() {
        let t = GIFExportService.frameTimes(duration: 2, fps: 10)
        XCTAssertEqual(t.count, 20)
        XCTAssertEqual(t.first, 0)
        XCTAssertEqual(t[1], 0.1, accuracy: 1e-9)
        XCTAssertEqual(GIFExportService.frameTimes(duration: 0, fps: 15).count, 1)
        XCTAssertEqual(GIFExportService.frameTimes(duration: 1.05, fps: 10).count, 11)
    }
}

final class PickerAndPromptTests: XCTestCase {

    private func candidate(_ id: String, video: Bool, duration: Double = 0, minutesAgo: Double) -> PickForMe.Candidate {
        PickForMe.Candidate(id: id, isVideo: video, duration: duration, date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }

    func testPickForMePrefersShortVideosSpreadOverTime() {
        let candidates = [
            candidate("long", video: true, duration: 600, minutesAgo: 1),
            candidate("v1", video: true, duration: 8, minutesAgo: 2),
            candidate("v1-burst", video: true, duration: 8, minutesAgo: 2.2),
            candidate("v2", video: true, duration: 15, minutesAgo: 30),
            candidate("tiny", video: true, duration: 0.5, minutesAgo: 50),
            candidate("p1", video: false, minutesAgo: 90),
            candidate("p2", video: false, minutesAgo: 200)
        ]
        let picked = PickForMe.select(from: candidates, minimumTotal: 4)
        XCTAssertFalse(picked.contains("long"))
        XCTAssertFalse(picked.contains("tiny"))
        XCTAssertTrue(picked.contains("v1"))
        XCTAssertTrue(picked.contains("v2"))
        XCTAssertFalse(picked.contains("v1-burst"), "bursts from the same minute are skipped")
        XCTAssertEqual(picked.count, 4)
        // Oldest first, so the edit plays in shooting order.
        XCTAssertEqual(picked.first, "p2")
        XCTAssertEqual(picked.last, "v1")
    }

    func testPickForMeCapsTotal() {
        let candidates = (0..<40).map { candidate("p\($0)", video: false, minutesAgo: Double($0) * 10) }
        XCTAssertEqual(PickForMe.select(from: candidates).count, 8)
        XCTAssertTrue(PickForMe.select(from: []).isEmpty)
    }

    func testPromptParsing() {
        let travel = AutoCutPromptParser.settings(for: "A chill beach trip recap, 30s, square")
        XCTAssertEqual(travel.style, .travel)
        XCTAssertEqual(travel.pacing, .slow)
        XCTAssertEqual(travel.targetDuration, 30)
        XCTAssertEqual(travel.aspectRatio, .square1x1)

        let hype = AutoCutPromptParser.settings(for: "Hype gym workout to the beat, 1 min landscape")
        XCTAssertEqual(hype.style, .fitness)
        XCTAssertEqual(hype.pacing, .fast)
        XCTAssertEqual(hype.targetDuration, 60)
        XCTAssertEqual(hype.mode, .music)
        XCTAssertEqual(hype.aspectRatio, .landscape16x9)

        var base = AutoCutSettings()
        base.style = .vlog
        base.targetDuration = 15
        let empty = AutoCutPromptParser.settings(for: "   ", base: base)
        XCTAssertEqual(empty.style, .vlog)
        XCTAssertEqual(empty.targetDuration, 15)
    }

    func testUIScreenArgument() {
        XCTAssertEqual(UIScreenHarness.screen(from: ["app", "-uiTesting", "-uiScreen", "review"]), .review)
        XCTAssertEqual(UIScreenHarness.screen(from: ["app", "-uiScreen", "exportOptions"]), .exportOptions)
        XCTAssertNil(UIScreenHarness.screen(from: ["app", "-uiScreen"]))
        XCTAssertNil(UIScreenHarness.screen(from: ["app", "-uiScreen", "nope"]))
    }
}

final class ReviewLooksTests: XCTestCase {

    func testAppendEndingAddsCardWithFadeAndTitle() {
        var t = Timeline(clips: [Fixtures.clip(3), Fixtures.clip(2)])
        let before = t.duration
        var card = Fixtures.clip(Timeline.endingDuration)
        card.transition = Transition(type: .dissolve, duration: 0.5)
        t.appendEnding(card)
        XCTAssertEqual(t.clips.count, 3)
        XCTAssertEqual(t.clips[1].transition.type, .fadeBlack)
        XCTAssertEqual(t.clips[2].transition.type, .none)
        XCTAssertGreaterThan(t.duration, before)
        let title = try? XCTUnwrap(t.texts.last)
        XCTAssertEqual(title?.text, Timeline.endingTitle)
        let cardStart = TimelineLayout(clips: t.clips).placements.last?.start ?? -1
        XCTAssertEqual(title?.start ?? -1, cardStart, accuracy: 1e-6)
    }

    func testLooksTabs() {
        XCTAssertFalse(LooksTab.forYou.templates(bookmarked: []).isEmpty)
        XCTAssertTrue(LooksTab.lyrics.templates(bookmarked: []).allSatisfy { !$0.titleText.isEmpty })
        XCTAssertTrue(LooksTab.lifestyle.templates(bookmarked: []).allSatisfy { [.travel, .vlog, .fitness].contains($0.category) })
        XCTAssertTrue(LooksTab.lyrics.addsCaptions)
        XCTAssertFalse(LooksTab.beat.addsCaptions)
        let least = TemplatePreset.all.min(by: { $0.uses < $1.uses })!
        XCTAssertEqual(LooksTab.forYou.templates(bookmarked: [least.id]).first?.id, least.id)
    }

    func testBookmarksToggle() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "looks-\(UUID().uuidString)"))
        XCTAssertTrue(LookBookmarks.load(defaults).isEmpty)
        XCTAssertEqual(LookBookmarks.toggle("a", defaults), ["a"])
        XCTAssertEqual(LookBookmarks.load(defaults), ["a"])
        XCTAssertEqual(LookBookmarks.toggle("a", defaults), [])
    }
}
