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
import OneTakeMedia
import MpvfxShared

/// A stem the media engine refuses: the user-facing reason from the probe (a later format), shown as the clip's
/// audio issue while the clip plays silent.
public struct StemDecodeError: Error, Equatable, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Decodes clip audio with the media engine's `AudioSampleReader` (WAV, FLAC, LPCM or FLAC in MOV/MP4) into the
/// stereo planes `AudioGraphTrack` holds.
public enum StemDecoder {
    /// Frames pulled from the engine per read: the interleaved scratch buffer stays at 256 KiB however long the clip.
    public static let chunkFrames = 1 << 15

    /// The clip's audio from `key.sourceIn`, at `sampleRate`, stereo, `key.duration` timeline seconds long (shorter
    /// when the source ends first). `key.rate` is the clip speed: with `key.preservesPitch` it is applied as
    /// pitch-preserving tempo (0.25 ... 4); without, the source is resampled to `sampleRate / rate` and played at
    /// `sampleRate`, so the pitch rises and falls with the speed.
    /// A file without an audio track decodes to an empty stem: the clip adds silence, like a muted one.
    public static func decode(_ key: DocumentAudioGraph.StemKey, sampleRate: Int) throws -> [[Float]] {
        let probe = try MediaProbe.probe(path: key.path)
        guard let audio = probe.audio else { return [[], []] }
        guard audio.decodable else { throw StemDecodeError(audio.reason ?? "This file's audio cannot be decoded.") }
        if let ramp = key.speedRamp, ramp.isSupported {
            return try decodeRamp(key, ramp: ramp, sampleRate: sampleRate)
        }
        let sped = abs(key.rate - 1) > 1e-9
        let reader: AudioSampleReader
        if sped && !key.preservesPitch {
            reader = try AudioSampleReader(path: key.path, sampleRate: try resampledRate(sampleRate, key.rate), channels: 2)
        } else {
            reader = try AudioSampleReader(path: key.path, sampleRate: sampleRate, channels: 2)
            // Tempo before seek: the engine converts the frames it drops after a seek at the tempo in force.
            if sped { try reader.setTempo(key.rate) }
        }
        try reader.seek(to: max(0, key.sourceIn))
        let want = max(0, Int((key.duration * Double(sampleRate)).rounded(.up)))
        var left = [Float](), right = [Float]()
        left.reserveCapacity(want); right.reserveCapacity(want)
        while left.count < want {
            let chunk = try reader.read(frames: min(chunkFrames, want - left.count))
            if chunk.isEmpty { break }
            chunk.withUnsafeBufferPointer { p in
                for i in 0..<(p.count / 2) { left.append(p[2 * i]); right.append(p[2 * i + 1]) }
            }
        }
        return [left, right]
    }

    /// The pitch-keeping stretcher runs from 0.25x to 4x; a ramp speed outside that plays at the nearest limit.
    private static func tempo(_ speed: Double) -> Double { min(4, max(0.25, speed)) }

    private static func decodeRamp(_ key: DocumentAudioGraph.StemKey, ramp: NativeSpeedRamp, sampleRate: Int) throws -> [[Float]] {
        let outputCount = max(0, Int((key.duration * Double(sampleRate)).rounded(.up)))
        let reader = try AudioSampleReader(path: key.path, sampleRate: sampleRate, channels: 2)
        if key.preservesPitch {
            // The first chunk must already run at the ramp's opening speed, so the tempo is set before the seek.
            try reader.setTempo(Self.tempo(ramp.speed(atClipFrame: 0)))
        }
        try reader.seek(to: max(0, key.sourceIn))
        if key.preservesPitch {
            var left = [Float](), right = [Float]()
            var tempo = Self.tempo(ramp.speed(atClipFrame: 0))
            left.reserveCapacity(outputCount); right.reserveCapacity(outputCount)
            while left.count < outputCount {
                let frame = Double(left.count) / Double(sampleRate) * key.timelineFPS
                let wanted = Self.tempo(ramp.speed(atClipFrame: frame))
                if abs(wanted - tempo) > 0.002 { try reader.setTempo(wanted); tempo = wanted }
                let chunk = try reader.read(frames: min(1_024, outputCount - left.count))
                if chunk.isEmpty { break }
                for i in 0..<(chunk.count / 2) { left.append(chunk[2 * i]); right.append(chunk[2 * i + 1]) }
            }
            return [left, right]
        }

        // Pitch-following playback is direct source sampling through the same time map used by video export.
        let sourceSeconds = ramp.sourcePosition(atClipFrame: key.duration * key.timelineFPS) / key.timelineFPS
        let sourceCount = max(2, Int((sourceSeconds * Double(sampleRate)).rounded(.up)) + 2)
        var interleaved = [Float]()
        while interleaved.count / 2 < sourceCount {
            let chunk = try reader.read(frames: min(chunkFrames, sourceCount - interleaved.count / 2))
            if chunk.isEmpty { break }
            interleaved += chunk
        }
        guard interleaved.count >= 4 else { return [[], []] }
        var left = [Float](), right = [Float]()
        left.reserveCapacity(outputCount); right.reserveCapacity(outputCount)
        for output in 0..<outputCount {
            let clipFrame = Double(output) / Double(sampleRate) * key.timelineFPS
            let sourceSample = ramp.sourcePosition(atClipFrame: clipFrame) / key.timelineFPS * Double(sampleRate)
            let i = min(max(0, Int(sourceSample.rounded(.down))), interleaved.count / 2 - 2)
            let fraction = Float(sourceSample - Double(i))
            left.append(interleaved[2 * i] + (interleaved[2 * (i + 1)] - interleaved[2 * i]) * fraction)
            right.append(interleaved[2 * i + 1] + (interleaved[2 * (i + 1) + 1] - interleaved[2 * i + 1]) * fraction)
        }
        return [left, right]
    }

    /// The rate a clip at speed `rate` is decoded at when its pitch follows the speed: `sampleRate / rate` samples per
    /// source second, played back at `sampleRate`.
    /// Speeds outside `resampledRates` (1/16x to 16x) are refused: the document allows any positive ratio, and the
    /// decode rate must stay a sample rate the engine can open.
    public static func resampledRate(_ sampleRate: Int, _ rate: Double) throws -> Int {
        guard rate.isFinite, resampledRates.contains(rate) else {
            throw StemDecodeError("This clip's speed (\(rate)x) is outside 1/16x to 16x, so its sound cannot follow the speed.")
        }
        return max(1, Int((Double(sampleRate) / rate).rounded()))
    }
    public static let resampledRates: ClosedRange<Double> = 1.0 / 16 ... 16
}
