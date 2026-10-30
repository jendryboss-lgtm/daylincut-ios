import CoreImage
import Photos
import SwiftData
import SwiftUI

/// `-uiTesting -uiScreen <name>` opens a screen with generated sample media so CI
/// can screenshot it: home, picker, review, editor, exportOptions, export.
enum UIScreenHarness {
    enum Screen: String {
        case home, picker, review, editor, exportOptions, export
    }

    static var isScreenshotRun: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-uiTesting") && args.contains("-uiScreen")
    }

    static func screen(from arguments: [String] = ProcessInfo.processInfo.arguments) -> Screen? {
        guard let i = arguments.firstIndex(of: "-uiScreen"), i + 1 < arguments.count else { return nil }
        return Screen(rawValue: arguments[i + 1])
    }

    /// Colour pairs for the sample clips (sunset, ocean, forest, neon).
    static let palettes: [(CIColor, CIColor)] = [
        (CIColor(red: 0.98, green: 0.55, blue: 0.20), CIColor(red: 0.55, green: 0.12, blue: 0.45)),
        (CIColor(red: 0.05, green: 0.45, blue: 0.85), CIColor(red: 0.0, green: 0.85, blue: 0.85)),
        (CIColor(red: 0.10, green: 0.55, blue: 0.30), CIColor(red: 0.75, green: 0.90, blue: 0.40)),
        (CIColor(red: 0.85, green: 0.10, blue: 0.55), CIColor(red: 0.20, green: 0.10, blue: 0.70))
    ]

    /// Writes one portrait sample clip whose gradient drifts over time.
    static func makeSampleClip(index: Int, seconds: Double = 3, withAudio: Bool = false) async throws -> Clip {
        let size = CGSize(width: 360, height: 640)
        let (a, b) = palettes[index % palettes.count]
        var audioURL: URL?
        if withAudio {
            let (samples, _) = AudioSynth.beatSamples(bpm: 120, duration: seconds, sampleRate: 44100)
            let url = MediaStore.temporaryFile(extension: "m4a")
            try AudioSynth.writeM4A(samples: samples, sampleRate: 44100, to: url)
            audioURL = url
        }
        let name = try await FrameVideoWriter.write(size: size, duration: seconds, fps: 30, audioURL: audioURL) { t in
            let shift = CGFloat(t / seconds) * size.height * 0.5
            let gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: shift),
                "inputPoint1": CIVector(x: size.width, y: size.height + shift),
                "inputColor0": a,
                "inputColor1": b
            ])?.outputImage ?? CIImage(color: a)
            return gradient.cropped(to: CGRect(origin: .zero, size: size))
        }
        return try await MediaProbe.clip(fileName: name, kind: .video)
    }

    static func sampleTimeline() async throws -> Timeline {
        var clips: [Clip] = []
        for i in 0..<3 { clips.append(try await makeSampleClip(index: i, withAudio: i == 0)) }
        var timeline = Timeline(clips: clips)
        timeline.aspectRatio = .portrait9x16
        return timeline
    }

    /// Saves sample clips to Photos (CI grants access with `simctl privacy`).
    static func seedPhotoLibrary() async {
        // CI grants access up front; never prompt from the harness.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let existing = PHAsset.fetchAssets(with: .video, options: nil).count
        guard existing < 4 else { return }
        for i in 0..<6 {
            guard let clip = try? await makeSampleClip(index: i, seconds: Double(3 + i)) else { continue }
            _ = try? await MediaLibraryService.saveVideoToPhotosReturningIdentifier(MediaStore.url(for: clip.fileName))
        }
    }

    @MainActor
    static func run(router: AppRouter, context: ModelContext, library: MediaLibraryService) async {
        guard ProcessInfo.processInfo.arguments.contains("-uiTesting"), let screen = screen() else { return }
        switch screen {
        case .home:
            if let timeline = try? await sampleTimeline() {
                let project = ProjectStore.create(timeline, name: "Sample trip", in: context)
                await ProjectStore.updateThumbnail(project, context: context)
            }
        case .picker:
            await seedPhotoLibrary()
            router.start(.newVideo)
        case .review, .editor, .exportOptions, .export:
            guard let timeline = try? await sampleTimeline() else { return }
            let project = ProjectStore.create(timeline, name: "Sample trip", in: context)
            await ProjectStore.updateThumbnail(project, context: context)
            switch screen {
            case .review: router.flow = CreationFlow(intent: .newVideo, stage: .review(project, timeline))
            case .exportOptions: router.open(project, action: .exportOptions)
            case .export: router.open(project, action: .exportSheet)
            default: router.open(project)
            }
        }
    }
}
