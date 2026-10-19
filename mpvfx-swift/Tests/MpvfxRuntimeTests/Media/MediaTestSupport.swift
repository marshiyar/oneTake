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
// Test inputs built with our own code: WAV, PNG, BMP and EXIF-tagged JPEG bytes written here (JPEG pixels by the
// media engine's encoder), MOV files written by the engine's MediaWriter, and hand-built MP4/MOV box trees for
// tracks nothing of ours can encode (HEVC, ProRes, AAC, rotated pictures). The layouts follow Apple QTFF, the PNG
// 3rd edition, RFC 1950/1951 stored blocks, Microsoft RIFF/WAVE and BITMAPINFOHEADER, and TIFF 6.0.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxRuntime

func makeMediaTempDir(_ prefix: String) throws -> String {
    try makeTemporaryDirectory(NSTemporaryDirectory() + prefix)
}

/// A committed engine fixture (`Tests/EngineFixtures/<name>`; provenance in its README).
func engineFixture(_ name: String) -> String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("EngineFixtures/\(name)").path
}

enum TestMedia {
    // MARK: Pixels and stills

    /// width × height straight RGBA8 of one colour.
    static func solid(_ rgb: (UInt8, UInt8, UInt8), width: Int, height: Int) -> [UInt8] {
        [UInt8]((0..<(width * height)).flatMap { _ in [rgb.0, rgb.1, rgb.2, 255] })
    }

    /// RGBA with the left half `left` and the right half `right`.
    static func split(_ left: (UInt8, UInt8, UInt8), _ right: (UInt8, UInt8, UInt8), width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        for _ in 0..<height { for x in 0..<width { let c = x < width / 2 ? left : right; out += [c.0, c.1, c.2, 255] } }
        return out
    }

    /// PNG of RGBA8 (colour type 6, depth 8, no interlace), image data in stored deflate blocks.
    static func png(_ rgba: [UInt8], width: Int, height: Int) -> Data {
        var raw: [UInt8] = []
        for y in 0..<height { raw.append(0); raw += rgba[(y * width * 4)..<((y + 1) * width * 4)] }   // filter type 0
        var z: [UInt8] = [0x78, 0x01]
        var at = 0
        repeat {
            let n = min(65_535, raw.count - at), last: UInt8 = at + n == raw.count ? 1 : 0
            z += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)] + raw[at..<(at + n)]
            at += n
        } while at < raw.count
        z += be32(adler32(raw))
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return be32(UInt32(body.count)) + typed + be32(crc32(typed))
        }
        let ihdr = be32(UInt32(width)) + be32(UInt32(height)) + [8, 6, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", z) + chunk("IEND", []))
    }

    /// Uncompressed 24-bit bottom-up BMP (BITMAPFILEHEADER + BITMAPINFOHEADER, rows padded to 4 bytes).
    static func bmp(_ rgba: [UInt8], width: Int, height: Int) -> Data {
        let row = (width * 3 + 3) / 4 * 4
        var pixels: [UInt8] = []
        for y in (0..<height).reversed() {
            for x in 0..<width { let i = (y * width + x) * 4; pixels += [rgba[i + 2], rgba[i + 1], rgba[i]] }
            pixels += [UInt8](repeating: 0, count: row - width * 3)
        }
        let info = le32(40) + le32(UInt32(width)) + le32(UInt32(height)) + le16(1) + le16(24) + le32(0) + le32(UInt32(pixels.count))
            + le32(2835) + le32(2835) + le32(0) + le32(0)
        let header: [UInt8] = Array("BM".utf8) + le32(UInt32(14 + 40 + pixels.count)) + le32(0) + le32(54)
        return Data(header + info + pixels)
    }

    /// A JPEG of `rgba` from the engine's encoder, with an APP1 Exif segment holding only IFD0 Orientation = `o`
    /// (big-endian TIFF for odd values, little-endian for even ones, so both byte orders are read).
    static func jpeg(_ rgba: [UInt8], width: Int, height: Int, orientation o: Int? = nil) throws -> Data {
        let jpeg = try ImageCodec.encodeJPEG(rgba: rgba, width: width, height: height, quality: 95)
        guard let o else { return jpeg }
        let le = o % 2 == 0
        func u16(_ v: Int) -> [UInt8] { le ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { le ? [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), 0, 0] : [0, 0, UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        let byteOrder: [UInt8] = le ? [0x49, 0x49] : [0x4D, 0x4D]
        let ifdHeader: [UInt8] = u16(42) + u32(8) + u16(1)
        let orientationEntry: [UInt8] = u16(0x0112) + u16(3) + u32(1) + u16(o)
        let entryPadding: [UInt8] = [0, 0]
        let tiff: [UInt8] = byteOrder + ifdHeader + orientationEntry + entryPadding + u32(0)
        let app1: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0, 0] + tiff
        let len = app1.count + 2
        return Data([UInt8](jpeg.prefix(2)) + [0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 0xFF)] + app1 + [UInt8](jpeg.dropFirst(2)))
    }

    // MARK: Audio

    /// 16-bit PCM WAV of interleaved samples in -1 ... 1.
    static func wav(_ samples: [Float], rate: Int, channels: Int) -> Data {
        let pcm = samples.flatMap { s -> [UInt8] in
            let v = Int16(max(-32_768, min(32_767, (Double(s) * 32_767).rounded())))
            return le16(UInt16(bitPattern: v))
        }
        let fmt = le16(1) + le16(UInt16(channels)) + le32(UInt32(rate)) + le32(UInt32(rate * channels * 2)) + le16(UInt16(channels * 2)) + le16(16)
        let body: [UInt8] = Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + fmt + Array("data".utf8) + le32(UInt32(pcm.count)) + pcm
        return Data(Array("RIFF".utf8) + le32(UInt32(body.count)) + body)
    }

    /// `seconds` of a sine at `amplitude`, mono.
    static func tone(seconds: Double, rate: Int, frequency: Double = 440, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { (i: Int) -> Float in amplitude * Float(sin(2 * .pi * frequency * Double(i) / Double(rate))) }
    }

    // MARK: Movies

    /// A MOV from the engine's writer: PNG frames (RGBA) at `fps`, and 16-bit stereo PCM of `audio` (mono at 48 kHz,
    /// copied to both channels) when it is given.
    static func writeMOV(_ path: String, frames: [[UInt8]], width: Int, height: Int, fps: Int = 10, audio: [Float]? = nil) throws {
        var config = MediaWriter.Config(container: .mov, width: width, height: height)
        config.fpsNumerator = fps
        config.audioRate = audio == nil ? 0 : 48_000
        let writer = try MediaWriter(path: path, config: config)
        for frame in frames { try writer.addVideo(frame) }
        if let audio { try writer.addAudio(audio.flatMap { [$0, $0] }) }
        try writer.finish()
    }

    /// One track of a hand-built movie: its handler, first sample description (a whole box) and samples, one per chunk.
    struct Track {
        var handler: String
        var entry: [UInt8]
        var samples: [[UInt8]]
        var timescale: UInt32 = 1000
        var sampleDuration: UInt32 = 100
        var size = (width: 0, height: 0)
        /// Clockwise display rotation written into the track matrix (0, 90, 180, 270).
        var rotation = 0
    }

    /// ftyp (`qt  ` for MOV, else `isom`), one mdat with every sample, then moov.
    static func movie(_ tracks: [Track], quicktime: Bool = false) -> Data {
        let ftyp = box("ftyp", Array((quicktime ? "qt  " : "isom").utf8) + be32(0) + Array((quicktime ? "qt  " : "isommp41").utf8))
        var mdat: [UInt8] = [], offsets: [[UInt32]] = []
        let base = ftyp.count + 8
        for t in tracks {
            offsets.append(t.samples.map { s in defer { mdat += s }; return UInt32(base + mdat.count) })
        }
        let movieDuration = tracks.map { (t: Track) -> UInt32 in
            let seconds = Double(t.samples.count) * Double(t.sampleDuration) / Double(t.timescale)
            return UInt32(seconds * 1000)
        }.max() ?? 0
        let mvhdTimes: [UInt8] = be32(0) + be32(0) + be32(1000) + be32(movieDuration) + be32(0x0001_0000)
        let mvhdVolume: [UInt8] = [1, 0]
        let mvhdTail: [UInt8] = zeros(10) + matrix(0) + zeros(24) + be32(UInt32(tracks.count + 1))
        let mvhd = full("mvhd", mvhdTimes + mvhdVolume + mvhdTail)
        let traks = tracks.enumerated().flatMap { i, t in trak(t, id: UInt32(i + 1), offsets: offsets[i]) }
        return Data(ftyp + box("mdat", mdat) + box("moov", mvhd + traks))
    }

    static func trak(_ t: Track, id: UInt32, offsets: [UInt32]) -> [UInt8] {
        let n = UInt32(t.samples.count), duration = n * t.sampleDuration
        let tkhdTimes: [UInt8] = be32(0) + be32(0) + be32(id) + be32(0) + be32(duration * 1000 / t.timescale)
        let tkhdVolume: [UInt8] = t.handler == "soun" ? [1, 0] : [0, 0]
        let tkhdLayout: [UInt8] = zeros(8) + zeros(4) + tkhdVolume + zeros(2) + matrix(t.rotation)
        let tkhdSize: [UInt8] = be32(UInt32(t.size.width) << 16) + be32(UInt32(t.size.height) << 16)
        let tkhd = full("tkhd", tkhdTimes + tkhdLayout + tkhdSize, flags: 7)
        let mdhd = full("mdhd", be32(0) + be32(0) + be32(t.timescale) + be32(duration) + [0x55, 0xC4] + zeros(2))
        let hdlr = full("hdlr", be32(0) + Array(t.handler.utf8) + zeros(12) + [0])
        let stbl = box("stbl", full("stsd", be32(1) + t.entry) + full("stts", be32(1) + be32(n) + be32(t.sampleDuration))
            + full("stsc", be32(1) + be32(1) + be32(1) + be32(1))
            + full("stsz", be32(0) + be32(n) + t.samples.flatMap { be32(UInt32($0.count)) })
            + full("stco", be32(n) + offsets.flatMap(be32)))
        return box("trak", tkhd + box("mdia", mdhd + hdlr + box("minf", stbl)))
    }

    /// A visual sample description (QTFF "Video sample description": 78 bytes of fixed fields, then `children`).
    static func videoEntry(_ fourcc: String, width: Int, height: Int, children: [UInt8] = []) -> [UInt8] {
        let one: [UInt8] = [0, 1]
        let dimensions: [UInt8] = [UInt8(width >> 8), UInt8(width & 0xFF), UInt8(height >> 8), UInt8(height & 0xFF)]
        let resolution: [UInt8] = be32(0x0048_0000) + be32(0x0048_0000) + be32(0)
        let depthAndColorTable: [UInt8] = [0, 24, 0xFF, 0xFF]
        let head: [UInt8] = zeros(6) + one + zeros(16) + dimensions
        let body: [UInt8] = head + resolution + one + zeros(32) + depthAndColorTable
        return box(fourcc, body + children)
    }

    /// A version-0 sound sample description (QTFF "Sound sample description version 0", 28 bytes), then `children`.
    static func soundEntry(_ fourcc: String, channels: Int, rate: Int, children: [UInt8] = []) -> [UInt8] {
        let one: [UInt8] = [0, 1]
        let format: [UInt8] = [0, UInt8(channels), 0, 16]
        let body: [UInt8] = zeros(6) + one + zeros(8) + format + zeros(4) + be32(UInt32(rate) << 16) + children
        return box(fourcc, body)
    }

    /// `mp4a` of AAC-LC (AudioSpecificConfig: object type 2, 48 kHz, mono) with its `esds` descriptor chain.
    static func aacEntry() -> [UInt8] {
        let dsi: [UInt8] = [0x05, 2, 0x11, 0x88]
        let config: [UInt8] = [0x04, UInt8(13 + dsi.count), 0x40, 0x15] + zeros(3) + be32(0) + be32(0) + dsi
        let es: [UInt8] = [0x03, UInt8(3 + config.count + 3), 0, 1, 0] + config + [0x06, 1, 2]
        return soundEntry("mp4a", channels: 1, rate: 48_000, children: full("esds", es))
    }

    /// One PNG picture per sample of a `png ` video track.
    static func pngTrack(_ frames: [[UInt8]], width: Int, height: Int, rotation: Int = 0) -> Track {
        Track(handler: "vide", entry: videoEntry("png ", width: width, height: height),
              samples: frames.map { [UInt8](png($0, width: width, height: height)) }, size: (width, height), rotation: rotation)
    }

    /// A video track whose samples are placeholder bytes, for codecs the editor refuses (hvc1, apcn, vp09, av01).
    static func opaqueVideoTrack(_ fourcc: String, width: Int = 32, height: Int = 16) -> Track {
        Track(handler: "vide", entry: videoEntry(fourcc, width: width, height: height), samples: [[0, 0, 0, 1], [0, 0, 0, 1]], size: (width, height))
    }

    /// An AAC-LC track carrying the access units of the engine fixture `isobmff/mp4_aac.mp4` (0.5 s of a 440 Hz sine,
    /// 48 kHz mono; fixtures/README.md), cut out at the packet offsets its committed packet listing (`.json`)
    /// records. No edit list: the 1024-frame encoder delay plays as a short silence at the start.
    static func aacTrack() throws -> Track {
        let fixture = engineFixture("isobmff/mp4_aac.mp4")
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: fixture)))
        let listing = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture + ".json")))
        let packets = try XCTUnwrap((listing as? [String: Any])?["packets"] as? [[String: Any]])
        let units = try packets.map { p -> [UInt8] in
            let pos = try XCTUnwrap(Int(p["pos"] as? String ?? "")), size = try XCTUnwrap(Int(p["size"] as? String ?? ""))
            return Array(bytes[pos..<(pos + size)])
        }
        return Track(handler: "soun", entry: aacEntry(), samples: units, timescale: 48_000, sampleDuration: 1024)
    }

    // MARK: Bytes

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(UInt32(8 + payload.count)) + Array(type.utf8) + payload }
    static func full(_ type: String, _ payload: [UInt8], flags: UInt32 = 0) -> [UInt8] { box(type, be32(flags) + payload) }
    static func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

    /// QTFF display matrix for a clockwise rotation: (a, b, c, d) in 16.16, w = 1 in 2.30.
    static func matrix(_ rotation: Int) -> [UInt8] {
        let one: Int32 = 0x0001_0000
        let (a, b, c, d): (Int32, Int32, Int32, Int32)
        switch rotation {
        case 90: (a, b, c, d) = (0, one, -one, 0)
        case 180: (a, b, c, d) = (-one, 0, 0, -one)
        case 270: (a, b, c, d) = (0, -one, one, 0)
        default: (a, b, c, d) = (one, 0, 0, one)
        }
        return [a, b, 0, c, d, 0, 0, 0, 0x4000_0000].flatMap { be32(UInt32(bitPattern: $0)) }
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    /// RFC 1950 8.2.
    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for x in bytes { a = (a + UInt32(x)) % 65_521; b = (b + a) % 65_521 }
        return b << 16 | a
    }

    /// PNG 3rd ed. Annex D (CRC-32, polynomial 0xEDB88320 reflected).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in bytes {
            c ^= UInt32(x)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return c ^ 0xFFFF_FFFF
    }

    /// Mean RGB of a straight RGBA8 region.
    static func mean(_ rgba: [UInt8], width: Int, x: Range<Int>, y: Range<Int>) -> (Double, Double, Double) {
        var sum = (0.0, 0.0, 0.0), n = 0.0
        for yy in y { for xx in x { let i = (yy * width + xx) * 4; sum.0 += Double(rgba[i]); sum.1 += Double(rgba[i + 1]); sum.2 += Double(rgba[i + 2]); n += 1 } }
        return (sum.0 / n, sum.1 / n, sum.2 / n)
    }
}
