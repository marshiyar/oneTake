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

/// A clip as the mixer sees it (timeline seconds).
public struct AudioClip: Equatable, Sendable {
    public var id: String, source: String, start: Double, end: Double, sourceIn: Double
    public var rate: Double, gain: Double, muted: Bool
    public init(id: String, source: String, start: Double, end: Double, sourceIn: Double = 0, rate: Double = 1, gain: Double = 1, muted: Bool = false) {
        self.id = id; self.source = source; self.start = start; self.end = end; self.sourceIn = sourceIn
        self.rate = rate > 0 ? rate : 1; self.gain = gain; self.muted = muted
    }
    public func sourceTime(at t: Double) -> Double { sourceIn + (t - start) * rate }
}

/// Source of decoded PCM for a clip from a timeline time (synthetic readers in tests; the app plays the bus/FX graph,
/// `GraphAudioSource`, whose stems the media engine decodes).
public protocol AudioClipReader: AnyObject { func read(frames: Int) -> [Float] }

/// Mixes active clips into consecutive blocks starting at a timeline time. Keeps one reader per clip and
/// opens it lazily at the clip's correct source time when the clip becomes active.
public final class AudioMixer {
    public let format: AudioFormat
    public var clips: [AudioClip]
    public var masterGain = 1.0
    public var muted = false
    public private(set) var time: Double
    let open: (AudioClip, Double) -> AudioClipReader?
    var readers: [String: AudioClipReader] = [:]

    public init(format: AudioFormat = .standard, clips: [AudioClip], time: Double, open: @escaping (AudioClip, Double) -> AudioClipReader?) {
        self.format = format; self.clips = clips; self.time = time; self.open = open
    }

    public func seek(_ t: Double) { time = t; readers.removeAll() }

    /// Next `frames` frames of mix, advancing `time`.
    public func render(frames: Int) -> [Float] {
        let ch = format.channels, sr = Double(format.sampleRate)
        var mix = [Float](repeating: 0, count: frames * ch)
        let t0 = time, t1 = time + Double(frames) / sr
        for clip in clips where clip.start < t1 && clip.end > t0 {
            let from = max(0, Int(((clip.start - t0) * sr).rounded()))
            let to = min(frames, Int(((clip.end - t0) * sr).rounded()))
            guard to > from else { continue }
            let reader: AudioClipReader
            if let r = readers[clip.id] { reader = r }
            else { guard let r = open(clip, clip.sourceTime(at: t0 + Double(from) / sr)) else { continue }; readers[clip.id] = r; reader = r }
            let pcm = reader.read(frames: to - from)
            guard !clip.muted else { continue }
            let g = Float(clip.gain)
            for i in 0..<min(pcm.count, (to - from) * ch) { mix[from * ch + i] += pcm[i] * g }
        }
        for id in readers.keys where !clips.contains(where: { $0.id == id && $0.end > t1 }) { readers[id] = nil }
        time = t1
        let g: Float = muted ? 0 : Float(masterGain)
        if g != 1 { for i in mix.indices { mix[i] *= g } }
        for i in mix.indices { mix[i] = max(-1, min(1, mix[i])) }
        return mix
    }
}
