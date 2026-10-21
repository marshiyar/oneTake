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
import MpvfxShared
import MpvfxAudioGraph
@testable import MpvfxAudio

/// What the listener hears around a live change: a rebuilt graph (bypass, add, remove, a parameter that cannot change
/// in place) crossfades in over `declickFrames` instead of switching at one sample, the transport gain and mute ramp,
/// and once the window has passed the output is the export render again, sample for sample.
final class LiveDeclickTests: XCTestCase {
    static let sr = 48000.0, tone = 1000.0, amp = 0.3

    static let stem: [[Float]] = {
        let p = (0..<96000).map { (i: Int) -> Float in Float(amp * sin(2 * Double.pi * tone * Double(i) / sr)) }
        return [p, p]
    }()

    /// A 2 s sine through a -30 dB gain node, enabled or bypassed.
    static func project(bypassed: Bool) throws -> AudioGraphProject {
        let enabled = bypassed ? #","enabled":false"# : ""
        let chain = try AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"gain","id":"g"\#(enabled),"params":{"gain":-30}}]}"#)
        return AudioGraphProject(duration: 2, sampleRate: sr, tracks: [AudioGraphTrack(id: "a", stem: stem, start: 0, end: 2, fxChain: chain)])
    }

    func maxStep(_ interleaved: [Float]) -> Double {
        var worst = 0.0
        for k in stride(from: 2, to: interleaved.count, by: 2) { worst = max(worst, Double(abs(interleaved[k] - interleaved[k - 2]))) }
        return worst
    }
    static let sineStep = 2 * Double.pi * tone * amp / sr

    func slice(_ a: [Float], frame: Int, frames: Int) -> [Float] { Array(a[(2 * frame)..<(2 * (frame + frames))]) }

    func testBypassWhilePlayingCrossfadesInsteadOfSwitchingAtOneSample() throws {
        let src = GraphAudioSource(project: try Self.project(bypassed: false))
        src.seek(0.5)
        let before = src.render(frames: 1280)
        src.replace(try Self.project(bypassed: true))
        XCTAssertEqual(src.lastReplace, .rebuilt)
        let after = src.render(frames: 2 * src.declickFrames)
        XCTAssertLessThan(maxStep(Array(before.suffix(2)) + after), 1.2 * Self.sineStep, "bypass switches the graph at one sample (a click)")
    }

    func testAfterTheCrossfadeLiveIsTheExportRenderExactly() throws {
        let edited = try Self.project(bypassed: true)
        let src = GraphAudioSource(project: try Self.project(bypassed: false))
        src.seek(0.5)
        _ = src.render(frames: 1280)
        src.replace(edited)
        let at = src.position
        let fade = src.declickFrames
        let during = src.render(frames: fade)
        let offline = AudioGraphRenderer.renderOffline(edited)
        XCTAssertFalse(during == slice(offline, frame: at, frames: fade), "the swap faded rather than jumped")
        XCTAssertTrue(src.render(frames: 4800) == slice(offline, frame: at + fade, frames: 4800), "live differs from export after the fade")
    }

    func testARebuildBeforeAnythingPlayedSwitchesAtOnce() throws {
        let edited = try Self.project(bypassed: true)
        let src = GraphAudioSource(project: try Self.project(bypassed: false))
        src.seek(0.5)
        src.replace(edited)
        XCTAssertTrue(src.render(frames: 2048) == slice(AudioGraphRenderer.renderOffline(edited), frame: 24000, frames: 2048),
                      "nothing was heard yet, so there is nothing to fade from")
    }

    func testTransportGainAndMuteRampInsteadOfStepping() throws {
        let src = GraphAudioSource(project: try Self.project(bypassed: true))
        src.seek(0.5)
        var heard = src.render(frames: 1280)
        src.masterGain = 0.1
        heard += src.render(frames: 1280)
        src.muted = true
        heard += src.render(frames: 1280)
        XCTAssertTrue(src.render(frames: 128).allSatisfy { $0 == 0 }, "muted after the ramp")
        src.muted = false; src.masterGain = 1
        heard += src.render(frames: 1280)
        XCTAssertLessThan(maxStep(heard), 1.2 * Self.sineStep, "a gain or mute change steps the signal (a click)")
    }
}
