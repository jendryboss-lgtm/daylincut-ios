import Foundation

// MARK: - OnsetDetector

/// Energy-flux onset detection plus autocorrelation tempo estimation.
///
/// This runs on mono PCM samples (the `AudioAnalyzer` reads them with
/// `AVAssetReader`). It is pure Swift so it can be unit tested with synthetic signals.
struct OnsetDetector: Sendable {
    struct Result: Hashable, Sendable {
        var onsets: [Double]
        var beats: [Double]
        var bpm: Double?
        var duration: Double
    }

    var frameSize: Int = 1024
    var hopSize: Int = 512

    func analyze(samples: [Float], sampleRate: Double, sensitivity: Double = 0.5) -> Result {
        let duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        guard samples.count >= frameSize, sampleRate > 0 else {
            return Result(onsets: [], beats: [], bpm: nil, duration: duration)
        }
        let hopTime = Double(hopSize) / sampleRate

        // 1. Log-compressed RMS energy per frame.
        var energy: [Double] = []
        energy.reserveCapacity(samples.count / hopSize + 1)
        var i = 0
        while i + frameSize <= samples.count {
            var sum: Double = 0
            for j in i..<(i + frameSize) {
                let s = Double(samples[j])
                sum += s * s
            }
            let rms = (sum / Double(frameSize)).squareRoot()
            energy.append(log(1 + 100 * rms))
            i += hopSize
        }

        // 2. Half-wave rectified energy flux.
        var flux = [Double](repeating: 0, count: energy.count)
        for n in 1..<max(1, energy.count) {
            flux[n] = max(0, energy[n] - energy[n - 1])
        }

        // 3. Adaptive threshold peak picking.
        let s = max(0, min(1, sensitivity))
        let k = 2.2 - 1.7 * s
        let window = max(4, Int(0.5 / hopTime))
        let minGap = max(1, Int((0.28 - 0.18 * s) / hopTime))
        let globalMax = flux.max() ?? 0
        var onsets: [Double] = []
        var lastPeak = -minGap
        if globalMax > 0 {
            for n in flux.indices {
                let lo = max(0, n - window), hi = min(flux.count - 1, n + window)
                var mean = 0.0
                for m in lo...hi { mean += flux[m] }
                mean /= Double(hi - lo + 1)
                var variance = 0.0
                for m in lo...hi { variance += (flux[m] - mean) * (flux[m] - mean) }
                let std = (variance / Double(hi - lo + 1)).squareRoot()
                let threshold = mean + k * std
                guard flux[n] > threshold, flux[n] > globalMax * 0.08 else { continue }
                let localLo = max(0, n - 3), localHi = min(flux.count - 1, n + 3)
                var isMax = true
                for m in localLo...localHi where flux[m] > flux[n] { isMax = false; break }
                if isMax && n - lastPeak >= minGap {
                    onsets.append(Double(n) * hopTime)
                    lastPeak = n
                }
            }
        }

        // 4. Tempo via autocorrelation of the flux envelope (60...180 BPM).
        let (bpm, period) = estimateTempo(flux: flux, hopTime: hopTime)
        var beats: [Double] = onsets
        if let period, period > 0 {
            let lag = period / hopTime
            // Choose the grid phase that collects the most flux.
            var bestPhase = 0.0
            var bestScore = -1.0
            let steps = max(1, Int(lag.rounded()))
            for p in 0..<steps {
                var score = 0.0
                var pos = Double(p)
                while Int(pos) < flux.count {
                    score += flux[Int(pos)]
                    pos += lag
                }
                if score > bestScore { bestScore = score; bestPhase = Double(p) * hopTime }
            }
            var grid: [Double] = []
            var t = bestPhase
            while t < duration {
                grid.append(t)
                t += period
            }
            beats = grid
        }
        return Result(onsets: onsets, beats: beats, bpm: bpm, duration: duration)
    }

    private func estimateTempo(flux: [Double], hopTime: Double) -> (Double?, Double?) {
        guard flux.count > 16 else { return (nil, nil) }
        let mean = flux.reduce(0, +) / Double(flux.count)
        let centered = flux.map { $0 - mean }
        let minLag = max(1, Int((60.0 / 180.0) / hopTime))
        let maxLag = min(centered.count - 1, Int((60.0 / 60.0) / hopTime))
        guard maxLag > minLag else { return (nil, nil) }
        var zero = 0.0
        for v in centered { zero += v * v }
        guard zero > 0 else { return (nil, nil) }
        var bestLag = 0
        var best = 0.0
        for lag in minLag...maxLag {
            var acc = 0.0
            var n = 0
            while n + lag < centered.count {
                acc += centered[n] * centered[n + lag]
                n += 1
            }
            // Mild preference for tempos around 120 BPM.
            let bpm = 60.0 / (Double(lag) * hopTime)
            let weight = exp(-pow(log2(bpm / 120.0), 2) / 2)
            let score = acc / zero * (0.6 + 0.4 * weight)
            if score > best { best = score; bestLag = lag }
        }
        guard bestLag > 0, best > 0.08 else { return (nil, nil) }
        let period = Double(bestLag) * hopTime
        return (60.0 / period, period)
    }
}

// MARK: - SceneChangeDetector

/// Detects hard scene changes from per-frame colour histograms.
struct SceneChangeDetector: Sendable {
    struct Frame: Hashable, Sendable {
        var time: Double
        /// Normalised histogram (sums to 1).
        var histogram: [Double]
        /// Mean luminance 0...1.
        var luma: Double
    }

    /// Returns detected scenes with an interest score based on motion and exposure.
    func scenes(frames: [Frame], duration: Double, sensitivity: Double = 0.5, minSceneLength: Double = 0.6) -> [SceneRange] {
        guard duration > 0 else { return [] }
        guard frames.count > 1 else { return [SceneRange(start: 0, end: duration, score: 0.5)] }
        var distances: [Double] = [0]
        for (a, b) in zip(frames, frames.dropFirst()) {
            distances.append(Self.distance(a.histogram, b.histogram))
        }
        let mean = distances.reduce(0, +) / Double(distances.count)
        let variance = distances.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(distances.count)
        let std = variance.squareRoot()
        let s = max(0, min(1, sensitivity))
        let k = 2.6 - 1.8 * s
        let absoluteFloor = 0.35 - 0.25 * s
        var cuts: [Double] = []
        for i in 1..<frames.count {
            let d = distances[i]
            if d > mean + k * std && d > absoluteFloor {
                let t = frames[i].time
                if t - (cuts.last ?? 0) >= minSceneLength && duration - t >= minSceneLength * 0.5 {
                    cuts.append(t)
                }
            }
        }
        let bounds = [0] + cuts + [duration]
        var result: [SceneRange] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) where end - start > 0.05 {
            let inside = frames.indices.filter { frames[$0].time >= start && frames[$0].time < end }
            let motion = inside.isEmpty ? 0 : inside.map { $0 == 0 ? 0 : min(1, distances[$0] * 4) }.reduce(0, +) / Double(inside.count)
            let luma = inside.isEmpty ? 0.5 : inside.map { frames[$0].luma }.reduce(0, +) / Double(inside.count)
            // Penalise very dark or blown-out scenes.
            let exposure = 1 - min(1, abs(luma - 0.5) * 2)
            let lengthBonus = min(1, (end - start) / 3)
            let score = 0.45 * motion + 0.35 * exposure + 0.2 * lengthBonus
            result.append(SceneRange(start: start, end: end, score: score))
        }
        return result
    }

    /// Half L1 distance between two normalised histograms (0 = identical, 1 = disjoint).
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d = 0.0
        for i in a.indices { d += abs(a[i] - b[i]) }
        return d / 2
    }
}
