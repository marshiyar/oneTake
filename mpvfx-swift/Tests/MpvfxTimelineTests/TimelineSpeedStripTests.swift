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
import OneTakeKeyframes
import MpvfxCanvas
import MpvfxTheme
@testable import MpvfxTimeline
@testable import MpvfxShared

/// The speed strip on a ramped clip (issue #271): the timeline's clip model carries the ramp only when it is one this
/// build understands, and the strip's colour is faint at 1x, accent below it and white above it, strongest at the ends.
final class TimelineSpeedStripTests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":32,"background":"#000000"},
     "assets":[{"id":"a1","kind":"video","name":"One","source":"a.mov","durationFrames":600}],
     "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
       {"id":"A","assetId":"a1","startFrame":0,"durationFrames":100,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """#

    func testTheClipModelCarriesTheRampOnlyWhileTheClipIsRamped() throws {
        let e = try TimelineEditor(json: Self.json, engine: try KeyframeRuntime())
        XCTAssertNil(e.tracks[0].clips[0].speedRamp, "a constant clip has no strip")
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.slowMiddle)))
        let ramp = try XCTUnwrap(e.tracks[0].clips[0].speedRamp)
        XCTAssertEqual(ramp, e.speedRamp(of: "A"))
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .clear))
        XCTAssertNil(e.tracks[0].clips[0].speedRamp, "clearing the ramp removes the strip")
    }

    func testAnUnsupportedRampDrawsNoStrip() throws {
        let e = try TimelineEditor(json: Self.json.replacingOccurrences(of: #""sourceInFrame":0,"#, with: #""sourceInFrame":0,"speedRamp":{"v":2,"kind":"speed-ramp","points":[{"t":0,"speed":2}]},"#),
                                   engine: try KeyframeRuntime())
        XCTAssertNil(e.tracks[0].clips[0].speedRamp, "a ramp from a newer version is kept but not drawn")
        XCTAssertNotNil(e.clip("A")?.clip.speedRamp)
    }

    func testTheStripColourIsFaintAtOneTimesAndStrongestAtTheEnds() {
        let one = TimelineView.speedStripColor(speed: 1)
        XCTAssertEqual(one.a, 0.3, accuracy: 1e-9)
        let slow = TimelineView.speedStripColor(speed: 0.1), fast = TimelineView.speedStripColor(speed: 10)
        XCTAssertEqual(slow.a, 0.95, accuracy: 1e-9)
        XCTAssertEqual(fast.a, 0.95, accuracy: 1e-9)
        let mint = CanvasColor(ThemeTokens.mint), white = CanvasColor(ThemeTokens.white)
        XCTAssertEqual([slow.r, slow.g, slow.b], [mint.r, mint.g, mint.b], "slower than 1x is the accent")
        XCTAssertEqual([fast.r, fast.g, fast.b], [white.r, white.g, white.b], "faster than 1x is white")
        XCTAssertLessThan(TimelineView.speedStripColor(speed: 0.5).a, slow.a, "further from 1x is stronger")
        XCTAssertGreaterThan(TimelineView.speedStripColor(speed: 0.5).a, one.a)
    }
}
