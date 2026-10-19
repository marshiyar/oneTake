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

// The benchmark's input clips, written by the media engine's own H.264 encoder (MediaWriter, MP4, no audio):
//
//   MpvfxPreviewBench --make-clips <fixtures dir>
//
// clip1080.mp4 (1920x1080, 10 s) and clip2160.mp4 (3840x2160, 6 s) show colour bars, a gradient with a ripple and a
// grey ramp with a moving square; clip1080b.mp4 (1920x1080, 10 s) shows moving rings. All are 30 fps with a little
// fresh noise on every frame, so no two frames are alike. A clip already in the directory is kept.

/// One benchmark clip: its file name, size, length and picture.
struct BenchClip {
    var file: String
    var width: Int, height: Int, seconds: Int
    var rings = false

    static let all = [
        BenchClip(file: "clip1080.mp4", width: 1920, height: 1080, seconds: 10),
        BenchClip(file: "clip1080b.mp4", width: 1920, height: 1080, seconds: 10, rings: true),
        BenchClip(file: "clip2160.mp4", width: 3840, height: 2160, seconds: 6),
    ]

    static let bars: [[UInt8]] = [[191, 191, 191], [191, 191, 0], [0, 191, 191], [0, 191, 0],
                                  [191, 0, 191], [191, 0, 0], [0, 0, 191], [0, 0, 0]]

    /// Frame `n` as straight RGBA8.
    func frame(_ n: Int, seed: inout UInt64) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        let third = height / 3, side = height / 6
        let sx = (n * 8) % (width - side), sy = third * 2 - side
        let cx = Double(width) / 2 + Double(width) / 4 * sin(Double(n) / 40), cy = Double(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                var c: [Int]
                if rings {
                    let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
                    let a = d / 24 - Double(n) / 6
                    c = [Int(128 + 100 * sin(a)), Int(128 + 100 * sin(a + 2.1)), Int(128 + 100 * sin(a + 4.2))]
                } else if x >= sx && x < sx + side && y >= sy && y < sy + side {
                    c = [255, 255, 255]
                } else if y < third {
                    c = Self.bars[min(7, x * 8 / width)].map { Int($0) }
                } else if y < third * 2 {
                    let ripple = 64 * sin(Double(x + n * 4) / 21) * cos(Double(y) / 15)
                    c = [x * 255 / (width - 1), (y - third) * 255 / max(1, third - 1), Int(128 + ripple)]
                } else {
                    let v = x * 207 / (width - 1) + 24 + (((x / 2 + y / 2) % 2 == 0) ? 24 : -24)
                    c = [v, v, v]
                }
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = Int((seed >> 33) % 9) - 4
                px[i] = UInt8(max(0, min(255, c[0] + noise)))
                px[i + 1] = UInt8(max(0, min(255, c[1] + noise)))
                px[i + 2] = UInt8(max(0, min(255, c[2] + noise)))
            }
        }
        return px
    }

    /// Writes the clip as H.264 MP4 at 30 fps, no audio.
    func write(to path: String) throws {
        var cfg = MediaWriter.Config(container: .mp4, width: width, height: height)
        cfg.fpsNumerator = 30; cfg.audioRate = 0
        let w = try MediaWriter(path: path, config: cfg)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for n in 0..<(seconds * 30) { try w.addVideo(frame(n, seed: &seed)) }
        try w.finish()
    }
}

/// Writes every benchmark clip missing from `dir`.
func makeClips(_ dir: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for clip in BenchClip.all {
        let path = "\(dir)/\(clip.file)"
        if FileManager.default.fileExists(atPath: path) { continue }
        print("writing \(path)")
        try clip.write(to: path)
    }
}
