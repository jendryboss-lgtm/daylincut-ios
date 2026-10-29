import AVFoundation
import CoreImage
import UIKit

// MARK: - FrameVideoWriter

/// Writes procedurally generated frames to an H.264 .mp4 in the `MediaStore`.
/// Used to turn photos into still clips and by the local AI generators.
enum FrameVideoWriter {

    /// - Parameters:
    ///   - size: output pixel size (rounded to even numbers).
    ///   - frame: returns the image for a time in seconds. Its extent should match `size`.
    static func write(size rawSize: CGSize,
                      duration: Double,
                      fps: Int = 30,
                      audioURL: URL? = nil,
                      progress: (@Sendable (Double) -> Void)? = nil,
                      frame: (Double) -> CIImage) async throws -> String {
        let size = CGSize(width: max(2, (Int(rawSize.width) / 2) * 2), height: max(2, (Int(rawSize.height) / 2) * 2))
        let target = MediaStore.newFile(extension: "mp4")
        let writer = try AVAssetWriter(outputURL: target.url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * 4),
                AVVideoMaxKeyFrameIntervalKey: fps
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw VideoEngineError.writerFailed("Cannot add video input") }
        writer.add(input)

        // Optional audio passthrough-encode (e.g. TTS narration or generated music).
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioURL {
            let asset = AVURLAsset(url: audioURL)
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2
                ])
                if reader.canAdd(output) { reader.add(output) }
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 160_000
                ])
                aInput.expectsMediaDataInRealTime = false
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    audioReader = reader
                    audioOutput = output
                    audioInput = aInput
                }
            }
        }

        guard writer.startWriting() else { throw VideoEngineError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        audioReader?.startReading()

        // AVAssetWriter interleaves tracks: once the video input runs ahead of the audio input
        // it stops reporting ready until audio arrives. Audio is therefore pumped alongside the
        // video frames instead of after them, which would deadlock.
        var audioFinished = audioInput == nil
        func pumpAudio() -> Bool {
            guard !audioFinished, let audioInput, let audioOutput else { return false }
            var appended = false
            while audioInput.isReadyForMoreMediaData {
                guard let sample = audioOutput.copyNextSampleBuffer() else {
                    audioInput.markAsFinished()
                    audioFinished = true
                    return true
                }
                if !audioInput.append(sample) {
                    audioInput.markAsFinished()
                    audioFinished = true
                    return true
                }
                appended = true
            }
            return appended
        }
        /// Waits until `input` can take more data, feeding audio meanwhile. Fails instead of
        /// spinning forever if the writer stops making progress.
        func waitUntilReady(_ input: AVAssetWriterInput) async throws {
            var idle = 0
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed {
                    throw VideoEngineError.writerFailed(writer.error?.localizedDescription ?? "writer failed")
                }
                if pumpAudio() { idle = 0; continue }
                idle += 1
                if idle > 5_000 { throw VideoEngineError.writerFailed("Writer stalled") } // ~10 s
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        let frameCount = max(1, Int((duration * Double(fps)).rounded()))
        let canvas = CGRect(origin: .zero, size: size)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<frameCount {
            try Task.checkCancellation()
            try await waitUntilReady(input)
            let t = Double(i) / Double(fps)
            guard let pool = adaptor.pixelBufferPool else { throw VideoEngineError.writerFailed("No pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw VideoEngineError.writerFailed("No pixel buffer") }
            autoreleasepool {
                let image = frame(t).cropped(to: canvas)
                RenderContext.shared.render(image, to: buffer, bounds: canvas, colorSpace: colorSpace)
            }
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) {
                throw VideoEngineError.writerFailed(writer.error?.localizedDescription ?? "append")
            }
            progress?(Double(i + 1) / Double(frameCount) * (audioInput == nil ? 1 : 0.9))
            _ = pumpAudio()
        }
        input.markAsFinished()

        if let audioInput {
            while !audioFinished {
                try await waitUntilReady(audioInput)
                _ = pumpAudio()
            }
        }

        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoEngineError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
        }
        progress?(1)
        return target.name
    }

    /// Converts a still photo into a clip-ready video. The image is normalised to `.up`
    /// orientation and limited to `maxDimension` on its long side.
    static func stillVideo(from image: UIImage, duration: Double = 10, maxDimension: CGFloat = 1920) async throws -> (fileName: String, size: CGSize) {
        guard let normalized = normalize(image, maxDimension: maxDimension), let cg = normalized.cgImage else {
            throw VideoEngineError.writerFailed("Unreadable photo")
        }
        let ci = CIImage(cgImage: cg)
        let size = CGSize(width: (cg.width / 2) * 2, height: (cg.height / 2) * 2)
        // Stills only need a couple of frames per second; the player holds each frame.
        let name = try await write(size: size, duration: duration, fps: 2) { _ in ci }
        return (name, size)
    }

    static func normalize(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxDimension / max(w, h))
        let size = CGSize(width: floor(w * scale / 2) * 2, height: floor(h * scale / 2) * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
