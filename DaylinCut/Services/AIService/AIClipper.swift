import AVFoundation
import CoreImage
import Foundation

// MARK: - AIClipper

/// Vision analysis that feeds `AIClipper.select`.
extension AIClipper {
    static func highlights(in clips: [Clip], window: Double = 4, perClip: Int = 3,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Highlight] {
        var result: [Highlight] = []
        for (ci, clip) in clips.enumerated() where clip.mediaKind == .video {
            let asset = AVURLAsset(url: MediaStore.url(for: clip.fileName))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 256)
            let step = max(0.5, clip.sourceDuration / 60)
            var samples: [(time: Double, people: Int, motion: Double)] = []
            var previous: [Double]?
            var t = 0.0
            while t < clip.sourceDuration {
                try Task.checkCancellation()
                if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                    let people = SegmentationService.humanRects(in: image).count
                    let hist = AutoCutEngine.histogram(image, time: t)?.histogram ?? []
                    let motion = previous.map { SceneChangeDetector.distance($0, hist) } ?? 0
                    previous = hist
                    samples.append((t, people, motion))
                }
                t += step
                progress((Double(ci) + t / clip.sourceDuration) / Double(max(1, clips.count)))
            }
            let w = min(window, clip.sourceDuration)
            for h in select(samples: samples, duration: clip.sourceDuration, window: w, count: perClip) {
                result.append(Highlight(clipID: clip.id, start: h.start, end: h.end, score: h.score))
            }
        }
        progress(1)
        return result
    }
}
