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

// Clip gain (clampAudioGain), the media volume envelope
// (normaliseEnvelope), the envelope walker (createEnvelopeWalker)
// and the volume lane keyframes the mixer reads (volumeLaneKeyframes).

public struct VolumeKeyframe: Equatable, Sendable {
    public var time: Double
    public var volume: Double
    public init(time: Double, volume: Double) { self.time = time; self.volume = volume }
}

public enum VolumeEnvelope {
    public static func clampAudioGain(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return max(0, min(AudioAutomation.maxAudioGain, value))
    }

    public static func normalise(_ keyframes: [VolumeKeyframe], trackStart: Double, baseVolume: Double) -> [VolumeKeyframe] {
        let points = keyframes.filter { $0.time.isFinite && $0.volume.isFinite }
            .map { VolumeKeyframe(time: max(0, $0.time - trackStart), volume: clampAudioGain($0.volume)) }
            .enumerated().sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }.map(\.element)
        var deduped: [VolumeKeyframe] = []
        for p in points {
            if let prev = deduped.last, abs(prev.time - p.time) < 1e-9 { deduped[deduped.count - 1].volume = p.volume } else { deduped.append(p) }
        }
        if deduped.isEmpty { return deduped }
        if deduped[0].time > 0 { deduped.insert(VolumeKeyframe(time: 0, volume: clampAudioGain(baseVolume)), at: 0) }
        return deduped
    }

    /// Forward-only gain lookup. Times passed in must be non-decreasing.
    public struct Walker: Sendable {
        let envelope: [VolumeKeyframe]
        var segment = 0
        public mutating func gain(at time: Double) -> Double {
            while true {
                if segment >= envelope.count - 2 || segment + 1 >= envelope.count || time < envelope[segment + 1].time { break }
                segment += 1
            }
            let a = envelope[segment]
            let b = segment + 1 < envelope.count ? envelope[segment + 1] : a
            let span = b.time - a.time
            let progress = span <= 0 ? 0 : min(1, max(0, (time - a.time) / span))
            return a.volume + (b.volume - a.volume) * progress
        }
    }

    public static func walker(_ keyframes: [VolumeKeyframe], trackStart: Double, baseVolume: Double) -> Walker? {
        let env = normalise(keyframes, trackStart: trackStart, baseVolume: baseVolume)
        return env.isEmpty ? nil : Walker(envelope: env)
    }

    static let curvedSegmentSamplesPerSec = 30.0

    /// `volumeLaneKeyframes`: a volume lane as composition-time keyframes for the PCM baker.
    public static func laneKeyframes(_ automation: Automation, trackStart: Double, duration: Double) -> [VolumeKeyframe]? {
        guard let lane = automation.lanes.first(where: { $0.target == AudioAutomation.volumeTarget }), !lane.points.isEmpty else { return nil }
        var out: [VolumeKeyframe] = []
        func push(_ t: Double, _ v: Double) { out.append(VolumeKeyframe(time: trackStart + t, volume: v)) }
        let first = lane.points[0]
        if first.t > 0 { push(0, first.v) }
        for i in 0..<lane.points.count {
            let a = lane.points[i]
            push(a.t, a.v)
            guard i + 1 < lane.points.count, let curve = a.curve, curve != 0 else { continue }
            let b = lane.points[i + 1]
            let steps = max(2, Int(((b.t - a.t) * curvedSegmentSamplesPerSec).rounded(.up)))
            for k in 1..<steps {
                let t = a.t + ((b.t - a.t) * Double(k)) / Double(steps)
                push(t, AudioAutomation.sampleLane(lane, t))
            }
        }
        let last = lane.points[lane.points.count - 1]
        if duration > last.t { push(duration, last.v) }
        return out
    }
}
