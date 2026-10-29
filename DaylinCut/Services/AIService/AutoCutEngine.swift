import AVFoundation
import CoreGraphics
import Foundation

// MARK: - AutoCutEngine

/// Real on-device AutoCut: analyses footage (scene changes from colour histograms)
/// and music (onsets + tempo), then arranges an edit with `AutoCutArranger`.
enum AutoCutEngine {

    struct Outcome: Sendable {
        var timeline: Timeline
        var bpm: Double?
        var sceneCount: Int
        var shotCount: Int
    }

    static func run(on timeline: Timeline,
                    settings: AutoCutSettings,
                    progress: @escaping @Sendable (Double, String) -> Void) async throws -> Outcome {
        // Unique sources in timeline order.
        var seen = Set<String>()
        var templates: [Clip] = []
        for clip in timeline.clips where seen.insert(clip.fileName).inserted {
            var t = clip
            t.sourceStart = 0
            t.sourceEnd = clip.sourceDuration
            t.speed = 1
            t.transition = Transition()
            templates.append(t)
        }
        guard !templates.isEmpty else { throw VideoEngineError.emptyTimeline }

        // 1. Scenes
        var sources: [AutoCutSource] = []
        var sceneCount = 0
        for (i, template) in templates.enumerated() {
            try Task.checkCancellation()
            progress(0.05 + 0.55 * Double(i) / Double(templates.count), "Detecting scenes")
            var scenes: [SceneRange] = []
            if template.mediaKind == .video && settings.mode != .music {
                let frames = try await sampleFrames(fileName: template.fileName, duration: template.sourceDuration)
                scenes = SceneChangeDetector().scenes(frames: frames, duration: template.sourceDuration,
                                                       sensitivity: settings.sensitivity)
            } else if template.mediaKind == .video {
                // Music mode still benefits from skipping the shaky first/last half second.
                let d = template.sourceDuration
                scenes = d > 2 ? [SceneRange(start: 0.3, end: d - 0.3, score: 0.5)] : []
            }
            sceneCount += max(1, scenes.count)
            sources.append(AutoCutSource(template: template, scenes: scenes))
        }

        // 2. Music / beats
        var result = timeline
        var beats: [Double] = []
        var bpm: Double?
        if settings.mode != .scene {
            progress(0.65, "Finding the beat")
            if let index = result.audio.firstIndex(where: { $0.kind == .music }) {
                let item = result.audio[index]
                let samples = try await AudioSynth.readMonoSamples(url: MediaStore.url(for: item.fileName), sampleRate: 11025,
                                                                     maxDuration: item.sourceStart + max(settings.targetDuration, 10) + 5)
                let analysis = OnsetDetector().analyze(samples: samples, sampleRate: 11025, sensitivity: settings.sensitivity)
                beats = analysis.beats.map { $0 - item.sourceStart + item.start }.filter { $0 >= 0 }
                bpm = analysis.bpm
                result.audio[index].beats = beats
            } else {
                let beat = try AudioSynth.makeBeat(bpm: settings.style.bpm, duration: settings.targetDuration + 2)
                // Verify the generated track with the same detector the user's music goes through.
                let samples = try await AudioSynth.readMonoSamples(url: MediaStore.url(for: beat.fileName))
                let analysis = OnsetDetector().analyze(samples: samples, sampleRate: 11025, sensitivity: settings.sensitivity)
                beats = analysis.beats.count >= 4 ? analysis.beats : beat.beats
                bpm = analysis.bpm ?? beat.bpm
                result.audio.append(AudioItem(kind: .music, title: "\(settings.style.title) Beat", fileName: beat.fileName,
                                              sourceDuration: beat.duration, start: 0, sourceStart: 0,
                                              duration: beat.duration, volume: 0.8, fadeIn: 0, fadeOut: 1, beats: beats))
            }
        }

        // 3. Arrange
        progress(0.85, "Arranging shots")
        let output = AutoCutArranger.arrange(sources: sources, beats: beats, settings: settings)
        guard !output.clips.isEmpty else { throw VideoEngineError.unreadableMedia("Not enough footage for AutoCut") }
        result.clips = output.clips
        result.aspectRatio = settings.aspectRatio
        result.captions = []
        result.clampToDuration()
        // Music should end with the edit.
        let total = result.duration
        for i in result.audio.indices where result.audio[i].kind == .music {
            result.audio[i].duration = min(result.audio[i].duration, max(0.1, total - result.audio[i].start))
            result.audio[i].fadeOut = min(1, result.audio[i].duration / 4)
        }
        progress(1, "Done")
        return Outcome(timeline: result, bpm: bpm, sceneCount: sceneCount, shotCount: output.clips.count)
    }

    /// Samples tiny frames and computes 3×8-bin RGB histograms + mean luma.
    static func sampleFrames(fileName: String, duration: Double) async throws -> [SceneChangeDetector.Frame] {
        let asset = AVURLAsset(url: MediaStore.url(for: fileName))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 64)
        let tolerance = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let step = max(0.2, min(1.0, duration / 150))
        var frames: [SceneChangeDetector.Frame] = []
        var t = 0.0
        while t < duration - 0.05 {
            try Task.checkCancellation()
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
               let frame = histogram(image, time: t) {
                frames.append(frame)
            }
            t += step
        }
        return frames
    }

    static func histogram(_ image: CGImage, time: Double) -> SceneChangeDetector.Frame? {
        let w = 32, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var hist = [Double](repeating: 0, count: 24)
        var luma = 0.0
        let n = Double(w * h)
        for p in 0..<(w * h) {
            let r = Int(pixels[p * 4]), g = Int(pixels[p * 4 + 1]), b = Int(pixels[p * 4 + 2])
            hist[r >> 5] += 1
            hist[8 + (g >> 5)] += 1
            hist[16 + (b >> 5)] += 1
            luma += (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255
        }
        let total = n * 3
        return SceneChangeDetector.Frame(time: time, histogram: hist.map { $0 / total }, luma: luma / n)
    }
}
