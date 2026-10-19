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

/// Test inputs written by our own code: RIFF/WAVE bytes for interleaved samples, and the committed engine fixtures.
enum WavFixtures {
    static let mediaFixtures = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/EngineFixtures").standardizedFileURL

    enum Encoding { case s16, f32 }

    /// A canonical 44-byte-header WAV: PCM 16-bit (format 1) or IEEE float 32-bit (format 3), little-endian.
    static func wav(_ interleaved: [Float], sampleRate: Int, channels: Int, encoding: Encoding = .f32) -> Data {
        let bytesPerSample = encoding == .s16 ? 2 : 4
        let dataSize = interleaved.count * bytesPerSample
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(encoding == .s16 ? 1 : 3); u16(channels); u32(sampleRate)
        u32(sampleRate * channels * bytesPerSample); u16(channels * bytesPerSample); u16(bytesPerSample * 8)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for x in interleaved {
            switch encoding {
            case .s16:
                let v = Int16(max(-32768, min(32767, (Double(x) * 32768).rounded())))
                withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
            case .f32:
                withUnsafeBytes(of: x.bitPattern.littleEndian) { d.append(contentsOf: $0) }
            }
        }
        return d
    }

    /// A fresh directory under the system temp folder; the caller removes it.
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `interleaved` as `name` in `dir` and returns its path.
    static func write(_ name: String, in dir: URL, _ interleaved: [Float], sampleRate: Int, channels: Int = 1,
                      encoding: Encoding = .f32) throws -> String {
        let url = dir.appendingPathComponent(name)
        try wav(interleaved, sampleRate: sampleRate, channels: channels, encoding: encoding).write(to: url)
        return url.path
    }

    static func sine(_ freq: Double, seconds: Double, amp: Double, sampleRate: Int) -> [Float] {
        let n = Int((seconds * Double(sampleRate)).rounded())
        return (0..<n).map { (i: Int) -> Float in Float(amp * sin(2 * Double.pi * freq * Double(i) / Double(sampleRate))) }
    }
}

/// Sign changes per second of one plane (a sine of f Hz has 2f).
func crossingsPerSecond(_ plane: [Float], sampleRate: Int) -> Double {
    guard plane.count > 1 else { return 0 }
    var n = 0
    for i in 1..<plane.count where (plane[i - 1] < 0) != (plane[i] < 0) { n += 1 }
    return Double(n) * Double(sampleRate) / Double(plane.count)
}

func rmsOf(_ plane: ArraySlice<Float>) -> Double {
    guard !plane.isEmpty else { return 0 }
    return (plane.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(plane.count)).squareRoot()
}

/// Largest absolute sample difference (length mismatch counts as infinite).
func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return .infinity }
    return zip(a, b).map { abs($0 - $1) }.max() ?? 0
}
