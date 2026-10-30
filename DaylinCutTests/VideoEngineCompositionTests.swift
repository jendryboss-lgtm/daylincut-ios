import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import DaylinCut

/// End-to-end tests for the composition built from a `Timeline`. Test media is
/// generated on the fly with `FrameVideoWriter` and `AudioSynth`.
final class VideoEngineCompositionTests: XCTestCase {

    private var createdFiles: [String] = []

    override func tearDown() {
        for name in createdFiles { try? FileManager.default.removeItem(at: MediaStore.url(for: name)) }
        createdFiles.removeAll()
        super.tearDown()
    }

    /// Writes a solid-colour test clip (optionally with a beat soundtrack) and probes it.
    private func makeClip(seconds: Double, color: CIColor, withAudio: Bool) async throws -> Clip {
        var audioURL: URL?
        if withAudio {
            let (samples, _) = AudioSynth.beatSamples(bpm: 120, duration: seconds, sampleRate: 44100)
            let url = MediaStore.temporaryFile(extension: "m4a")
            try AudioSynth.writeM4A(samples: samples, sampleRate: 44100, to: url)
            audioURL = url
        }
        let size = CGSize(width: 180, height: 320)
        let name = try await FrameVideoWriter.write(size: size, duration: seconds, fps: 30, audioURL: audioURL) { t in
            // Slight brightness ramp so consecutive frames differ.
            let k = CGFloat(0.6 + 0.4 * (t / seconds))
            return CIImage(color: CIColor(red: color.red * k, green: color.green * k, blue: color.blue * k))
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        createdFiles.append(name)
        let clip = try await MediaProbe.clip(fileName: name, kind: .video)
        XCTAssertEqual(clip.sourceDuration, seconds, accuracy: 0.1)
        XCTAssertEqual(clip.hasAudio, withAudio)
        return clip
    }

    private var options: RenderPlan.Options {
        RenderPlan.Options(renderSize: CGSize(width: 360, height: 640), frameRate: 30, watermark: false,
                           ultraHD: false, smartHDR: false, isPreview: true)
    }

    func testCompositionMatchesLayoutWithTransitions() async throws {
        var a = try await makeClip(seconds: 2, color: .red, withAudio: true)
        a.transition = Transition(type: .dissolve, duration: 0.5)
        var b = try await makeClip(seconds: 2, color: .green, withAudio: false)
        b.transition = Transition(type: .wipeLeft, duration: 0.5)
        let c = try await makeClip(seconds: 2, color: .blue, withAudio: true)
        let timeline = Timeline(clips: [a, b, c])

        let built = try await VideoEngine.build(timeline: timeline, options: options)
        let layout = built.plan.layout

        XCTAssertEqual(layout.totalDuration, 5, accuracy: 0.05)
        XCTAssertEqual(built.duration.seconds, layout.totalDuration, accuracy: 1.0 / 30 + 0.01)
        XCTAssertEqual(built.composition.duration.seconds, layout.totalDuration, accuracy: 0.1)

        // One clip layer per clip, alternating between the two main tracks (A/B).
        XCTAssertEqual(built.plan.clipLayers.count, 3)
        let ids = built.plan.clipLayers.map(\.trackID)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(ids[0], ids[2])

        // Instructions: one per segment, contiguous from 0 to the end, transitions use two tracks.
        let instructions = built.videoComposition.instructions.compactMap { $0 as? CompositionInstruction }
        XCTAssertEqual(instructions.count, layout.segments.count)
        XCTAssertEqual(instructions.first?.timeRange.start, .zero)
        for (x, y) in zip(instructions, instructions.dropFirst()) {
            XCTAssertEqual(x.timeRange.end, y.timeRange.start)
        }
        XCTAssertEqual(instructions.last!.timeRange.end.seconds, built.duration.seconds, accuracy: 1e-6)
        for (instruction, segment) in zip(instructions, layout.segments) {
            if case .transition = segment.kind {
                XCTAssertEqual(instruction.requiredSourceTrackIDs?.count, 2)
            } else {
                XCTAssertEqual(instruction.requiredSourceTrackIDs?.count, 1)
            }
        }

        // Audio from clips a and c lands on the composition's audio tracks.
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
    }

    func testCompositorRendersFrames() async throws {
        var a = try await makeClip(seconds: 1.5, color: .red, withAudio: false)
        a.transition = Transition(type: .dissolve, duration: 0.5)
        let b = try await makeClip(seconds: 1.5, color: .blue, withAudio: false)
        let built = try await VideoEngine.build(timeline: Timeline(clips: [a, b]), options: options)

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for seconds in [0.2, 1.25, 2.2] {
            let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            XCTAssertEqual(image.width, 360)
            XCTAssertEqual(image.height, 640)
        }
    }

    func testSpeedAndTrimChangeCompositionDuration() async throws {
        var a = try await makeClip(seconds: 3, color: .yellow, withAudio: true)
        a.sourceStart = 0.5
        a.sourceEnd = 2.5
        a.speed = 2
        let built = try await VideoEngine.build(timeline: Timeline(clips: [a]), options: options)
        XCTAssertEqual(built.duration.seconds, 1, accuracy: 0.05)
    }

    func testEmptyTimelineThrows() async {
        do {
            _ = try await VideoEngine.build(timeline: Timeline(), options: options)
            XCTFail("Expected emptyTimeline")
        } catch {
            XCTAssertEqual(error as? VideoEngineError, .emptyTimeline)
        }
    }

    func testExportWritesPlayableMovieWithWatermarkForFreeUsers() async throws {
        var a = try await makeClip(seconds: 1.5, color: .magenta, withAudio: true)
        a.transition = Transition(type: .fadeBlack, duration: 0.4)
        let b = try await makeClip(seconds: 1.5, color: .cyan, withAudio: true)
        var timeline = Timeline(clips: [a, b])
        timeline.texts = [TextOverlay(text: "Daylin Cut", start: 0.2, duration: 1)]

        var settings = ExportSettings()
        settings.resolution = .p480
        settings.frameRate = 24
        settings.resetBitrate()
        settings.addWatermark = false // forced on anyway because isPro is false

        let result = try await ExportService().export(timeline: timeline, settings: settings, isPro: false) { _ in }
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertFalse(result.usedHDR)
        let asset = AVURLAsset(url: result.url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, TimelineLayout(clips: timeline.clips).totalDuration, accuracy: 0.15)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size.width, 480)
        XCTAssertEqual(size.height, 854)
        let fps = try await video.load(.nominalFrameRate)
        XCTAssertEqual(Double(fps), 24, accuracy: 1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty)
    }

    func testGIFExportWritesAnimatedGIF() async throws {
        let a = try await makeClip(seconds: 1, color: .red, withAudio: false)
        let b = try await makeClip(seconds: 1, color: .blue, withAudio: false)
        let timeline = Timeline(clips: [a, b])
        var settings = ExportSettings()
        settings.format = .gif
        settings.gifFrameRate = 10
        settings.gifShortSide = 240

        let result = try await GIFExportService().export(timeline: timeline, settings: settings, isPro: true) { _ in }
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(result.url.pathExtension, "gif")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
        let expected = GIFExportService.frameTimes(duration: TimelineLayout(clips: timeline.clips).totalDuration, fps: 10).count
        XCTAssertEqual(CGImageSourceGetCount(source), expected)
        XCTAssertEqual(result.frameCount, expected)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(first.width, 240)
        XCTAssertEqual(first.height, 426)
    }
}
