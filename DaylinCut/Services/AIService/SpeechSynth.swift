import AVFoundation
import Foundation

// MARK: - SpeechSynth

/// Text-to-speech to an audio file (used by AI avatar and AI story maker).
/// Keep the instance alive until `synthesize` returns.
final class SpeechSynth: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func synthesize(_ text: String, voiceIdentifier: String? = nil, rate: Float = 0.5) async throws -> (fileName: String, duration: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VideoEngineError.writerFailed("Nothing to say") }
        let utterance = AVSpeechUtterance(string: trimmed)
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = rate
        let target = MediaStore.newFile(extension: "caf")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); self.continuation = continuation; lock.unlock()
            synthesizer.write(utterance) { [weak self] buffer in
                guard let self else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    self.finish(nil)
                    return
                }
                do {
                    if self.file == nil {
                        self.file = try AVAudioFile(forWriting: target.url, settings: pcm.format.settings,
                                                    commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                    }
                    try self.file?.write(from: pcm)
                } catch {
                    self.finish(error)
                }
            }
        }
        guard FileManager.default.fileExists(atPath: target.url.path) else {
            throw VideoEngineError.writerFailed("Speech synthesis produced no audio")
        }
        let info = try await MediaProbe.probe(target.url)
        return (target.name, info.duration)
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        file = nil // closes the file
        lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(nil)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(VideoEngineError.cancelled)
    }

    static var voices: [AVSpeechSynthesisVoice] {
        let lang = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices()
        let local = all.filter { $0.language.hasPrefix(lang) }
        return local.isEmpty ? all.filter { $0.language.hasPrefix("en") } : local
    }
}
