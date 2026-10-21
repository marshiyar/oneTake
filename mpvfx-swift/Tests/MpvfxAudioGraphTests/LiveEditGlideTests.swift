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

/// Live parameter edits on a running graph (`AudioGraphRenderer.applyParameterEdits`): a slider move glides to its
/// value over `LiveEdit.glideSeconds` instead of stepping, so it is not heard as a click; an edit before the first
/// rendered frame still gives exactly the graph built with the new value; and after the glide a stateless chain is
/// sample-identical to the export render of the edited project.
final class LiveEditGlideTests: XCTestCase {
    static let sr = 48000.0
    static let tone = 1000.0, amp = 0.3

    /// A 1 kHz sine at 0.3, one second, as both stereo planes.
    static let stem: [[Float]] = {
        let p = (0..<48000).map { (i: Int) -> Float in Float(amp * sin(2 * Double.pi * tone * Double(i) / sr)) }
        return [p, p]
    }()

    static func project(chain: String?, volume: Double = 1) throws -> AudioGraphProject {
        let fx = try chain.map { try AudioFx.parseChain($0) }
        return AudioGraphProject(duration: 1, sampleRate: sr, tracks: [
            AudioGraphTrack(id: "a", stem: stem, start: 0, end: 1, volume: volume, fxChain: fx),
        ], quantizeIntermediates: false)
    }
    static func gain(_ db: Double) -> String { #"{"version":1,"nodes":[{"type":"gain","id":"g","params":{"gain":\#(db)}}]}"# }
    static func peaking(_ db: Double) -> String {
        #"{"version":1,"nodes":[{"type":"peaking","id":"p","params":{"frequency":1000,"gain":\#(db),"q":1}}]}"#
    }

    /// Largest second difference |x[n+1] - 2x[n] + x[n-1]| of the left channel: a click (a step in level or slope)
    /// is a spike in it, while a sine whose level glides keeps it near the sine's own.
    func maxCurvature(_ interleaved: [Float]) -> Double {
        var worst = 0.0
        for k in stride(from: 4, to: interleaved.count, by: 2) {
            worst = max(worst, abs(Double(interleaved[k]) - 2 * Double(interleaved[k - 2]) + Double(interleaved[k - 4])))
        }
        return worst
    }
    /// A clean sine of amplitude `a`: its largest second difference, a (2 sin(ω/2))².
    static func sineCurvature(_ a: Double) -> Double { a * pow(2 * sin(Double.pi * tone / sr), 2) }

    /// Renders 0.25 s, applies `next` in place, and returns the 30 ms after the edit with the two frames before it.
    func edit(_ before: AudioGraphProject, to next: AudioGraphProject) -> [Float] {
        let r = AudioGraphRenderer(before)
        _ = r.render(12000 - 2)
        let lead = r.render(2)
        XCTAssertTrue(r.applyParameterEdits(next), "the edit must apply in place")
        return lead + r.render(1440)
    }

    func testGainNodeEditGlidesInsteadOfStepping() throws {
        let out = edit(try Self.project(chain: Self.gain(0)), to: try Self.project(chain: Self.gain(-30)))
        XCTAssertLessThan(maxCurvature(out), 1.5 * Self.sineCurvature(Self.amp), "a -30 dB gain move is a step in the signal (a click)")
    }

    func testPeakingGainEditGlidesInsteadOfStepping() throws {
        // +18 dB at the tone's own frequency: the step a click would be is ~8x the sine's own slope.
        let out = edit(try Self.project(chain: Self.peaking(0)), to: try Self.project(chain: Self.peaking(18)))
        XCTAssertLessThan(maxCurvature(out), 1.5 * Self.sineCurvature(Self.amp * pow(10, 18.0 / 20)), "an EQ band move clicks")
    }

    func testClipVolumeEditGlidesInsteadOfStepping() throws {
        let out = edit(try Self.project(chain: nil, volume: 1), to: try Self.project(chain: nil, volume: 0.05))
        XCTAssertLessThan(maxCurvature(out), 1.5 * Self.sineCurvature(Self.amp), "a fader move clicks")
    }

    func testEditBeforeTheFirstFrameIsTheEditedGraphExactly() throws {
        let next = try Self.project(chain: Self.gain(-12), volume: 0.5)
        let r = AudioGraphRenderer(try Self.project(chain: Self.gain(0), volume: 1))
        XCTAssertTrue(r.applyParameterEdits(next))
        XCTAssertTrue(r.renderAll() == AudioGraphRenderer.renderOffline(next))
    }

    func testAfterTheGlideAStatelessChainEqualsTheExportRender() throws {
        let next = try Self.project(chain: Self.gain(-12), volume: 0.5)
        let r = AudioGraphRenderer(try Self.project(chain: Self.gain(0), volume: 1))
        _ = r.render(12000)
        XCTAssertTrue(r.applyParameterEdits(next))
        let glide = LiveEdit.glideFrames(Self.sr)
        // The chain runs in 128-frame quanta, so its glide starts at the next quantum the edit reaches: up to one late.
        let window = glide + dspBlockSize
        let during = r.render(window)
        let after = r.render(4800)
        let export = AudioGraphRenderer.renderOffline(next)
        XCTAssertTrue(after == Array(export[(2 * (12000 + window))..<(2 * (12000 + window + 4800))]), "settled output differs from export")
        XCTAssertFalse(during == Array(export[(2 * 12000)..<(2 * (12000 + window))]), "the edit glided rather than jumped")
    }

    func testGlideIsLinearAndEndsExactlyOnTheTarget() {
        var g = LiveGlide(from: 1, to: 0, frames: 4)
        XCTAssertEqual((0..<4).map { _ in g.next() }, [0.75, 0.5, 0.25, 0])
        XCTAssertTrue(g.finished)
        XCTAssertEqual(g.next(), 0)
        XCTAssertEqual(LiveEdit.glideFrames(48000), 960)
    }
}
