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
// Muted audio groups export silently. Fixtures/muteParity.json holds reference audio windows recorded from the
// original renderer; the Swift export must match them within 0.001 RMS per 100 ms window. The inputs follow the
// generator's recipe (FFmpeg lavfi sines at their default 1/8 amplitude, a red/green 64x32 picture at 10 fps), made
// here with our own code: WAV bytes written directly, the videos by MediaWriter (MP4 = H.264 + FLAC).
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime

final class MuteParityTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/muteParity.json")
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("mute-parity-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        installAppExportFrames()
        let dir = Self.root
        guard !FileManager.default.fileExists(atPath: "\(dir)/silent.mp4") else { return }
        try TestMedia.write(TestVideo(tone: 440, container: .mp4), to: "\(dir)/red.mp4")
        try TestMedia.wav(660, seconds: 2, to: "\(dir)/voice.wav")
        try TestMedia.wav(220, seconds: 2, to: "\(dir)/bed.wav")
        try TestMedia.write(TestVideo(color: { _ in [0, 255, 0] }, container: .mp4), to: "\(dir)/silent.mp4")
    }

    func load() throws -> (scenarios: NativeJSONObject, results: NativeJSONObject) {
        let json = try NativeJSONValue.parse(String(contentsOf: Self.fixture, encoding: .utf8)).objectValue!
        return (json["scenarios"]!.objectValue!, json["results"]!.objectValue!)
    }
    func render(_ name: String, _ scenario: NativeJSONValue) throws -> String {
        let output = "\(Self.root)/\(name).mp4"
        try? FileManager.default.removeItem(atPath: output)
        try renderNativeTimeline(.init(project: try parseNativeProjectDocument(scenario), projectDir: Self.root, outputPath: output, format: .mp4))
        return output
    }
    /// RMS of the mono mix per 100 ms window over the first second (the generator's windows).
    func windows(_ path: String) throws -> [Double] {
        let stereo = try Exported(path: path).audio()
        return stride(from: 0, to: 48_000, by: 4800).filter { $0 + 4800 <= stereo.count / 2 }
            .map { TestAudio.rms(stereo, from: $0, count: 4800) }
    }
    func expected(_ results: NativeJSONObject, _ name: String) -> [Double] {
        results[name]!.objectValue!["rms"]!.arrayValue!.compactMap { $0.numberValue }
    }

    /// The original's muted variants all decode to the same audio: the group contributes nothing.
    func testOriginalMutedGroupIsFullySilentWhateverItsFXAutomationOrVolume() throws {
        let (_, results) = try load()
        let plain = expected(results, "plainMutedGroup")
        XCTAssertEqual(plain.count, 10)
        for name in ["mutedGroupWithBusFx", "mutedGroupWithBusAutomation", "mutedGroupMemberWithFx", "mutedGroupMemberWithAutomation", "mutedGroupAtHalfVolume"] {
            XCTAssertEqual(expected(results, name), plain, name)
        }
        // Voice-only level (660 Hz sine at ffmpeg's default 1/8 amplitude => RMS ~0.0884), so the 440/220 Hz members add nothing.
        for v in plain { XCTAssertEqual(v, 0.125 / 2.0.squareRoot(), accuracy: 0.002) }
    }

    /// Swift drops the muted group; its mixed output matches the recorded render and the recorded "dropped" reference.
    func testDroppingAPlainMutedGroupLeavesTheMixedOutputUnchanged() throws {
        let (scenarios, results) = try load()
        for name in ["plainMutedGroup", "mutedGroupAtHalfVolume", "droppedReference"] {
            let got = try windows(try render(name, scenarios[name]!))
            let want = expected(results, name)
            XCTAssertEqual(got.count, want.count, name)
            // The references were recorded through an AAC re-encode; Swift mixes through the bus/FX
            // graph and stores FLAC (16-bit). 0.001 is the tolerance the AAC references were recorded with.
            for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: 0.001, name) }
        }
    }

    /// Decision D4 (Oct 13): match the recorded behaviour. A muted group with bus/member FX or automation exports silently.
    func testMutedGroupWithFXOrAutomationExportsSilentlyLikeTheOriginal() throws {
        let (scenarios, results) = try load()
        for name in ["mutedGroupWithBusFx", "mutedGroupWithBusAutomation", "mutedGroupMemberWithFx", "mutedGroupMemberWithAutomation"] {
            XCTAssertEqual(results[name]!.objectValue!["ok"], .bool(true), "recorded export of \(name) succeeded")
            let got = try windows(try render(name, scenarios[name]!))
            let want = expected(results, name)
            XCTAssertEqual(got.count, want.count, name)
            for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: 0.001, name) }
        }
    }

    /// The audio-stream check runs before muted groups are skipped, so this still fails (as recorded).
    func testMutedGroupMemberWithoutAnAudioStreamFailsLikeTheOriginal() throws {
        let (scenarios, results) = try load()
        let want = results["mutedGroupMemberWithoutAudioStream"]!.objectValue!["error"]!.stringValue!
        XCTAssertThrowsError(try render("noStream", scenarios["mutedGroupMemberWithoutAudioStream"]!)) { XCTAssertEqual("\($0)", want) }
    }
}
