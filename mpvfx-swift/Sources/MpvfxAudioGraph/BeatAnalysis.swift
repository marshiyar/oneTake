//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (c) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
import Foundation

// Beat analysis: find where the beats fall in a piece of audio, for the timeline beat grid.
//
// The method is the usual onset-based one, written here from scratch:
//  1. Onset strength. A mono mix is cut into 1024-sample frames every 512 samples (Hann window). Each frame gets a
//     magnitude spectrum, the magnitudes are log-compressed, and the onset strength of a frame is the sum over bins of
//     how much each bin rose since the previous frame (half-wave rectified spectral flux).
//  2. Onsets. A frame is an onset when it is a local peak and beats an adaptive threshold: the mean plus a multiple of the
//     standard deviation of the surrounding half second, never below a small share of the strongest onset.
//     `sensitivity` lowers both.
//  3. Tempo. The autocorrelation of the onset strength over lags for 60 to 200 BPM, with a mild preference for 100 to 140
//     BPM and a correction for double and half tempo.
//  4. Tracking. Dynamic programming over the frames: every onset scores its strength, and the gap between two chosen
//     beats costs more the further it is from the tempo period. Only beats that sit on a real onset are reported.
//  5. Refinement. A frame is 10.7 ms wide at 48 kHz, so each beat is moved to the attack in the raw samples next to
//     its frame, which puts it well below one frame of error.
//
// The start of the input counts as silence, so a sound that begins at 0 s is an onset at 0 s. Past the end the input
// counts as silence too, so a hit just before the end is found, and nothing is reported after the last sample.
public enum BeatAnalysis {
    /// Analysis frame and step in samples. They do not change with the sample rate (21 ms and 10.7 ms at 48 kHz).
    public static let frameSize = 1024
    public static let hop = 512
    /// The tempos the tracker looks for, in beats per minute.
    public static let tempoRange: ClosedRange<Double> = 60...200
    /// The values `Options.every` may take; any other value is treated as 1.
    public static let everyChoices = [1, 2, 4]

    public struct Options: Equatable, Sendable {
        /// 0...1, higher finds more onsets. Values outside the range are clamped and NaN counts as 0.5.
        public var sensitivity: Double = 0.5
        /// Keep every 1st, 2nd or 4th beat, starting with the first. Any value not in `everyChoices` is treated as 1.
        public var every: Int = 1
        public init(sensitivity: Double = 0.5, every: Int = 1) {
            self.sensitivity = sensitivity
            self.every = every
        }
    }

    public struct Beat: Equatable, Sendable {
        /// Seconds from the start of the input.
        public var time: Double
        /// 0...1, the onset strength relative to the strongest beat found (1 for the strongest).
        public var strength: Double
        public init(time: Double, strength: Double) {
            self.time = time
            self.strength = strength
        }
    }

    // Tuning. The magnitude gain is applied to a signal scaled so its peak is 1.
    static let compression = 100.0
    static let lowestHz = 30.0
    static let silenceFloor = 1e-5
    static let scanChunk = 1 << 18
    static let thresholdSeconds = 0.5
    static let peakRadius = 2
    static let tightness = 20.0
    static let attackBlock = 32
    static let attackLead = 64
    static let attackTail = 256
    static let attackFraction = 0.1

    static let window: [Double] = (0..<frameSize).map { (i: Int) -> Double in
        0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(frameSize))
    }
    static let windowSum: Double = window.reduce(0, +)

    static func clampedSensitivity(_ value: Double) -> Double { value.isNaN ? 0.5 : min(1, max(0, value)) }
    static func validEvery(_ value: Int) -> Int { everyChoices.contains(value) ? value : 1 }

    /// Average of the channels. A channel shorter than the longest counts as silent after its end.
    public static func monoMix(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        let length = channels.reduce(0) { max($0, $1.count) }
        var mix = [Float](repeating: 0, count: length)
        for channel in channels {
            channel.withUnsafeBufferPointer { src in
                mix.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<src.count { dst[i] += src[i] }
                }
            }
        }
        let scale = 1 / Float(channels.count)
        mix.withUnsafeMutableBufferPointer { dst in
            for i in 0..<dst.count { dst[i] *= scale }
        }
        return mix
    }

    /// Beats of a mono signal, sorted by time. Returns nil when `isCancelled` turns true (it is polled at least once per
    /// 64 frames and in every later loop), and [] for input that is empty, silent, shorter than one frame, has no clear
    /// tempo, or has a sample rate that is not positive. `progress` gets increasing values from 0 to 1.
    public static func analyse(_ mono: [Float], sampleRate: Double, options: Options = .init(),
                               isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) -> [Beat]? {
        if isCancelled() { return nil }
        progress(0)
        guard sampleRate.isFinite, sampleRate > 0, mono.count >= frameSize else { progress(1); return [] }
        let hopSeconds = Double(hop) / sampleRate

        guard let envelope = onsetStrengthCore(mono, sampleRate: sampleRate, isCancelled: isCancelled,
                                               progress: { progress($0 * 0.7) }) else { return nil }
        progress(0.7)
        guard envelope.contains(where: { $0 > 0 }) else { progress(1); return [] }

        let tempo = estimateTempo(onsetEnvelope: envelope, hopSeconds: hopSeconds, isCancelled: isCancelled)
        if isCancelled() { return nil }
        progress(0.75)
        guard let bpm = tempo else { progress(1); return [] }

        guard let onsets = pickOnsets(envelope, hopSeconds: hopSeconds, sensitivity: options.sensitivity,
                                      isCancelled: isCancelled) else { return nil }
        progress(0.8)
        guard let frames = track(onsets: onsets, period: 60 / (bpm * hopSeconds), isCancelled: isCancelled) else { return nil }
        progress(0.9)

        var strongest = 0.0
        for frame in frames { strongest = max(strongest, onsets[frame]) }
        var beats: [Beat] = []
        beats.reserveCapacity(frames.count)
        for (i, frame) in frames.enumerated() {
            if i % 32 == 0 && isCancelled() { return nil }
            let sample = attackSample(mono, aroundFrame: frame)
            beats.append(Beat(time: Double(sample) / sampleRate, strength: min(1, onsets[frame] / strongest)))
            progress(0.9 + 0.09 * Double(i + 1) / Double(frames.count))
        }
        beats.sort { $0.time < $1.time }

        let step = validEvery(options.every)
        if step > 1 {
            let all = beats
            beats = stride(from: 0, to: all.count, by: step).map { all[$0] }
        }
        progress(1)
        return beats
    }

    // MARK: Stage 1: onset strength

    /// One value per hop. Frame k is centred on sample k * hop (zero padded at both ends), so there are
    /// ceil(count / hop) + 1 values and value 0 is measured against silence.
    static func onsetStrength(_ mono: [Float], sampleRate: Double) -> [Double] {
        onsetStrengthCore(mono, sampleRate: sampleRate, isCancelled: { false }, progress: { _ in }) ?? []
    }

    static func onsetStrengthCore(_ mono: [Float], sampleRate: Double, isCancelled: () -> Bool,
                                  progress: (Double) -> Void) -> [Double]? {
        let n = mono.count
        guard n > 0, sampleRate.isFinite, sampleRate > 0 else { return [] }
        let frames = (n + hop - 1) / hop + 1
        var envelope = [Double](repeating: 0, count: frames)

        // Scale so the loudest sample is 1, which keeps the log compression the same for quiet and loud input.
        var peak = 0.0
        var from = 0
        while from < n {
            let to = min(n, from + scanChunk)
            for i in from..<to {
                let a = Double(abs(mono[i]))
                if a.isFinite && a > peak { peak = a }
            }
            if isCancelled() { return nil }
            from = to
        }
        guard peak > silenceFloor else { return envelope }

        // Skip the DC bin and anything under about 30 Hz.
        let binHz = sampleRate / Double(frameSize)
        let lowBin = max(1, Int((lowestHz / binHz).rounded(.up)))
        let highBin = frameSize / 2
        guard lowBin <= highBin else { return envelope }

        // Two real frames share one complex FFT (one in the real part, one in the imaginary part), which halves the
        // transforms. Both spectra are then read back from the mirrored bins. The 0.5 is that read-back factor.
        let gain = 0.5 * compression / (peak * windowSum)
        var re = [Double](repeating: 0, count: frameSize)
        var im = [Double](repeating: 0, count: frameSize)
        var previous = [Double](repeating: 0, count: highBin + 1)
        var k = 0
        while k < frames {
            if k % 64 == 0 {
                if isCancelled() { return nil }
                progress(Double(k) / Double(frames))
            }
            loadFrame(mono, frame: k, into: &re)
            loadFrame(mono, frame: k + 1, into: &im)
            AudioCarve.fft(&re, &im)
            var fluxA = 0.0, fluxB = 0.0
            for bin in lowBin...highBin {
                let mirror = frameSize - bin
                let zr = re[bin], zi = im[bin], wr = re[mirror], wi = im[mirror]
                let ar = zr + wr, ai = zi - wi
                let br = zi + wi, bi = zr - wr
                let logA = log1p(gain * (ar * ar + ai * ai).squareRoot())
                let logB = log1p(gain * (br * br + bi * bi).squareRoot())
                let riseA = logA - previous[bin]
                if riseA > 0 { fluxA += riseA }
                let riseB = logB - logA
                if riseB > 0 { fluxB += riseB }
                previous[bin] = logB
            }
            envelope[k] = fluxA
            if k + 1 < frames { envelope[k + 1] = fluxB }
            k += 2
        }

        // A sound that is already playing at the first sample would otherwise show a huge onset there. Cap it at the
        // strongest of the rest, so it counts as an ordinary onset.
        if frames > 1 {
            var rest = 0.0
            for i in 1..<frames { rest = max(rest, envelope[i]) }
            envelope[0] = min(envelope[0], rest)
        }
        return envelope
    }

    /// Windowed samples of frame `frame` (centred on frame * hop) into `buffer`; zero where the frame is outside the input.
    static func loadFrame(_ mono: [Float], frame: Int, into buffer: inout [Double]) {
        let shape = window
        for i in 0..<frameSize { buffer[i] = 0 }
        let start = frame * hop - frameSize / 2
        let lo = max(0, -start), hi = min(frameSize, mono.count - start)
        if lo < hi {
            for i in lo..<hi {
                let value = Double(mono[start + i])
                if value.isFinite { buffer[i] = value * shape[i] }
            }
        }
    }

    // MARK: Stage 2: onsets

    /// The onset strength kept only at onsets (local peaks over the adaptive threshold), zero elsewhere, scaled so the
    /// average kept value is 1. A higher `sensitivity` lowers the threshold, so it never removes an onset by itself.
    static func pickOnsets(_ envelope: [Double], hopSeconds: Double, sensitivity: Double,
                           isCancelled: () -> Bool) -> [Double]? {
        let n = envelope.count
        var onsets = [Double](repeating: 0, count: n)
        guard n > 0, hopSeconds > 0 else { return onsets }
        var strongest = 0.0
        for value in envelope where value > strongest { strongest = value }
        guard strongest > 0 else { return onsets }

        let s = clampedSensitivity(sensitivity)
        let spread = 2.8 - 2.4 * s
        let floorLevel = (0.2 - 0.18 * s) * strongest
        let half = max(2, Int((thresholdSeconds / hopSeconds).rounded()))
        var sum = [Double](repeating: 0, count: n + 1)
        var squares = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            sum[i + 1] = sum[i] + envelope[i]
            squares[i + 1] = squares[i] + envelope[i] * envelope[i]
        }
        for k in 0..<n {
            if k % 1024 == 0 && isCancelled() { return nil }
            let value = envelope[k]
            if value <= floorLevel { continue }
            let a = max(0, k - half), b = min(n, k + half + 1)
            let count = Double(b - a)
            let mean = (sum[b] - sum[a]) / count
            let variance = max(0, (squares[b] - squares[a]) / count - mean * mean)
            if value <= mean + spread * variance.squareRoot() { continue }
            // A local peak: strictly above the frames before it, at least as high as the frames after it.
            var isPeak = true
            for j in max(0, k - peakRadius)...min(n - 1, k + peakRadius) where j != k {
                let higher = j < k ? envelope[j] >= value : envelope[j] > value
                if higher { isPeak = false; break }
            }
            if isPeak { onsets[k] = value }
        }
        var total = 0.0, kept = 0
        for value in onsets where value > 0 { total += value; kept += 1 }
        if kept > 0 {
            let mean = total / Double(kept)
            for i in 0..<n where onsets[i] > 0 { onsets[i] /= mean }
        }
        return onsets
    }

    // MARK: Stage 3: tempo

    /// How much a tempo is liked: 1 from 100 to 140 BPM, falling off gently outside (0.65 at 60, 0.8 at 200).
    static func tempoPreference(_ bpm: Double) -> Double {
        let octaves: Double
        if bpm < 100 { octaves = log2(100 / bpm) } else if bpm > 140 { octaves = log2(bpm / 140) } else { return 1 }
        let z = octaves / 0.8
        return exp(-0.5 * z * z)
    }

    /// Tempo in beats per minute (inside `tempoRange`) from the autocorrelation of the onset strength, or nil when the
    /// envelope is flat or too short for a lag of at least 60 BPM. The peak is picked with the tempo preference, then a
    /// slow answer (under 90 BPM) moves to double and a fast one (over 160 BPM) to half when that tempo's peak is nearly
    /// as strong. The result is refined between lags with a parabola.
    static func estimateTempo(onsetEnvelope envelope: [Double], hopSeconds: Double,
                              isCancelled: () -> Bool = { false }) -> Double? {
        let n = envelope.count
        guard n >= 8, hopSeconds.isFinite, hopSeconds > 0 else { return nil }
        var mean = 0.0
        for value in envelope { mean += value }
        mean /= Double(n)
        let x = envelope.map { $0 - mean }
        var energy = 0.0
        for value in x { energy += value * value }
        guard energy > 1e-12 else { return nil }

        let lagLow = max(2, Int((60 / (tempoRange.upperBound * hopSeconds)).rounded(.down)))
        let lagHigh = min(Int((60 / (tempoRange.lowerBound * hopSeconds)).rounded(.up)), n / 2)
        guard lagHigh >= lagLow + 3 else { return nil }

        // Autocorrelation, per overlapping sample, for the lags plus one either side for the parabola.
        var r = [Double](repeating: 0, count: lagHigh + 2)
        for lag in (lagLow - 1)...(lagHigh + 1) {
            if isCancelled() { return nil }
            var sum = 0.0
            x.withUnsafeBufferPointer { p in
                var i = 0
                while i + lag < n { sum += p[i] * p[i + lag]; i += 1 }
            }
            r[lag] = sum / Double(n - lag)
        }
        func bpm(_ lag: Double) -> Double { 60 / (lag * hopSeconds) }

        var lag = -1
        var bestScore = 0.0
        for candidate in lagLow...lagHigh where r[candidate] > 0 && r[candidate] > r[candidate - 1] && r[candidate] >= r[candidate + 1] {
            let score = r[candidate] * tempoPreference(bpm(Double(candidate)))
            if score > bestScore { bestScore = score; lag = candidate }
        }
        guard lag > 0 else { return nil }

        // The strongest lag within one of `centre`, if that is inside the lag range.
        func strongest(near centre: Int) -> Int? {
            let a = max(lagLow, centre - 1), b = min(lagHigh, centre + 1)
            if a > b { return nil }
            var found = a
            for candidate in a...b where r[candidate] > r[found] { found = candidate }
            return found
        }
        let found = bpm(Double(lag))
        if found < 90, let half = strongest(near: (lag + 1) / 2), r[half] >= 0.8 * r[lag] {
            lag = half
        } else if found > 160, let twice = strongest(near: lag * 2), r[twice] >= 0.8 * r[lag] {
            lag = twice
        }

        var offset = 0.0
        let curve = r[lag - 1] - 2 * r[lag] + r[lag + 1]
        if curve < 0 { offset = max(-0.5, min(0.5, 0.5 * (r[lag - 1] - r[lag + 1]) / curve)) }
        return bpm(Double(lag) + offset)
    }

    // MARK: Stage 4: tracking

    /// Frames of the beats: the best chain of onsets whose gaps stay near `period` (in frames). Every onset in a chain
    /// adds its strength, and a gap g costs `tightness * ln(g / period)^2`, so a chain may stretch or squeeze a little
    /// but does not take off-grid onsets. Gaps under half or over twice the period are not allowed. Frames without an
    /// onset can bridge a gap but are not returned. Returns nil when cancelled.
    static func track(onsets: [Double], period: Double, isCancelled: () -> Bool = { false }) -> [Int]? {
        let n = onsets.count
        guard n > 0, period.isFinite, period >= 2 else { return [] }
        let minGap = max(1, Int((period / 2).rounded(.up)))
        let maxGap = Int((period * 2).rounded(.down))
        guard minGap <= maxGap else { return [] }
        var cost = [Double](repeating: 0, count: maxGap + 1)
        for gap in minGap...maxGap {
            let r = log(Double(gap) / period)
            cost[gap] = tightness * r * r
        }

        var score = [Double](repeating: 0, count: n)
        var before = [Int](repeating: -1, count: n)
        for t in 0..<n {
            if t % 256 == 0 && isCancelled() { return nil }
            var best = 0.0, from = -1
            let lowest = max(0, t - maxGap), highest = t - minGap
            if lowest <= highest {
                for p in lowest...highest {
                    let value = score[p] - cost[t - p]
                    if value > best { best = value; from = p }
                }
            }
            score[t] = onsets[t] + best
            before[t] = from
        }

        var end = 0
        for t in 0..<n where score[t] > score[end] { end = t }
        if score[end] <= 0 { return [] }
        var chain: [Int] = []
        var cursor = end
        while cursor >= 0 {
            chain.append(cursor)
            cursor = before[cursor]
        }
        return chain.reversed().filter { onsets[$0] > 0 }
    }

    // MARK: Stage 5: refinement

    /// The sample where the attack begins near a beat frame. Looks from just before the frame's first half to a little
    /// after its last, takes the energy of 32-sample blocks, and returns the start of the first block with at least a
    /// tenth of the largest block's energy. That is within a block or two of the true start of a hit, far below a hop.
    static func attackSample(_ mono: [Float], aroundFrame frame: Int) -> Int {
        let n = mono.count
        guard n > 0 else { return 0 }
        let centre = frame * hop
        let start = max(0, centre - hop - attackLead)
        let end = min(n, centre + hop + attackTail)
        let blocks = (end - start) / attackBlock
        guard blocks > 0 else { return min(max(centre, 0), n - 1) }
        var energy = [Double](repeating: 0, count: blocks)
        var largest = 0.0
        for j in 0..<blocks {
            var e = 0.0
            let first = start + j * attackBlock
            for i in first..<(first + attackBlock) {
                let value = Double(mono[i])
                if value.isFinite { e += value * value }
            }
            energy[j] = e
            largest = max(largest, e)
        }
        guard largest > 0 else { return min(max(centre, 0), n - 1) }
        let limit = attackFraction * largest
        for j in 0..<blocks where energy[j] >= limit { return start + j * attackBlock }
        return min(max(centre, 0), n - 1)
    }
}
