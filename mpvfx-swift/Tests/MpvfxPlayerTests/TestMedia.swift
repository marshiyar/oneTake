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

/// Test inputs written by the media engine itself: no external tool. Scratch files stay inside the package
/// (.build/test-tmp) and are removed by the test that made them.
enum TestMedia {
    static let packageRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A fresh scratch directory under .build/test-tmp.
    static func scratch(_ tag: String) throws -> URL {
        let dir = packageRoot.appendingPathComponent(".build/test-tmp/\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// width×height RGBA8 of one colour.
    static func solid(_ rgb: [UInt8], width: Int, height: Int) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = rgb[0]; px[i + 1] = rgb[1]; px[i + 2] = rgb[2] }
        return px
    }

    /// width×height red RGBA8 with a blue `side`×`side` square at the top-left (an orientation marker).
    static func blueCornerOnRed(side: Int, width: Int, height: Int) -> [UInt8] {
        var px = solid([255, 0, 0], width: width, height: height)
        for y in 0..<side { for x in 0..<side { let i = (y * width + x) * 4; px[i] = 0; px[i + 2] = 255 } }
        return px
    }

    /// A lossless MOV (PNG frames) of solid colour segments, each `seconds` long.
    struct SolidVideo {
        var width = 64, height = 36, fps = 30
        var segments: [(rgb: [UInt8], seconds: Double)]

        /// 1 s red then 1 s blue, 64×36 @30fps.
        static let redThenBlue = SolidVideo(segments: [([255, 0, 0], 1), ([0, 0, 255], 1)])

        func write(to path: String) throws -> String {
            let w = try TestMedia.movWriter(path: path, width: width, height: height, fps: fps)
            for seg in segments {
                let frame = TestMedia.solid(seg.rgb, width: width, height: height)
                for _ in 0..<Int((seg.seconds * Double(fps)).rounded()) { try w.addVideo(frame) }
            }
            try w.finish()
            return path
        }
    }

    /// A lossless MOV (PNG frames, fastest level) without audio.
    static func movWriter(path: String, width: Int, height: Int, fps: Int) throws -> MediaWriter {
        var cfg = MediaWriter.Config(container: .mov, width: width, height: height)
        cfg.fpsNumerator = fps; cfg.audioRate = 0; cfg.quality = .draft
        return try MediaWriter(path: path, config: cfg)
    }

    /// A different picture every frame with the content grade and stylize tests need: 75 % colour bars (top third),
    /// a smooth two-axis colour gradient with a sine ripple (middle), a grey ramp with a fine 2-px checker (bottom,
    /// texture for edge and smoothing effects), and a white square that moves two pixels per frame.
    struct PatternVideo {
        var width = 160, height = 90, fps = 30, seconds = 1.0

        static let bars: [[UInt8]] = [[191, 191, 191], [191, 191, 0], [0, 191, 191], [0, 191, 0],
                                      [191, 0, 191], [191, 0, 0], [0, 0, 191], [0, 0, 0]]

        func frame(_ n: Int) -> [UInt8] {
            var px = [UInt8](repeating: 255, count: width * height * 4)
            let third = max(1, height / 3), side = max(2, height / 6)
            let sx = (n * 2) % max(1, width - side), sy = third * 2 - side
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let c = pixel(x, y, third: third)
                    let inSquare = x >= sx && x < sx + side && y >= sy && y < sy + side
                    px[i] = inSquare ? 255 : c[0]; px[i + 1] = inSquare ? 255 : c[1]; px[i + 2] = inSquare ? 255 : c[2]
                }
            }
            return px
        }

        func pixel(_ x: Int, _ y: Int, third: Int) -> [UInt8] {
            if y < third { return Self.bars[min(7, x * 8 / width)] }
            if y < third * 2 {
                let ripple = 64 * sin(Double(x) / 7) * cos(Double(y) / 5)
                return [UInt8(x * 255 / max(1, width - 1)), UInt8((y - third) * 255 / max(1, third - 1)),
                        UInt8(max(0, min(255, 128 + ripple)))]
            }
            let ramp = x * 207 / max(1, width - 1) + 24, check = ((x / 2 + y / 2) % 2 == 0) ? 24 : -24
            let v = UInt8(max(0, min(255, ramp + check)))
            return [v, v, v]
        }

        func write(to path: String) throws -> String {
            let w = try TestMedia.movWriter(path: path, width: width, height: height, fps: fps)
            for n in 0..<Int((seconds * Double(fps)).rounded()) { try w.addVideo(frame(n)) }
            try w.finish()
            return path
        }
    }

    /// A JPEG (our encoder, quality 100) of RGBA pixels.
    static func writeJPEG(_ rgba: [UInt8], width: Int, height: Int, to path: String) throws -> String {
        try ImageCodec.encodeJPEG(rgba: rgba, width: width, height: height, quality: 100).write(to: URL(fileURLWithPath: path))
        return path
    }
}
