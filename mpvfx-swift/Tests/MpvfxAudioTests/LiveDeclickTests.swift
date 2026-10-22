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

    func testABSwitchUsesRebuildCrossfadeAndSettlesWithin20ms() throws {
        var chain = try AudioFx.parseChain(#"{"version":2,"nodes":[{"type":"gain","id":"g","params":{"gain":-30}}]}"#)
        chain.nodes[0].copyAToB()
        chain.nodes[0].paramsB?["gain"] = .number(0)
        func project(_ c: FxChain) -> AudioGraphProject {
            AudioGraphProject(duration: 2, sampleRate: Self.sr, tracks: [AudioGraphTrack(id: "a", stem: Self.stem, start: 0, end: 2, fxChain: c)])
        }
        let source = GraphAudioSource(project: project(chain))
        source.seek(0.5)
        let before = source.render(frames: 1280)
        chain.nodes[0].selectSlotB(true)
        let edited = project(chain)
        source.replace(edited)
        XCTAssertEqual(source.lastReplace, .rebuilt)
        XCTAssertLessThanOrEqual(Double(source.declickFrames) / Self.sr, 0.020)
        let start = source.position
        let after = source.render(frames: 960)
        let heard = Array(before.suffix(4)) + after
        XCTAssertLessThan(maxStep(heard), 1.2 * Self.sineStep)
        var curvature = 0.0
        for i in stride(from: 4, to: heard.count, by: 2) {
            curvature = max(curvature, Double(abs(heard[i] - 2 * heard[i - 2] + heard[i - 4])))
        }
        XCTAssertLessThan(curvature, 1.5 * Self.amp * pow(2 * .pi * Self.tone / Self.sr, 2))
        let offline = AudioGraphRenderer.renderOffline(edited)
        XCTAssertEqual(source.render(frames: 128), slice(offline, frame: start + 960, frames: 128))
    }

    func testBypassWhilePlayingCrossfadesInsteadOfSwitchingAtOneSample() throws {
        let src = GraphAudioSource(project: try Self.project(bypassed: false))
        src.seek(0.5)
        let before = src.render(frames: 1280)
        src.replace(try Self.project(bypassed: true))
        XCTAssertEqual(src.lastReplace, .rebuilt)
        let after = src.render(frames: 2 * src.declickFrames)
        XCTAssertLessThan(maxStep(Array(before.suffix(2)) + after), 1.2 * Self.sineStep, "bypass switches the graph at one sample (a click)")
    }

    /// Edits faster than the fade: a second rebuild 128 frames into the first fade crossfades from the blend that is
    /// being heard, not from the graph that was only partly faded in.
    func testASecondRebuildMidFadeFadesFromWhatIsHeard() throws {
        let src = GraphAudioSource(project: try Self.project(bypassed: false))
        src.seek(0.5)
        var heard = src.render(frames: 1280)
        src.replace(try Self.project(bypassed: true))
        heard += src.render(frames: 128)
        src.replace(try Self.project(bypassed: false))
        XCTAssertEqual(src.lastReplace, .rebuilt)
        heard += src.render(frames: 3 * src.declickFrames)
        XCTAssertLessThan(maxStep(heard), 1.2 * Self.sineStep, "the second swap drops the fade in flight (a click)")
        let at = src.position
        XCTAssertTrue(src.render(frames: 1280) == slice(AudioGraphRenderer.renderOffline(try Self.project(bypassed: false)), frame: at, frames: 1280),
                      "both fades done: the last edit plays alone, as export renders it")
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
