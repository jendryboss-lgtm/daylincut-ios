import AVFoundation
import Foundation

// MARK: - AudioSynth file output

extension AudioSynth {
    /// Writes a beat loop to an .m4a in the media store.
    static func makeBeat(bpm: Double, duration: Double) throws -> Beat {
        let sampleRate = 44100.0
        let (samples, beats) = beatSamples(bpm: bpm, duration: duration, sampleRate: sampleRate)
        let target = MediaStore.newFile(extension: "m4a")
        try writeM4A(samples: samples, sampleRate: sampleRate, to: target.url)
        return Beat(fileName: target.name, duration: duration, bpm: bpm, beats: beats)
    }

    static func writeM4A(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw VideoEngineError.writerFailed("Audio format")
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 44100
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let channel = buffer.floatChannelData?[0] else { break }
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress! + offset, count: n)
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            offset += n
        }
    }

    /// Reads any audio (or the audio track of a video) as mono Float samples.
    static func readMonoSamples(url: URL, sampleRate: Double = 11025, maxDuration: Double = 600) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxDuration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoEngineError.unreadableMedia(url.lastPathComponent) }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        return samples
    }
}
