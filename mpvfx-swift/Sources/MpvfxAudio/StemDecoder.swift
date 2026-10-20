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
        let sped = abs(key.rate - 1) > 1e-9
        let reader: AudioSampleReader
        if sped && !key.preservesPitch {
            reader = try AudioSampleReader(path: key.path, sampleRate: resampledRate(sampleRate, key.rate), channels: 2)
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

    /// The rate a clip at speed `rate` is decoded at when its pitch follows the speed: `sampleRate / rate` samples per
    /// source second, played back at `sampleRate`.
    public static func resampledRate(_ sampleRate: Int, _ rate: Double) -> Int {
        max(1, Int((Double(sampleRate) / rate).rounded()))
    }
}
