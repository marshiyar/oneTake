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
import XCTest
@testable import MpvfxAudioGraph

/// Clip fades in the graph (issue #85): `AudioGraphTrack.fadeIn` / `fadeOut` are a linear gain ramp on the clip's
/// stem, applied before its FX chain, rendered the same block by block (live playback) and in export's chunks.
final class ClipFadeTests: XCTestCase {
    static let sr = 48_000.0

    /// One clip, `seconds` long from 0, of constant 0.5 (exact in 16 bits, so the s16 intermediates keep it exact).
    static func project(seconds: Double = 2, fadeIn: Double = 0, fadeOut: Double = 0, fxChain: FxChain? = nil) -> AudioGraphProject {
        let n = Int(seconds * sr)
        let plane = [Float](repeating: 0.5, count: n)
        var track = AudioGraphTrack(id: "c", stem: [plane, plane], start: 0, end: seconds, fxChain: fxChain)
        track.fadeIn = fadeIn; track.fadeOut = fadeOut
        return AudioGraphProject(duration: seconds, tracks: [track])
    }

    /// Live playback's partition: 128-frame blocks from frame 0.
    static func live(_ p: AudioGraphProject) -> [Float] {
        let r = AudioGraphRenderer(p)
        var out: [Float] = []
        while r.position < r.totalFrames { out += r.render(128) }
        return out
    }

    /// Export's partition (`ExportAudioMix`): one renderer, `advance(to:)`, then one chunk per video frame (30 fps).
    static func export(_ p: AudioGraphProject) -> [Float] {
        let r = AudioGraphRenderer(p)
        r.advance(to: 0)
        var out: [Float] = []
        while r.position < r.totalFrames { out += r.render(1600) }
        return out
    }

    /// Left-channel gain at `seconds` relative to the unfaded 0.5.
    static func gain(_ mix: [Float], at seconds: Double) -> Double { Double(mix[2 * Int(seconds * sr)]) / 0.5 }

    func testOneSecondFadeInRampsFromZeroToFullGainLiveAndInExport() {
        let p = Self.project(fadeIn: 1)
        let live = Self.live(p), export = Self.export(p)
        XCTAssertEqual(live.count, p.totalFrames * 2)
        XCTAssertTrue(live == export, "live playback and export render the same samples")
        assertOneSecondFadeIn(live, "live")
        assertOneSecondFadeIn(export, "export")
    }

    func assertOneSecondFadeIn(_ mix: [Float], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Self.gain(mix, at: 0), 0, "\(name): the first sample is silent", file: file, line: line)
        XCTAssertEqual(Self.gain(mix, at: 0.25), 0.25, accuracy: 1e-4, name, file: file, line: line)
        XCTAssertEqual(Self.gain(mix, at: 0.5), 0.5, accuracy: 1e-4, name, file: file, line: line)
        let unfaded = (2 * Int(Self.sr)..<mix.count).filter { mix[$0] != 0.5 }
        XCTAssertEqual(unfaded, [], "\(name): full gain from 1 s", file: file, line: line)
    }

    func testFadeOutRampsDownToTheClipEnd() {
        let p = Self.project(fadeOut: 0.5)
        let mix = Self.live(p)
        XCTAssertEqual(Self.gain(mix, at: 1.4), 1)
        XCTAssertEqual(Self.gain(mix, at: 1.5), 1, accuracy: 1e-4)
        XCTAssertEqual(Self.gain(mix, at: 1.75), 0.5, accuracy: 1e-4)
        XCTAssertEqual(Double(mix[2 * (p.totalFrames - 1)]) / 0.5, 1 / (0.5 * Self.sr), accuracy: 1e-4, "the last sample is nearly silent")
        XCTAssertTrue(mix == Self.export(p))
    }

    func testNoFadesRenderTheSameSamplesAsBefore() {
        let plain = Self.project()
        XCTAssertTrue(Self.live(plain).allSatisfy { $0 == 0.5 }, "no fade fields: unity gain everywhere")
    }

    func testFadesReachTheClipThroughItsFxChain() throws {
        let chain = try AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"gain","id":"g","params":{"gain":-6}}]}"#)
        let mix = Self.live(Self.project(fadeIn: 1, fxChain: chain))
        let full = Double(mix[2 * Int(1.5 * Self.sr)])
        XCTAssertGreaterThan(full, 0.1)
        XCTAssertEqual(Double(mix[2 * Int(0.5 * Self.sr)]) / full, 0.5, accuracy: 1e-3, "the ramp runs into the chain")
        XCTAssertEqual(mix[0], 0)
    }

    func testAFadeChangeIsNotAnInPlaceParameterEdit() {
        let r = AudioGraphRenderer(Self.project(fadeIn: 1))
        XCTAssertFalse(r.applyParameterEdits(Self.project(fadeIn: 0.5)), "a new ramp needs a new renderer")
        XCTAssertFalse(r.applyParameterEdits(Self.project(fadeIn: 1, fadeOut: 0.2)))
    }
}
