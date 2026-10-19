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
// Waveform peaks for timeline audio: the file downmixed to mono at
// 4 kHz (read with the media engine's AudioSampleReader), split into `bars` windows (fractional step), each the
// window's absolute maximum, normalized so the loudest bar is 1. Results are cached in the project's
// `.waveform-cache/` keyed by path, size and modification time. No encoder priming is skipped here: the engine's
// reader already drops AAC priming (the MP4/MOV edit list), and PCM and FLAC have none.
import Foundation
import OneTakeMedia
import MpvfxShared

public enum WaveformPeaks {
    public static let defaultBars = 4000
    /// Decode rate: enough resolution for 4000 bars on long files without huge buffers.
    static let sampleRate = 4000
    static let cacheVersion = "v3"
    /// Frames read per engine call (1 s at the decode rate).
    static let readFrames = 4000

    /// Peaks of `samples`; never fabricated: an empty input gives all zeros.
    public static func peaks(_ samples: [Float], bars: Int) -> [Double] {
        guard bars > 0 else { return [] }
        let step = Double(samples.count) / Double(bars)
        var out = [Double](repeating: 0, count: bars)
        samples.withUnsafeBufferPointer { buf in
            for i in 0..<bars {
                var m: Float = 0
                let start = Int((Double(i) * step).rounded(.down)), end = min(Int((Double(i + 1) * step).rounded(.down)), buf.count)
                if start < end { for j in start..<end { m = max(m, abs(buf[j])) } }
                out[i] = Double(m)
            }
        }
        let top = max(out.max() ?? 0, 0.001)
        return out.map { $0 / top }
    }

    /// `.waveform-cache/<version>_<path with / as _>_<size>-<mtime ms>.json`.
    static func cacheName(_ source: String, size: Int64, mtimeNs: Int128) -> String {
        let name = source.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        return "\(cacheVersion)_\(name)_\(size)-\(Int64((Double(mtimeNs) / 1e6).rounded())).json"
    }

    /// The whole first audio track of `path` as mono samples at `sampleRate`.
    static func monoSamples(_ path: String, cancellation: MediaCancellation?) throws -> [Float] {
        do {
            let reader = try AudioSampleReader(path: path, sampleRate: sampleRate, channels: 1)
            var samples: [Float] = []
            while true {
                try cancellation?.throwIfCancelled()
                let chunk = try reader.read(frames: readFrames)
                if chunk.isEmpty { return samples }
                samples.append(contentsOf: chunk)
            }
        } catch let e as MediaError { throw mediaToolError(e) }
    }

    /// Peaks of a project media file's first audio track, downmixed to mono. Throws when the file is outside the
    /// project or has no audio the engine can decode (with the engine's reason).
    public static func forProjectMedia(_ projectDir: String, _ source: String, bars: Int = defaultBars, cache: Bool = true,
                                       cancellation: MediaCancellation? = nil) throws -> [Double] {
        guard (1...20_000).contains(bars) else { throw MediaToolError("Invalid waveform request") }
        let root = try ProjectFS.realpath(projectDir)
        let path = try ProjectFS.realpath(PosixPath.resolve(root, source))
        let offset = PosixPath.relative(root, path)
        if offset.isEmpty || PosixPath.isAbsolute(offset) || offset == ".." || offset.hasPrefix("../") {
            throw MediaToolError("Media must be a file inside this project")
        }
        let info = try ProjectFS.statInfo(path)
        guard info.isFile else { throw MediaToolError("Media must be a regular file") }
        let cacheDir = PosixPath.join(root, ".waveform-cache")
        let cachePath = PosixPath.join(cacheDir, cacheName(offset, size: info.size, mtimeNs: info.mtimeNs))
        if cache, bars == defaultBars, let text = try? ProjectFS.readUTF8(cachePath),
           let cached = (try? NativeJSONValue.parse(text))?.arrayValue?.compactMap({ v -> Double? in if case .number(let n) = v { return n }; return nil }),
           cached.count == bars { return cached }
        let samples = try monoSamples(path, cancellation: cancellation)
        if samples.isEmpty { throw MediaToolError("No audio to draw: \(source)") }
        let computed = peaks(samples, bars: bars)
        if cache, bars == defaultBars {   // best effort: a cache write failure only costs a recompute
            try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            try? Data(jsJSONStringify(.array(computed.map { .number($0) })).utf8).write(to: URL(fileURLWithPath: cachePath), options: .atomic)
        }
        return computed
    }
}
