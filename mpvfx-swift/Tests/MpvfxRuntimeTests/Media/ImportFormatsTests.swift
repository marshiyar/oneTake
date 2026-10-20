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
// The import format table (the media engine's format table): v1 formats import, "later" and "blocked" ones are refused
// with that table's messages. Every input is written by our own code; nothing here runs FFmpeg.
import Foundation
import XCTest
import OneTakeMedia
import MpvfxShared
@testable import MpvfxRuntime

final class ImportFormatsTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        root = try makeMediaTempDir("mpvfx-import-formats-")
        try FileManager.default.createDirectory(atPath: root + "/project", withIntermediateDirectories: false)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    private func source(_ name: String, _ data: Data) throws -> String {
        let path = root + "/" + name
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }
    private func importing(_ paths: [String]) throws -> LocalMediaImportResult {
        try importLocalMedia(projectRoot: root + "/project", paths: paths, durableWrite: TestDurableWrite())
    }
    private func refusal(_ name: String, _ data: Data) throws -> String? {
        let result = try importing([try source(name, data)])
        XCTAssertEqual(result.files, [], name)
        return result.invalid.first?.reason
    }

    func testImportsEveryV1Format() throws {
        let red = TestMedia.solid((255, 0, 0), width: 8, height: 4)
        try TestMedia.writeMOV(root + "/ours.mov", frames: [red, red], width: 8, height: 4, audio: TestMedia.tone(seconds: 0.2, rate: 48_000))
        let tone = TestMedia.tone(seconds: 0.25, rate: 8000)
        let flac = engineFixture("flac/c5_8k_s16_mono.flac")
        try FileManager.default.copyItem(atPath: flac, toPath: root + "/tone.flac")
        let paths = [
            root + "/ours.mov",
            try source("png.mp4", TestMedia.movie([TestMedia.pngTrack([red], width: 8, height: 4)])),
            try source("tone.wav", TestMedia.wav(tone, rate: 8000, channels: 1)),
            root + "/tone.flac",
            try source("lossless.m4a", Data(contentsOf: URL(fileURLWithPath: engineFixture("isobmff/mp4_flac.mp4")))),
            try source("still.png", TestMedia.png(red, width: 8, height: 4)),
            try source("still.jpg", TestMedia.jpeg(red, width: 8, height: 4)),
            try source("still.bmp", TestMedia.bmp(red, width: 8, height: 4)),
            try copy("gif/min4.gif", as: "still.gif"),
            try copy("gif/anim_dispose.gif", as: "animated.gif"),
            try copy("webp/ll_all.webp", as: "lossless.webp"),
            try copy("webp/alpha_f3_c1.webp", as: "lossy.webp"),
            try copy("webp/anim.webp", as: "animated.webp"),
            try copy("ico/ff_three_sizes.ico", as: "icon.ico"),
            try copy("ico/hand_cursor.cur", as: "pointer.cur"),
        ]
        let result = try importing(paths)
        XCTAssertEqual(result.invalid, [])
        XCTAssertEqual(result.files, ["ours.mov", "png.mp4", "tone.wav", "tone.flac", "lossless.m4a", "still.png", "still.jpg", "still.bmp",
                                      "still.gif", "animated.gif", "lossless.webp", "lossy.webp", "animated.webp", "icon.ico", "pointer.cur"])
    }

    private func copy(_ fixture: String, as name: String) throws -> String {
        try source(name, Data(contentsOf: URL(fileURLWithPath: engineFixture(fixture))))
    }

    /// GIF, WebP, ICO and CUR import as images; the probe describes an animated GIF or WebP as a video stream with its
    /// frame count and duration (anim_dispose.gif: delays 5, 7, 12, 20 and 3 hundredths; anim.webp: 100, 50, 70,
    /// 0 shown for 100, and 30 ms), and a still as one frame.
    func testGifWebpIcoProbeFacts() throws {
        let rows: [(String, String, Bool, Int, Int, Int, Double)] = [
            ("gif/min4.gif", "gif", true, 1, 17, 13, 0), ("gif/anim_dispose.gif", "gif", false, 5, 24, 18, 0.47),
            ("webp/ll_all.webp", "webp", true, 1, 41, 29, 0), ("webp/anim.webp", "webp", false, 5, 40, 30, 0.35),
            ("ico/ff_three_sizes.ico", "ico", true, 1, 48, 40, 0),
        ]
        let probes = try rows.map { try MediaProbe.probe(path: engineFixture($0.0)) }
        let facts = probes.map { p in
            [p.container, "\(p.video?.still ?? false)", "\(p.video?.frames ?? 0)", "\(p.video?.displayWidth ?? 0)x\(p.video?.displayHeight ?? 0)",
             String(format: "%.6f", p.duration ?? -1)]
        }
        XCTAssertEqual(facts, rows.map { [$0.1, "\($0.2)", "\($0.3)", "\($0.4)x\($0.5)", String(format: "%.6f", $0.6)] })
        XCTAssertNoThrow(try probes.forEach { try ImportFormats.check($0, as: .image) })
        XCTAssertEqual(try MediaProbe.probe(path: engineFixture("gif/anim_dispose.gif")).video?.frameRate ?? 0, 5 / 0.47, accuracy: 1e-9)
    }

    func testGifWebpIcoCurAreImageKinds() {
        XCTAssertEqual(["a.gif", "a.webp", "a.ico", "a.CUR"].map { ImportFormats.kind(of: $0) }, [.image, .image, .image, .image])
        XCTAssertEqual(ProjectMediaCatalog.category(of: "a.gif"), .images)
        XCTAssertEqual(ProjectMediaCatalog.category(of: "a.cur"), .images)
    }

    /// Ogg Vorbis (.ogg, .oga) and SILK-only Ogg Opus (.opus, also Opus in .ogg) import as audio; a CELT or hybrid Opus
    /// stream is refused with a reason; the probe reports the codec,
    /// rate, channels and the duration from the last granule position. EngineFixtures/ogg: Vorbis 44100 Hz stereo
    /// 0.251 s, Vorbis 22050 Hz stereo 0.253 s, Opus CELT 48 kHz stereo 0.25 s and Opus SILK 48 kHz mono 0.5 s.
    func testImportsOggVorbisAndOpus() throws {
        let copy = { (fixture: String, name: String) throws -> String in
            let path = self.root + "/" + name
            try FileManager.default.copyItem(atPath: engineFixture("ogg/" + fixture), toPath: path)
            return path
        }
        let paths = [
            try copy("vorbis_44k_stereo.ogg", "song.ogg"),
            try copy("vorbis_22k_stereo_q2.ogg", "song.oga"),
            try copy("opus_ffcelt_stereo.opus", "voice.opus"),
            try copy("opus_silk_wb60_mono.opus", "speech.ogg"),
        ]
        let result = try importing(paths)
        // The engine decodes SILK-only Opus (speech); a CELT or hybrid stream (music) is refused by the probe with
        // the reason the import names, and the other files still import.
        XCTAssertEqual(result.invalid.map(\.name), ["voice.opus"])
        XCTAssertTrue(result.invalid.first?.reason.contains("CELT") ?? false, "\(result.invalid)")
        XCTAssertEqual(result.files, ["song.ogg", "song.oga", "speech.ogg"])
        let vorbis = try MediaProbe.probe(path: paths[0])
        XCTAssertEqual(vorbis.container, "ogg")
        XCTAssertEqual(vorbis.audio?.codec, "vorbis"); XCTAssertEqual(vorbis.audio?.sampleRate, 44_100); XCTAssertEqual(vorbis.audio?.channels, 2)
        XCTAssertEqual(vorbis.duration ?? -1, 11072.0 / 44_100, accuracy: 1e-9)
        let opus = try MediaProbe.probe(path: paths[3])
        XCTAssertEqual(opus.audio?.codec, "opus"); XCTAssertEqual(opus.audio?.sampleRate, 48_000); XCTAssertEqual(opus.audio?.channels, 1)
        XCTAssertEqual(opus.duration ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertThrowsError(try MediaProbe.probe(path: paths[2]))   // CELT: refused, not decoded
        XCTAssertEqual(ImportFormats.kind(of: "a.opus"), .audio); XCTAssertEqual(ImportFormats.kind(of: "a.OGA"), .audio)
        XCTAssertEqual(ProjectMediaCatalog.category(of: "a.opus"), .audio)
        // An Ogg file that is not Vorbis or Opus (here junk) is refused after the probe, not by its extension.
        XCTAssertNil(ImportFormats.refusal(forName: "x.ogg"))
        XCTAssertNotNil(try refusal("broken.opus", Data("OggS not really".utf8)))
    }

    /// H.264 with PCM, FLAC or AAC in every other container of formats.md imports with its sound: Matroska, AVI,
    /// MPEG-TS, M2TS (.m2ts and .mts) and MXF, each holding the streams of an MP4/MOV fixture; HEVC with AAC in
    /// Matroska imports too.
    func testImportsH264InEveryVideoContainer() throws {
        let rows: [(String, String)] = [
            ("clip.mkv", "matroska/mkv_h264_flac.mkv"), ("clip.avi", "avi/avi_h264_pcm.avi"), ("clip.ts", "mpegts/ts_h264_aac.ts"),
            ("clip.m2ts", "mpegts/m2ts_h264.m2ts"), ("clip.mts", "mpegts/m2ts_h264.m2ts"), ("clip.mxf", "mxf/mxf_h264_pcm.mxf"),
            ("hevc.mkv", "matroska/mkv_hevc_aac.mkv"),
        ]
        let paths = try rows.map { name, fixture in try source(name, Data(contentsOf: URL(fileURLWithPath: engineFixture(fixture)))) }
        let result = try importing(paths)
        XCTAssertEqual(result.invalid, [])
        XCTAssertEqual(result.files, rows.map { $0.0 })
        let described = describeImportedMedia(projectDir: root + "/project", files: rows.map { $0.0 })
        XCTAssertEqual(described.invalid, [])
        XCTAssertEqual(described.media.map { $0.hasVideo }, Array(repeating: true, count: rows.count))
        XCTAssertEqual(described.media.map { $0.width }, Array(repeating: 160, count: rows.count))
        XCTAssertEqual(described.media.compactMap { $0.notice }, [], "no clip imports silent")
        XCTAssertEqual(described.media.map { $0.hasAudio }, [true, true, true, false, false, true, true])
    }

    /// A container that imports can still hold a codec that lands later: the refusal names the codec in it.
    func testRefusesLaterCodecsInsideTheNewContainers() throws {
        let rows: [(String, String, String)] = [
            ("clip.webm", "matroska/webm_vp9_opus.webm", "vp9 in webm"),
            ("clip.ts", "mpegts/ts_hevc.ts", "hevc in ts"), ("clip.mxf", "mxf/mxf_mpeg2.mxf", "mpeg video in mxf"),
        ]
        let refusals = try rows.map { name, fixture, _ in try refusal(name, Data(contentsOf: URL(fileURLWithPath: engineFixture(fixture)))) }
        XCTAssertEqual(refusals, rows.map { "This video format is not supported yet: \($0.2)." })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root + "/project"), [])
    }

    func testRefusesLaterFormatsByExtensionWithTheTableMessages() throws {
        let bytes = Data("not media".utf8)
        let images = ["avif", "svg"]
        XCTAssertEqual(try images.map { try refusal("image.\($0)", bytes) }, images.map { "This image format is not supported yet: \($0)." })
        // The video containers are no longer refused by name: bytes that are not media fail the probe instead.
        let containers = ["clip.webm", "clip.mkv", "clip.avi", "clip.ts", "clip.mts", "clip.m2ts", "clip.mxf"]
        XCTAssertEqual(containers.map { ImportFormats.refusal(forName: $0) }, Array(repeating: nil, count: containers.count))
        XCTAssertEqual(try containers.map { try refusal($0, bytes) != nil }, Array(repeating: true, count: containers.count))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root + "/project"), [])
    }

    /// ProRes, VP9 and AV1 tracks in MP4/MOV are refused with "<codec> in <container>".
    func testRefusesLaterVideoCodecsInsideMP4AndMOV() throws {
        let rows: [(String, Bool, String)] = [
            ("apcn", true, "prores in mov"), ("vp09", false, "vp9 in mp4"), ("av01", false, "av1 in mp4"),
        ]
        let refused = try rows.map { fourcc, quicktime, _ in
            try refusal("clip-\(fourcc).\(quicktime ? "mov" : "mp4")", TestMedia.movie([TestMedia.opaqueVideoTrack(fourcc)], quicktime: quicktime))
        }
        XCTAssertEqual(refused, rows.map { "This video format is not supported yet: \($0.2)." })
    }

    /// HEVC (the engine's decoder): an iPhone-style portrait MOV and HEVC MP4s import; an MP4 whose
    /// sound is MP3 imports without sound and says why.
    func testImportsHEVCVideos() throws {
        let paths = [
            try source("phone.mov", Data(contentsOf: URL(fileURLWithPath: engineFixture("hevc/hvc1_rot90.mov")))),
            try source("phone.mp4", Data(contentsOf: URL(fileURLWithPath: engineFixture("isobmff/hevc.mp4")))),
            try source("phone-mp2.mp4", Data(contentsOf: URL(fileURLWithPath: engineFixture("hevc/hev1_mp2.mp4")))),
            try source("phone-mp3.mp4", Data(contentsOf: URL(fileURLWithPath: engineFixture("hevc/hevc_mp3.mp4")))),
        ]
        let result = try importing(paths)
        XCTAssertEqual(result.invalid, [])
        XCTAssertEqual(result.files, ["phone.mov", "phone.mp4", "phone-mp2.mp4", "phone-mp3.mp4"])
        let described = describeImportedMedia(projectDir: root + "/project", files: result.files)
        XCTAssertEqual(described.invalid, [])
        let byName = Dictionary(uniqueKeysWithValues: described.media.map { ($0.name, $0) })
        let phone = try XCTUnwrap(byName["phone.mov"])
        XCTAssertTrue(phone.hasVideo); XCTAssertEqual(phone.width, 90); XCTAssertEqual(phone.height, 160)
        XCTAssertTrue(try XCTUnwrap(byName["phone-mp2.mp4"]).hasAudio)
        let silent = try XCTUnwrap(byName["phone-mp3.mp4"])
        XCTAssertFalse(silent.hasAudio); XCTAssertEqual(silent.notice, "This audio format is not supported yet: mp3.")
    }

    /// MPEG audio: Layer II files import (also when named .mp3); Layer III (MP3) is refused by the probe.
    func testMPEGAudioLayerTwoImportsAndMP3IsRefused() throws {
        let mp2 = try Data(contentsOf: URL(fileURLWithPath: engineFixture("mpa/l2_48k_stereo_192k_id3.mp2")))
        let result = try importing([try source("song.mp2", mp2), try source("layer2.mp3", mp2)])
        XCTAssertEqual(result.invalid, [])
        XCTAssertEqual(result.files, ["song.mp2", "layer2.mp3"])
        let mp3 = try Data(contentsOf: URL(fileURLWithPath: engineFixture("mpa/l3_48k_stereo_128k.mp3")))
        XCTAssertEqual(try refusal("song.mp3", mp3), "This audio format is not supported yet: mp3.")
    }

    /// AAC (formats.md v1, decoded by mpvfx-media crates/aac): AAC-only M4A and ADTS files import as audio, and a
    /// video with AAC sound imports with its sound and no notice.
    func testAACImportsAudioFilesAndVideosWithSound() throws {
        let m4a = try source("voice.m4a", Data(contentsOf: URL(fileURLWithPath: engineFixture("isobmff/mp4_aac.mp4"))))
        let adts = try source("voice.aac", Data(contentsOf: URL(fileURLWithPath: engineFixture("aac/lc_44k_stereo.aac"))))
        let frame = TestMedia.solid((0, 0, 255), width: 16, height: 8)
        let video = try source("talk.mp4", TestMedia.movie([TestMedia.pngTrack([frame, frame], width: 16, height: 8), TestMedia.aacTrack()]))
        let result = try importing([m4a, adts, video])
        XCTAssertEqual(result.invalid, [])
        XCTAssertEqual(result.files, ["voice.m4a", "voice.aac", "talk.mp4"])
        let described = describeImportedMedia(projectDir: root + "/project", files: ["voice.m4a", "voice.aac", "talk.mp4"])
        XCTAssertEqual(described.invalid, [])
        XCTAssertEqual(described.media.map(\.hasAudio), [true, true, true])
        XCTAssertEqual(described.media.map(\.notice), [nil, nil, nil])
        let media = try XCTUnwrap(described.media.last)
        XCTAssertTrue(media.hasVideo)
        XCTAssertEqual(media.width, 16); XCTAssertEqual(media.height, 8)
    }

    func testRefusesFilesWhoseContentsAreNotTheirKind() throws {
        let noVideo = TestMedia.wav(TestMedia.tone(seconds: 0.1, rate: 8000), rate: 8000, channels: 1)
        XCTAssertEqual(try refusal("renamed.mp4", noVideo), "This file has no video track.")
        XCTAssertNotNil(try refusal("garbage.png", Data("not a picture".utf8)))
        XCTAssertNotNil(try refusal("garbage.gif", Data("not a picture".utf8)))
        XCTAssertNotNil(try refusal("garbage.webp", Data("RIFF\u{4}\0\0\0WEBP".utf8)))
        XCTAssertNotNil(try refusal("garbage.ico", Data([0, 0, 1, 0, 1, 0])))
        XCTAssertNotNil(try refusal("garbage.wav", Data("not a sound".utf8)))
        let silent = TestMedia.movie([TestMedia.pngTrack([TestMedia.solid((1, 1, 1), width: 4, height: 4)], width: 4, height: 4)])
        XCTAssertEqual(try refusal("silent.m4a", silent), "This file has no audio track.")
    }

    func testKindCoversTheEngineOnlyFormatsAndListsThemInTheProject() {
        XCTAssertEqual(ImportFormats.kind(of: "a.flac"), .audio)
        XCTAssertEqual(ImportFormats.kind(of: "a.BMP"), .image)
        let videoExtensions = ["webm", "mkv", "avi", "ts", "mts", "m2ts", "mxf", "MKV"]
        XCTAssertEqual(videoExtensions.map { ImportFormats.kind(of: "a.\($0)") }, Array(repeating: .video, count: videoExtensions.count))
        XCTAssertEqual(ProjectMediaCatalog.category(of: "a.mxf"), .video)
        XCTAssertEqual(ImportFormats.kind(of: "a.cube"), .lut)
        XCTAssertNil(ImportFormats.kind(of: "a.txt"))
        XCTAssertEqual(ProjectMediaCatalog.category(of: "a.flac"), .audio)
        XCTAssertEqual(ProjectMediaCatalog.category(of: "a.bmp"), .images)
    }
}
