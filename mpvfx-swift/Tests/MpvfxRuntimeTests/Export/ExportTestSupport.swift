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
// Inputs and checks for export tests, all through our own code: WAV and BMP bytes written directly, videos written
// by MediaWriter (MOV = PNG + LPCM works without the H.264 encoder; MP4 needs it), exports decoded back with
// MediaProbe, VideoFrameReader and AudioSampleReader. No FFmpeg anywhere.
import Foundation
import XCTest
import OneTakeMedia
import MpvfxPlayer
import MpvfxShared
@testable import MpvfxRuntime

/// A test video: `seconds` long at `fps`, every frame one colour (`color(t)`), optionally with a sine `tone` (Hz) at
/// `amplitude` on both channels; written as MOV (PNG + LPCM) or MP4 (H.264 + FLAC).
struct TestVideo {
    var width = 64, height = 32, fps = 10
    var seconds = 2.0
    var color: (Double) -> [UInt8] = { _ in [255, 0, 0] }
    var tone: Double? = nil
    var amplitude: Float = 0.125
    var container = MediaWriter.Container.mov
    /// Paints each frame from its time (default: one colour); overrides `color`.
    var pixels: ((Double) -> [UInt8])? = nil
}

extension TestMedia {
    /// Writes `video` to `path` (through `<path>.partial`, renamed by the writer).
    static func write(_ video: TestVideo, to path: String) throws {
        var config = MediaWriter.Config(container: video.container, width: video.width, height: video.height)
        config.fpsNumerator = video.fps
        config.audioRate = video.tone == nil ? 0 : 48_000
        let writer = try MediaWriter(path: path, config: config)
        let frames = Int((video.seconds * Double(video.fps)).rounded())
        var written = 0
        for i in 0..<frames {
            let t = Double(i) / Double(video.fps)
            let rgba = video.pixels?(t) ?? solid(video.color(t), video.width, video.height)
            try writer.addVideo(rgba)
            guard let tone = video.tone else { continue }
            let end = (i + 1) * 48_000 / video.fps
            try writer.addAudio(sine(tone, amplitude: video.amplitude, frames: written..<end, channels: 2))
            written = end
        }
        try writer.finish()
    }

    static func solid(_ rgb: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        Array((0..<(width * height)).map { _ in [rgb[0], rgb[1], rgb[2], rgb.count > 3 ? rgb[3] : 255] }.joined())
    }

    static func sine(_ frequency: Double, amplitude: Float, frames: Range<Int>, channels: Int) -> [Float] {
        frames.flatMap { i -> [Float] in
            let v = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / 48_000))
            return [Float](repeating: v, count: channels)
        }
    }

    /// 16-bit PCM mono WAV at 48 kHz: a sine at `amplitude` (FFmpeg's lavfi `sine` default is 1/8).
    static func wav(_ frequency: Double, seconds: Double, to path: String, amplitude: Float = 0.125) throws {
        let samples = sine(frequency, amplitude: amplitude, frames: 0..<Int(seconds * 48_000), channels: 1)
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + samples.count * 2); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(samples.count * 2)
        for s in samples { var x = Int16(max(-32768, min(32767, (s * 32768).rounded()))).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        try d.write(to: URL(fileURLWithPath: path))
    }

    /// Uncompressed 24-bit BMP (bottom-up rows padded to 4 bytes) of one colour.
    static func bmp(width: Int, height: Int, rgb: [UInt8], to path: String) throws {
        let stride = (width * 3 + 3) / 4 * 4
        var d = Data("BM".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(54 + stride * height); u32(0); u32(54)
        u32(40); u32(width); u32(height); u16(1); u16(24); u32(0); u32(stride * height); u32(2835); u32(2835); u32(0); u32(0)
        let row = Array((0..<width).map { _ in [rgb[2], rgb[1], rgb[0]] }.joined()) + [UInt8](repeating: 0, count: stride - width * 3)
        for _ in 0..<height { d.append(contentsOf: row) }
        try d.write(to: URL(fileURLWithPath: path))
    }
}

/// An exported file read back with the media engine.
struct Exported {
    let path: String
    var probe: MediaProbe { get throws { try MediaProbe.probe(path: path) } }

    /// The frame shown at `seconds` at the file's own size, straight RGBA.
    func rgba(_ seconds: Double) throws -> (rgba: [UInt8], width: Int, height: Int) {
        let reader = try VideoFrameReader(path: path)
        let f = try reader.frame(at: seconds, width: reader.info.width, height: reader.info.height, fit: .stretch)
        return (f.rgba, reader.info.width, reader.info.height)
    }

    /// The frame at `seconds` as packed RGB (alpha dropped), the layout the pixel checks index.
    func rgb(_ seconds: Double) throws -> [UInt8] {
        let f = try rgba(seconds).rgba
        return stride(from: 0, to: f.count, by: 4).flatMap { (i: Int) -> [UInt8] in [f[i], f[i + 1], f[i + 2]] }
    }

    /// The whole sound track as 48 kHz stereo interleaved samples.
    func audio() throws -> [Float] {
        let reader = try AudioSampleReader(path: path, sampleRate: 48_000, channels: 2)
        var out: [Float] = []
        while true {
            let chunk = try reader.read(frames: 1 << 15)
            if chunk.isEmpty { return out }
            out += chunk
        }
    }

    /// RMS of the mono mix ((L + R) / 2) over `length` seconds from `seconds`; 0 past the end.
    func rms(_ seconds: Double, length: Double = 0.1) throws -> Double {
        TestAudio.rms(try audio(), from: Int(seconds * 48_000), count: Int(length * 48_000))
    }
}

enum TestAudio {
    static func rms(_ stereo: [Float], from start: Int, count: Int) -> Double {
        let frames = stereo.count / 2
        let lo = min(start, frames), hi = min(start + count, frames)
        guard hi > lo else { return 0 }
        let sum = (lo..<hi).reduce(0.0) { acc, i in
            let m = (Double(stereo[2 * i]) + Double(stereo[2 * i + 1])) / 2
            return acc + m * m
        }
        return (sum / Double(hi - lo)).squareRoot()
    }
}

/// Export tests paint frames with the app's own renderer, as main.swift installs it.
func installAppExportFrames() {
    NativeExportFrames.defaultRenderer = PreviewExportFrames.factory
}

/// The frame the preview's painter draws for `input` at `time`: what the export must match.
func previewExportFrame(_ input: NativeTimelineRenderInput, at time: Double) throws -> [UInt8] {
    var probe = input
    probe.outputPath = input.outputPath + ".plan-only"
    let plan = try planNativeTimelineRender(&probe)
    var request = NativeExportFrameRequest(document: plan.project, projectDir: plan.root, width: plan.width, height: plan.height)
    request.transparentPad = input.format == .mov
    request.keyframeEngine = probe.keyframeEngine
    return try PreviewExportFrames(request).frame(at: time)
}

func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .infinity }
    return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
}

func maxAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Int {
    guard a.count == b.count else { return .max }
    return zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
}

/// Every name in `dir` an export may leave behind by mistake: partial files and staging folders.
func leftovers(_ dir: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".partial") || $0.hasPrefix(".studio-render-tmp") }
}
