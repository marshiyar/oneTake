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
import XCTest
@testable import MpvfxAudioGraph

/// The export audio assertions (grouped buses, gain, mute, FX, trims and gaps) run
/// against the graph
/// instead of the encoded export (same rms windows, same tolerances).
final class NativeTimelinePortTests: XCTestCase {
    // The sines are amplitude 1/8; the fixtures there are 440/880/660 Hz.
    let red = sine(440, seconds: 2), blue = sine(880, seconds: 2), voice = sine(660, seconds: 2)

    /// toBeCloseTo(x, 1): |a - x| < 0.05.
    func closeTo(_ a: Double, _ x: Double, _ m: String = "") { XCTAssertLessThan(abs(a - x), 0.05, "\(a) vs \(x) \(m)") }

    func testDetachedSoundRendersOnce() {
        let baseline = AudioGraphRenderer.renderOffline(.init(duration: 1, tracks: [.init(id: "red", stem: red, start: 0, end: 1)]))
        // Detached: the video clip's own audio is excluded, the detached clip carries it.
        let detached = AudioGraphRenderer.renderOffline(.init(duration: 1, tracks: [
            .init(id: "red", stem: red, start: 0, end: 1, muted: true),
            .init(id: "red-audio-clip", stem: red, start: 0, end: 1)]))
        closeTo(rms(detached, at: 0.2) / rms(baseline, at: 0.2), 1)
    }

    func testBusGainAndMute() {
        func doc(_ volume: Double, muted: Bool = false) -> AudioGraphProject {
            .init(duration: 1, tracks: [.init(id: "red", stem: red, start: 0, end: 1, groupId: "dialogue"),
                                        .init(id: "voice-clip", stem: voice, start: 0, end: 1, groupId: "dialogue")],
                  groups: [.init(id: "dialogue", volume: volume, muted: muted)])
        }
        let full = AudioGraphRenderer.renderOffline(doc(1))
        XCTAssertGreaterThan(rms(full, at: 0.2), 0.01)
        closeTo(rms(AudioGraphRenderer.renderOffline(doc(0.25)), at: 0.2) / rms(full, at: 0.2), 0.25)
        let muted = AudioGraphRenderer(doc(1, muted: true))
        XCTAssertEqual(muted.inputs.count, 0, "a muted bus contributes no stream")
        XCTAssertTrue(muted.renderAll().allSatisfy { $0 == 0 })
    }

    func testGroupedTracksKeepTrimAndGapPositions() {
        // red: frames 0..5 at 10 fps (0–0.5 s, source in 0.5 s, 2x speed — pre-rendered stem);
        // blue: 1.0–1.5 s. Both unmuted in group "videos" at volume 0.5.
        let redStem = [Array(red[0][24000..<72000]), Array(red[1][24000..<72000])]
        let p = AudioGraphProject(duration: 1.5, tracks: [
            .init(id: "red", stem: redStem, start: 0, end: 0.5, groupId: "videos"),
            .init(id: "blue", stem: blue, start: 1.0, end: 1.5, groupId: "videos")],
            groups: [.init(id: "videos", volume: 0.5)])
        let out = AudioGraphRenderer.renderOffline(p)
        XCTAssertGreaterThan(rms(out, at: 0.2), 0.005)
        XCTAssertLessThan(rms(out, at: 0.7), 0.001)
        XCTAssertGreaterThan(rms(out, at: 1.2), 0.005)
    }

    func testBusFxChainAppliesMinus6dB() {
        let gain = try! AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"gain","params":{"gain":-6},"enabled":true}]}"#)
        func doc(_ chain: FxChain?) -> AudioGraphProject {
            .init(duration: 1, tracks: [.init(id: "red", stem: red, start: 0, end: 1, groupId: "fx")], groups: [.init(id: "fx", volume: 1, fxChain: chain)])
        }
        closeTo(rms(AudioGraphRenderer.renderOffline(doc(gain)), at: 0.2) / rms(AudioGraphRenderer.renderOffline(doc(nil)), at: 0.2), pow(10, -6.0 / 20))
    }

    func testClipFxChainAppliesMinus6dB() {
        let gain = try! AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"gain","params":{"gain":-6},"enabled":true}]}"#)
        func doc(_ chain: FxChain?) -> AudioGraphProject { .init(duration: 1, tracks: [.init(id: "clip-fx-clip", stem: red, start: 0, end: 1, fxChain: chain)]) }
        closeTo(rms(AudioGraphRenderer.renderOffline(doc(gain)), at: 0.2) / rms(AudioGraphRenderer.renderOffline(doc(nil)), at: 0.2), pow(10, -6.0 / 20))
    }

    func testCutsGapsAndMute() {
        let redStem = [Array(red[0][24000..<72000]), Array(red[1][24000..<72000])]
        let out = AudioGraphRenderer.renderOffline(.init(duration: 1.5, tracks: [
            .init(id: "red", stem: redStem, start: 0, end: 0.5),
            .init(id: "blue", stem: blue, start: 1.0, end: 1.5, muted: true)]))
        XCTAssertGreaterThan(rms(out, at: 0.2), 0.01)
        XCTAssertLessThan(rms(out, at: 0.7), 0.001)
        XCTAssertLessThan(rms(out, at: 1.2), 0.001)
        XCTAssertEqual(Double(out.count / 2) / 48000, 1.5, accuracy: 0.05)
    }
}
