import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

// MARK: - ExportService

/// Renders a timeline to a movie file with `AVAssetReader` → `AVAssetWriter`
/// so resolution, frame rate, bitrate and HDR are fully controllable.
final class ExportService: @unchecked Sendable {

    struct Result: Sendable {
        var url: URL
        var bytes: Int64
        var duration: Double
        var usedHDR: Bool
    }

    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        reader?.cancelReading()
        writer?.cancelWriting()
        lock.unlock()
    }

    /// - Parameters:
    ///   - isPro: Pro users get no watermark and may export 4K.
    func export(timeline: Timeline,
                settings: ExportSettings,
                isPro: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        var settings = settings
        if !isPro && settings.resolution.requiresPro { settings.resolution = .p1080 }
        let watermark = settings.addWatermark || !isPro
        do {
            return try await render(timeline: timeline, settings: settings, watermark: watermark, hdr: settings.smartHDR, progress: progress)
        } catch let error where settings.smartHDR && !(error is CancellationError) && (error as? VideoEngineError) != .cancelled {
            // Some devices can't encode 10-bit HEVC: fall back to SDR H.264.
            return try await render(timeline: timeline, settings: settings, watermark: watermark, hdr: false, progress: progress)
        }
    }

    private func render(timeline: Timeline, settings: ExportSettings, watermark: Bool, hdr: Bool,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let size = settings.renderSize(for: timeline.aspectRatio)
        let renderSize = CGSize(width: size.width, height: size.height)
        let options = RenderPlan.Options(renderSize: renderSize,
                                         frameRate: settings.frameRate,
                                         watermark: watermark,
                                         ultraHD: settings.aiUltraHD,
                                         smartHDR: hdr,
                                         isPreview: false)
        let built = try await VideoEngine.build(timeline: timeline, options: options)
        let durationSeconds = built.duration.seconds

        let url = MediaStore.temporaryFile(extension: hdr ? "mov" : "mp4")
        let reader = try AVAssetReader(asset: built.composition)
        let writer = try AVAssetWriter(outputURL: url, fileType: hdr ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // MARK: Video
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoEngineError.writerFailed("Reader video output") }
        reader.add(videoOutput)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitsPerSecond,
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2,
            AVVideoAllowFrameReorderingKey: true
        ]
        var videoSettings: [String: Any] = [
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height
        ]
        if hdr {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        } else {
            videoSettings[AVVideoCodecKey] = size.width * size.height > 1920 * 1080 ? AVVideoCodecType.hevc : AVVideoCodecType.h264
            if videoSettings[AVVideoCodecKey] as? AVVideoCodecType == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }
        videoSettings[AVVideoCompressionPropertiesKey] = compression
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoEngineError.writerFailed("Writer rejected video settings") }
        writer.add(videoInput)

        // MARK: Audio
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2
            ])
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            if reader.canAdd(output) {
                reader.add(output)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: settings.audioBitrateKbps * 1000
                ])
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioOutput = output
                    audioInput = input
                }
            }
        }

        lock.lock()
        self.reader = reader
        self.writer = writer
        let cancelledEarly = isCancelled
        lock.unlock()
        if cancelledEarly { throw VideoEngineError.cancelled }

        guard reader.startReading() else { throw VideoEngineError.writerFailed(reader.error?.localizedDescription ?? "startReading") }
        guard writer.startWriting() else { throw VideoEngineError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        let total = max(0.01, durationSeconds)
        let videoQueue = DispatchQueue(label: "com.daylincut.export.video")
        let audioQueue = DispatchQueue(label: "com.daylincut.export.audio")
        let group = DispatchGroup()

        group.enter()
        let videoDone = OnceFlag()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    if videoDone.set() { group.leave() }
                    return
                }
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if !videoInput.append(sample) {
                    reader.cancelReading()
                    videoInput.markAsFinished()
                    if videoDone.set() { group.leave() }
                    return
                }
                progress(min(0.99, t / total))
            }
        }

        if let audioInput, let audioOutput {
            group.enter()
            let audioDone = OnceFlag()
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        if audioDone.set() { group.leave() }
                        return
                    }
                    if !audioInput.append(sample) {
                        audioInput.markAsFinished()
                        if audioDone.set() { group.leave() }
                        return
                    }
                }
            }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }

        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw VideoEngineError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw VideoEngineError.writerFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        writer.endSession(atSourceTime: built.duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoEngineError.writerFailed(writer.error?.localizedDescription ?? "writer failed")
        }
        progress(1)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Result(url: url, bytes: bytes, duration: durationSeconds, usedHDR: hdr)
    }
}

/// Thread-safe one-shot flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true the first time only.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
