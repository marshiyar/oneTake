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
// The narration audio format: mono 48 kHz 16-bit PCM in a canonical RIFF/WAVE file (44-byte header: `fmt ` chunk of
// 16 bytes, format tag 1, then `data`). Adapters whose OS hands back samples write them with `narrationWAV`.
import Foundation

public enum NarrationWAV {
    public static let sampleRate = 48_000
    public static let channels = 1
    public static let bitsPerSample = 16
    /// RIFF sizes are 32-bit: the largest data chunk a canonical file can describe.
    static let maxDataBytes = Int(UInt32.max) - 36

    /// The WAV bytes of `samples` (mono, 48 kHz). nil when the data would not fit a RIFF file.
    public static func encode(_ samples: [Int16]) -> Data? {
        let dataSize = samples.count * 2
        guard dataSize <= maxDataBytes else { return nil }
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * channels * bitsPerSample / 8); u16(channels * bitsPerSample / 8); u16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        samples.withUnsafeBufferPointer { buffer in
            for s in buffer { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }

    /// Writes `samples` to `url` (a temporary file the caller owns), failing with `SynthesisError.writeFailed`.
    public static func write(_ samples: [Int16], to url: URL) throws {
        guard let data = encode(samples) else {
            throw SynthesisError.writeFailed(path: url.path, underlying: "the narration is too long for one WAV file")
        }
        do { try data.write(to: url, options: [.withoutOverwriting]) }
        catch { throw SynthesisError.writeFailed(path: url.path, underlying: error.localizedDescription) }
    }
}
