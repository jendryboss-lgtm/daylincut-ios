import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - GIFExportService

/// Renders a timeline to an animated GIF: the composition (with the same
/// compositor, filters, text and watermark as video export) is sampled at the
/// GIF frame rate and written with ImageIO as a looping GIF.
final class GIFExportService: @unchecked Sendable {

    struct Result: Sendable {
        var url: URL
        var bytes: Int64
        var frameCount: Int
        var size: CGSize
    }

    private let lock = NSLock()
    private var isCancelled = false

    func cancel() { lock.withLock { isCancelled = true } }
    private var cancelled: Bool { lock.withLock { isCancelled } }

    /// Frame times (seconds) for a clip of `duration` at `fps`; always at least one frame.
    static func frameTimes(duration: Double, fps: Int) -> [Double] {
        let fps = max(1, fps)
        let count = max(1, Int((max(0, duration) * Double(fps)).rounded(.up)))
        return (0..<count).map { Double($0) / Double(fps) }
    }

    func export(timeline: Timeline,
                settings: ExportSettings,
                isPro: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let size = settings.gifRenderSize(for: timeline.aspectRatio)
        let renderSize = CGSize(width: size.width, height: size.height)
        let options = RenderPlan.Options(renderSize: renderSize,
                                         frameRate: settings.gifFrameRate,
                                         watermark: settings.addWatermark || !isPro,
                                         ultraHD: false,
                                         smartHDR: false,
                                         isPreview: false)
        let built = try await VideoEngine.build(timeline: timeline, options: options)
        let duration = built.duration.seconds
        guard duration.isFinite, duration > 0 else { throw VideoEngineError.writerFailed("Nothing to export") }

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.maximumSize = renderSize
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(max(2, settings.gifFrameRate * 2)))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let lastFrame = max(0, duration - 1.0 / 60)
        let times = Self.frameTimes(duration: duration, fps: settings.gifFrameRate).map { min($0, lastFrame) }
        let url = MediaStore.temporaryFile(extension: "gif")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw VideoEngineError.writerFailed("Could not create GIF file")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]
        ] as CFDictionary)
        let delay = 1.0 / Double(max(1, settings.gifFrameRate))
        let frameProperties = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay,
                kCGImagePropertyGIFUnclampedDelayTime as String: delay
            ]
        ] as CFDictionary

        var previous: CGImage?
        for (i, t) in times.enumerated() {
            if cancelled || Task.isCancelled {
                try? FileManager.default.removeItem(at: url)
                throw VideoEngineError.cancelled
            }
            let time = CMTime(seconds: t, preferredTimescale: 600)
            var image: CGImage?
            do { image = try await generator.image(at: time).image } catch { image = previous }
            // The frame count is fixed up front, so a failed grab repeats the previous frame.
            guard let frame = image ?? previous else { throw VideoEngineError.writerFailed("Could not render GIF frame") }
            CGImageDestinationAddImage(destination, frame, frameProperties)
            previous = frame
            progress(Double(i + 1) / Double(times.count) * 0.97)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw VideoEngineError.writerFailed("Could not finish GIF")
        }
        progress(1)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Result(url: url, bytes: bytes, frameCount: times.count, size: renderSize)
    }
}
