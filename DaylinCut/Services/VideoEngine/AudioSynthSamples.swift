import Foundation

// MARK: - AudioSynth

/// Procedural beat generator used for AutoCut when no music is provided, for the
/// local "AI music" mock, and for unit tests of the onset detector.
enum AudioSynth {

    struct Beat: Sendable {
        var fileName: String
        var duration: Double
        var bpm: Double
        var beats: [Double]
    }

    /// Generates PCM samples of a simple drum + bass loop.
    static func beatSamples(bpm: Double, duration: Double, sampleRate: Double = 44100, energy: Double = 1) -> (samples: [Float], beats: [Double]) {
        let count = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: max(0, count))
        let beat = 60 / bpm
        var beats: [Double] = []
        var t = 0.0
        var rng = SystemRandomNumberGenerator()
        let bassNotes: [Double] = [55, 55, 65.4, 49]
        var index = 0
        while t < duration {
            beats.append(t)
            let start = Int(t * sampleRate)
            // Kick on every beat: pitch-swept sine with exponential decay.
            let kickLen = Int(0.25 * sampleRate)
            for i in 0..<kickLen where start + i < count {
                let x = Double(i) / sampleRate
                let freq = 50 + 110 * exp(-x * 30)
                let v = sin(2 * .pi * freq * x) * exp(-x * 14) * 0.9 * energy
                out[start + i] += Float(v)
            }
            // Hi-hat on the off-beat.
            let hatStart = Int((t + beat / 2) * sampleRate)
            let hatLen = Int(0.05 * sampleRate)
            for i in 0..<hatLen where hatStart + i < count {
                let x = Double(i) / sampleRate
                let noise = Double.random(in: -1...1, using: &rng)
                out[hatStart + i] += Float(noise * exp(-x * 80) * 0.18 * energy)
            }
            // Snare-ish clap on beats 2 and 4.
            if index % 2 == 1 {
                let len = Int(0.12 * sampleRate)
                for i in 0..<len where start + i < count {
                    let x = Double(i) / sampleRate
                    let noise = Double.random(in: -1...1, using: &rng)
                    out[start + i] += Float(noise * exp(-x * 30) * 0.35 * energy)
                }
            }
            // Bass pad for the whole beat.
            let note = bassNotes[(index / 4) % bassNotes.count]
            let padLen = Int(beat * sampleRate)
            for i in 0..<padLen where start + i < count {
                let x = Double(i) / sampleRate
                out[start + i] += Float(sin(2 * .pi * note * x) * 0.12 * (1 - x / beat))
            }
            index += 1
            t += beat
        }
        // Soft clip.
        for i in out.indices { out[i] = tanhf(out[i]) }
        return (out, beats)
    }
}
