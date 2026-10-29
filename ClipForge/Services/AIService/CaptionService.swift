import AVFoundation
import Foundation
import Speech

// MARK: - CaptionService

/// Auto captions with the Speech framework (on-device when supported).
enum CaptionService {

    enum CaptionError: LocalizedError {
        case notAuthorized, unavailable, noSpeech
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Speech recognition permission is required for auto captions. Enable it in Settings."
            case .unavailable: return "Speech recognition isn't available for your language right now."
            case .noSpeech: return "No speech was detected in this video."
            }
        }
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes the mixed audio of `timeline` and returns timed words.
    static func transcribe(timeline: Timeline, locale: Locale = .current,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [CaptionGrouper.Word] {
        guard await requestAuthorization() else { throw CaptionError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw CaptionError.unavailable }

        progress(0.1)
        let audioURL = try await exportAudio(timeline: timeline)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        progress(0.35)

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.taskHint = .dictation

        let words: [CaptionGrouper.Word] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let words = result.bestTranscription.segments.map {
                        CaptionGrouper.Word(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    continuation.resume(returning: words)
                } else if let error {
                    finished = true
                    let nsError = error as NSError
                    // 1110 = "No speech detected"
                    if nsError.code == 1110 || nsError.code == 203 {
                        continuation.resume(throwing: CaptionError.noSpeech)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        progress(1)
        guard !words.isEmpty else { throw CaptionError.noSpeech }
        return words
    }

    static func captions(for timeline: Timeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [Caption] {
        let words = try await transcribe(timeline: timeline, progress: progress)
        return CaptionGrouper.group(words)
    }

    /// Renders the timeline's audio mix (original audio + music + voice-over) to m4a.
    static func exportAudio(timeline: Timeline) async throws -> URL {
        var tl = timeline
        tl.overlays = []
        let built = try await VideoEngine.build(timeline: tl, options: .preview(for: tl))
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptionError.unavailable
        }
        let url = MediaStore.temporaryFile(extension: "m4a")
        session.outputURL = url
        session.outputFileType = .m4a
        session.audioMix = built.audioMix
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: session.error ?? CaptionService.CaptionError.noSpeech)
                }
            }
        }
        return url
    }
}
