import AVFoundation
import CoreImage
import UIKit

// MARK: - Errors

enum VideoEngineError: LocalizedError, Equatable {
    case emptyTimeline
    case unreadableMedia(String)
    case missingFile(String)
    case cancelled
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: return "Add at least one clip to the timeline."
        case .unreadableMedia(let f): return "The media file \(f) can't be read."
        case .missingFile(let f): return "The media file \(f) is missing."
        case .cancelled: return "The operation was cancelled."
        case .writerFailed(let m): return "Rendering failed: \(m)"
        }
    }
}

// MARK: - BuiltComposition

/// Everything AVFoundation needs to play or render a timeline.
struct BuiltComposition: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix
    let duration: CMTime
    let plan: RenderPlan

    func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

// MARK: - VideoEngine

/// Builds `AVMutableComposition` + custom video composition + audio mix from a `Timeline`.
///
/// Layout:
/// - Main clips alternate between two video tracks (A/B) and two audio tracks so
///   transitions can blend overlapping frames (Apple's AVCustomEdit pattern).
/// - Each overlay gets its own video (and optional audio) track.
/// - Each music / voice-over item gets its own audio track.
enum VideoEngine {

    static let timescale: CMTimeScale = 600

    static func cm(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: timescale)
    }

    static func build(timeline: Timeline, options: RenderPlan.Options) async throws -> BuiltComposition {
        guard !timeline.clips.isEmpty else { throw VideoEngineError.emptyTimeline }
        let layout = TimelineLayout(clips: timeline.clips)
        let composition = AVMutableComposition()
        composition.naturalSize = options.renderSize

        guard let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw VideoEngineError.writerFailed("Could not create composition tracks") }

        let videoTracks = [videoA, videoB]
        let audioTracks = [audioA, audioB]
        var videoEnds = [CMTime.zero, CMTime.zero]
        var audioEnds = [CMTime.zero, CMTime.zero]
        var clipLayers: [RenderPlan.ClipLayer] = []
        var audioParams: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        let totalTime = cm(layout.totalDuration)

        // MARK: Main clips
        for placement in layout.placements {
            let clip = timeline.clips[placement.index]
            let url = MediaStore.url(for: clip.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { throw VideoEngineError.missingFile(clip.fileName) }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoEngineError.unreadableMedia(clip.fileName)
            }
            let assetDuration = try await asset.load(.duration)
            let transform = try await sourceVideo.load(.preferredTransform)

            let t = placement.track
            var insertAt = cm(placement.start)
            if insertAt < videoEnds[t] { insertAt = videoEnds[t] }
            let timelineDuration = cm(placement.end) - insertAt
            guard timelineDuration > .zero else { continue }

            let sourceStart = cm(clip.sourceStart)
            var sourceDuration = CMTimeMultiplyByFloat64(timelineDuration, multiplier: clip.speed)
            if sourceStart + sourceDuration > assetDuration {
                sourceDuration = max(.zero, assetDuration - sourceStart)
            }
            guard sourceDuration > .zero else { continue }
            let sourceRange = CMTimeRange(start: sourceStart, duration: sourceDuration)
            let scaledDuration = abs(clip.speed - 1) < 0.001 ? sourceDuration : CMTimeMultiplyByFloat64(sourceDuration, multiplier: 1 / clip.speed)

            try videoTracks[t].insertTimeRange(sourceRange, of: sourceVideo, at: insertAt)
            if abs(clip.speed - 1) >= 0.001 {
                videoTracks[t].scaleTimeRange(CMTimeRange(start: insertAt, duration: sourceDuration), toDuration: scaledDuration)
            }
            videoEnds[t] = insertAt + scaledDuration

            clipLayers.append(RenderPlan.ClipLayer(clip: clip,
                                                   trackID: videoTracks[t].trackID,
                                                   orientation: FilterRenderer.orientation(for: transform),
                                                   placement: placement))

            // Original audio
            if !timeline.muteOriginalAudio, clip.volume > 0.001,
               let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                var audioAt = insertAt
                if audioAt < audioEnds[t] { audioAt = audioEnds[t] }
                if audioAt == insertAt {
                    try audioTracks[t].insertTimeRange(sourceRange, of: sourceAudio, at: audioAt)
                    if abs(clip.speed - 1) >= 0.001 {
                        audioTracks[t].scaleTimeRange(CMTimeRange(start: audioAt, duration: sourceDuration), toDuration: scaledDuration)
                    }
                    audioEnds[t] = audioAt + scaledDuration
                    let params = audioParams[audioTracks[t].trackID] ?? AVMutableAudioMixInputParameters(track: audioTracks[t])
                    params.audioTimePitchAlgorithm = .spectral
                    applyVolume(to: params, volume: clip.volume, start: audioAt, end: audioAt + scaledDuration,
                                fadeIn: cm(placement.transitionIn), fadeOut: cm(placement.transitionOut))
                    audioParams[audioTracks[t].trackID] = params
                }
            }
        }
        if clipLayers.count != layout.placements.count {
            // A clip produced no media (e.g. trimmed beyond its end). Keep indices aligned.
            throw VideoEngineError.unreadableMedia("one or more clips")
        }

        // MARK: Overlays
        var overlayLayers: [RenderPlan.OverlayLayer] = []
        for item in timeline.overlays where item.start < layout.totalDuration && item.duration > 0.05 {
            let url = MediaStore.url(for: item.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let assetDuration = try await asset.load(.duration)
            let transform = try await sourceVideo.load(.preferredTransform)
            let available = max(0, min(item.duration, layout.totalDuration - item.start))
            var duration = cm(available)
            let start = cm(item.sourceStart)
            if start + duration > assetDuration { duration = max(.zero, assetDuration - start) }
            guard duration > .zero else { continue }
            let range = CMTimeRange(start: start, duration: duration)
            try track.insertTimeRange(range, of: sourceVideo, at: cm(item.start))
            overlayLayers.append(.init(item: item, trackID: track.trackID, orientation: FilterRenderer.orientation(for: transform)))

            if item.volume > 0.001, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
               let aTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try aTrack.insertTimeRange(range, of: sourceAudio, at: cm(item.start))
                let params = AVMutableAudioMixInputParameters(track: aTrack)
                params.setVolume(item.volume, at: .zero)
                audioParams[aTrack.trackID] = params
            }
        }

        // MARK: Music, voice-over, sound effects
        for item in timeline.audio where item.start < layout.totalDuration && item.duration > 0.05 {
            let url = MediaStore.url(for: item.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let assetDuration = try await asset.load(.duration)
            let available = max(0, min(item.duration, layout.totalDuration - item.start))
            var duration = cm(available)
            let start = cm(item.sourceStart)
            if start + duration > assetDuration { duration = max(.zero, assetDuration - start) }
            guard duration > .zero else { continue }
            let at = cm(item.start)
            try track.insertTimeRange(CMTimeRange(start: start, duration: duration), of: sourceAudio, at: at)
            let params = AVMutableAudioMixInputParameters(track: track)
            applyVolume(to: params, volume: item.volume, start: at, end: at + duration,
                        fadeIn: cm(min(item.fadeIn, available / 2)), fadeOut: cm(min(item.fadeOut, available / 2)))
            audioParams[track.trackID] = params
        }

        // Remove empty tracks (AVFoundation dislikes empty audio tracks in exports).
        for track in composition.tracks where track.segments.isEmpty {
            composition.removeTrack(track)
            audioParams[track.trackID] = nil
        }

        // MARK: Video composition
        let plan = RenderPlan(timeline: timeline, layout: layout, options: options,
                              clipLayers: clipLayers, overlayLayers: overlayLayers)
        let compositionEnd = max(totalTime, composition.duration)
        var instructions: [CompositionInstruction] = []
        for (i, segment) in layout.segments.enumerated() {
            let start = instructions.last?.timeRange.end ?? .zero
            let end = i == layout.segments.count - 1 ? compositionEnd : cm(segment.end)
            guard end > start else { continue }
            var ids: [CMPersistentTrackID] = []
            switch segment.kind {
            case .single(let c):
                ids.append(clipLayers[c].trackID)
            case .transition(let from, let to, _):
                ids.append(clipLayers[from].trackID)
                ids.append(clipLayers[to].trackID)
            }
            for layer in overlayLayers where layer.item.start < segment.end && layer.item.end > segment.start {
                ids.append(layer.trackID)
            }
            instructions.append(CompositionInstruction(timeRange: CMTimeRange(start: start, end: end),
                                                       segment: segment, trackIDs: ids, plan: plan))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = options.smartHDR ? HDRClipCompositor.self : ClipCompositor.self
        videoComposition.renderSize = options.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, options.frameRate)))
        videoComposition.instructions = instructions
        if options.smartHDR {
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        } else {
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = Array(audioParams.values)

        return BuiltComposition(composition: composition.copy() as? AVComposition ?? composition,
                                videoComposition: videoComposition.copy() as? AVVideoComposition ?? videoComposition,
                                audioMix: audioMix.copy() as? AVAudioMix ?? audioMix,
                                duration: compositionEnd,
                                plan: plan)
    }

    /// Applies volume with optional linear fades. Ramps never overlap.
    static func applyVolume(to params: AVMutableAudioMixInputParameters, volume: Float, start: CMTime, end: CMTime, fadeIn: CMTime, fadeOut: CMTime) {
        let length = end - start
        let fin = min(fadeIn, length)
        let fout = min(fadeOut, length - fin)
        if fin > .zero {
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: start, duration: fin))
        } else {
            params.setVolume(volume, at: start)
        }
        if fout > .zero {
            params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: end - fout, duration: fout))
        }
    }

    // MARK: Thumbnails

    /// Single frame of a media file (e.g. for timeline strips).
    static func thumbnail(fileName: String, at seconds: Double, maxSize: CGSize = CGSize(width: 240, height: 240)) async -> CGImage? {
        let asset = AVURLAsset(url: MediaStore.url(for: fileName))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        return try? await generator.image(at: cm(seconds)).image
    }

    /// Rendered frame of the whole timeline including filters, text and overlays.
    static func renderedFrame(of built: BuiltComposition, at seconds: Double, maxSize: CGSize) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let t = min(cm(seconds), max(.zero, built.duration - CMTime(value: 1, timescale: 30)))
        return try? await generator.image(at: t).image
    }
}
