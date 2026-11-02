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

// Learning a noise profile for the Clean up noise effect (issue #312).
//
// The profile is the power of the noise in each frequency bin of the effect's own short-time transform
// (`DenoiseUnit.size` samples, sqrt-Hann window), in dB, rounded to 0.1 dB. Two ways to learn it:
// - Quietest parts: the median spectrum of the quietest 10% of the frames of the clip. The median of a noise bin's
//   power is ln 2 times its mean, so the median is divided by ln 2 to give the mean the unit's gain law expects.
// - Selected range: the mean spectrum of the frames that lie wholly inside the I/O range of the clip.
// The result is stored with the effect (`FxNode.noiseProfile`); learning again is always an explicit action.

public enum NoiseProfile {
    public static let size = DenoiseUnit.size
    public static let bins = DenoiseUnit.size / 2 + 1
    /// The share of frames, quietest first, that the quietest-parts mode learns from.
    public static let quietestShare = 0.1
    /// Frames are taken every half window, which covers every sample twice and keeps long clips cheap.
    static let hop = DenoiseUnit.size / 2
    static let floorDb = -180.0
    /// Mean square below which a frame is digital silence (−120 dBFS).
    static let silentPower = 1e-12

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case tooShort
        case noChannels
        case invalidRange
        /// Every frame is digital silence, so there is no noise to learn.
        case silent
        public var description: String {
            switch self {
            case .tooShort: return "There is not enough audio to learn the noise from. Choose a longer part."
            case .noChannels: return "There is no audio to learn the noise from."
            case .invalidRange: return "The range to learn from is not valid. Set an in point before the out point."
            case .silent: return "This part of the clip is completely silent, so there is no noise to learn. Choose another part."
            }
        }
    }

    /// A span of the clip's own audio, in seconds from its first sample.
    public struct Span: Equatable, Sendable {
        public var start: Double, end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// The part of a clip that the timeline's I/O range covers, in seconds from the clip's start; nil when either point is
    /// missing, the range is empty or it does not touch the clip. A range running past the clip is cut to the clip.
    public static func clipRange(inPoint: Double?, outPoint: Double?, clipStart: Double, clipDuration: Double) -> Span? {
        guard let inPoint, let outPoint, inPoint.isFinite, outPoint.isFinite, clipStart.isFinite, clipDuration.isFinite,
              outPoint > inPoint, clipDuration > 0 else { return nil }
        let start = max(inPoint, clipStart) - clipStart, end = min(outPoint, clipStart + clipDuration) - clipStart
        return end > start ? Span(start: start, end: end) : nil
    }

    /// The median spectrum of the quietest `quietestShare` of the frames of `channels` (one array per channel).
    public static func learnQuietest(_ channels: [[Float]], sampleRate: Double) throws -> [Double] {
        let length = try checked(channels)
        let count = frameCount(length, from: 0, to: length)
        guard count > 0 else { throw Failure.tooShort }
        var energy: [(index: Int, energy: Double)] = []
        energy.reserveCapacity(count)
        for f in 0..<count {
            let start = f * hop
            var sum = 0.0
            for channel in channels { for i in start..<(start + size) { let v = Double(channel[i]); sum += v * v } }
            energy.append((f, sum))
        }
        // Frames of digital silence say nothing about the noise (a gap an editor cut out), so the quietest tenth is taken
        // from the frames that carry any sound at all.
        let sounding = energy.filter { $0.energy / Double(size * channels.count) > silentPower }
        guard !sounding.isEmpty else { throw Failure.silent }
        let ordered = sounding.sorted { $0.energy != $1.energy ? $0.energy < $1.energy : $0.index < $1.index }
        let take = max(1, Int((Double(ordered.count) * quietestShare).rounded(.up)))
        // The median of a bin's power is ln 2 times its mean for noise (an exponential spread), so it is taken per channel
        // and the channels are then averaged.
        var power = [Double](repeating: 0, count: bins)
        let frames = ordered.prefix(take).map { framePowers(channels, start: $0.index * hop) }
        for c in 0..<channels.count {
            for k in 0..<bins {
                let sorted = frames.map { $0[c][k] }.sorted()
                let mid = sorted.count / 2
                let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
                power[k] += median / M_LN2 / Double(channels.count)
            }
        }
        return encode(power)
    }

    /// The mean spectrum of the frames that lie wholly inside `span`.
    public static func learnRange(_ channels: [[Float]], sampleRate: Double, span: Span) throws -> [Double] {
        let length = try checked(channels)
        guard sampleRate.isFinite, sampleRate > 0, span.start.isFinite, span.end.isFinite, span.end > span.start else { throw Failure.invalidRange }
        let from = Int(min(Double(length), max(0, (span.start * sampleRate).rounded())))
        let to = Int(min(Double(length), max(0, (span.end * sampleRate).rounded())))
        let count = frameCount(length, from: from, to: to)
        guard count > 0 else { throw Failure.tooShort }
        var power = [Double](repeating: 0, count: bins)
        for f in 0..<count {
            let p = framePower(channels, start: from + f * hop)
            for k in 0..<bins { power[k] += p[k] }
        }
        return encode(power.map { $0 / Double(count) })
    }

    /// Per-bin power back from the stored dB values.
    static func power(fromDb db: [Double]) -> [Double] { db.map { pow(10, $0 / 10) } }

    /// A stored profile is valid when it has one finite value per bin.
    public static func isValid(_ db: [Double]) -> Bool { db.count == bins && db.allSatisfy { $0.isFinite } }

    private static func encode(_ power: [Double]) -> [Double] {
        power.map { p in
            let db = p > 0 ? 10 * log10(p) : floorDb
            return (max(floorDb, db) * 10).rounded() / 10
        }
    }

    private static func checked(_ channels: [[Float]]) throws -> Int {
        guard let first = channels.first else { throw Failure.noChannels }
        guard channels.allSatisfy({ $0.count == first.count }) else { throw Failure.noChannels }
        return first.count
    }

    /// Frames that start every `hop` samples from `from` and end by `to`.
    private static func frameCount(_ length: Int, from: Int, to: Int) -> Int {
        let end = min(length, to)
        return end - from >= size ? (end - from - size) / hop + 1 : 0
    }

    private static let window: [Double] = (0..<size).map { sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }

    /// The power of the frame at `start` in each channel.
    private static func framePowers(_ channels: [[Float]], start: Int) -> [[Double]] {
        var re = [Double](repeating: 0, count: size), im = [Double](repeating: 0, count: size)
        return channels.map { channel in
            for i in 0..<size { re[i] = Double(channel[start + i]) * window[i]; im[i] = 0 }
            AudioCarve.fft(&re, &im)
            return (0..<bins).map { re[$0] * re[$0] + im[$0] * im[$0] }
        }
    }

    /// The power of the frame at `start`, averaged over the channels.
    private static func framePower(_ channels: [[Float]], start: Int) -> [Double] {
        let perChannel = framePowers(channels, start: start)
        return (0..<bins).map { k in perChannel.reduce(0) { $0 + $1[k] } / Double(channels.count) }
    }
}

extension FxChain {
    /// The chain as export plays it. Listening to the removed noise is a way of checking the sound, never part of it.
    public func forExport() -> FxChain {
        guard nodes.contains(where: { Self.listens($0) }) else { return self }
        var copy = self
        for i in copy.nodes.indices where Self.listens(copy.nodes[i]) {
            copy.nodes[i].paramsA?["listen"] = .string("off")
            copy.nodes[i].paramsB?["listen"] = .string("off")
        }
        return copy
    }

    private static func listens(_ node: FxNode) -> Bool {
        node.type == "denoise" && (node.paramsA?["listen"]?.string == "on" || node.paramsB?["listen"]?.string == "on")
    }
}

extension AudioGraphProject {
    /// The project as the export mix renders it (see `FxChain.forExport`).
    public func forExport() -> AudioGraphProject {
        var out = self
        for i in out.tracks.indices { out.tracks[i].fxChain = out.tracks[i].fxChain?.forExport() }
        for i in out.groups.indices { out.groups[i].fxChain = out.groups[i].fxChain?.forExport() }
        return out
    }
}
