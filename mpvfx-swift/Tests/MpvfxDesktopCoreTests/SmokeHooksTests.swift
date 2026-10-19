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
import MpvfxTheme
@testable import MpvfxDesktopCore

/// `SmokeHooks(env:)`: one parse of the `MPVFX_SMOKE_*` variables for every shell (issue #28).
final class SmokeHooksTests: XCTestCase {
    func testNoVariablesGiveTheDefaults() {
        let h = SmokeHooks(env: ["PATH": "/bin"])
        XCTAssertEqual(h, SmokeHooks())
        XCTAssertNil(h.snapshotPath)
        XCTAssertEqual(h.delay, 1.5)
        XCTAssertEqual(h.gestureDelay, 1.0)
        XCTAssertEqual(h.memoryLimitMB, 256)
    }

    func testSnapshotStateHooks() {
        let h = SmokeHooks(env: ["MPVFX_SMOKE_SNAPSHOT": "/tmp/a.png", "MPVFX_SMOKE_DELAY_MS": "3000",
                                 "MPVFX_SMOKE_SEEK": "2.5", "MPVFX_SMOKE_SELECT": "clip:a", "MPVFX_SMOKE_SET_APPEARANCE": "light"])
        XCTAssertEqual(h.snapshotPath, "/tmp/a.png")
        XCTAssertEqual(h.delay, 3.0)
        XCTAssertEqual(h.gestureDelay, 2.5)
        XCTAssertEqual(h.seek, 2.5)
        XCTAssertEqual(h.select, "clip:a")
        XCTAssertEqual(h.setAppearance, .light)
    }

    func testGestureHooksKeepTheirValueCounts() {
        let h = SmokeHooks(env: ["MPVFX_SMOKE_MARQUEE": "1,2,3,4", "MPVFX_SMOKE_GAPMENU": "5,6,7", "MPVFX_SMOKE_CLICK": "8,9",
                                 "MPVFX_SMOKE_RAZOR": "1,2,3", "MPVFX_SMOKE_DRAG": "1,0.5,3,-0.2,1,2",
                                 "MPVFX_SMOKE_BIN_DRAG": "10,20,30,40,0"])
        XCTAssertEqual(h.marquee, SmokeSegment(from: SmokePoint(1, 2), to: SmokePoint(3, 4)))
        XCTAssertEqual(h.gapMenu, SmokePoint(5, 6))
        XCTAssertEqual(h.click, SmokePoint(8, 9))
        XCTAssertNil(h.razor, "the razor takes exactly x,y")
        XCTAssertEqual(h.drag, SmokeClipDrag(from: SmokePoint(1, 0.5), to: SmokePoint(3, -0.2), release: true, alt: 2))
        XCTAssertEqual(h.binDrag, SmokeBinDrag(from: SmokePoint(10, 20), to: SmokePoint(30, 40), release: false))
        XCTAssertEqual(SmokeHooks(env: ["MPVFX_SMOKE_BIN_DRAG": "1,2,3,4"]).binDrag?.release, true)
        XCTAssertNil(SmokeHooks(env: ["MPVFX_SMOKE_MARQUEE": "1,2,3"]).marquee)
        XCTAssertNil(SmokeHooks(env: ["MPVFX_SMOKE_DRAG": "1,x,3"]).drag)
    }

    func testPanelAndStressHooks() {
        let h = SmokeHooks(env: ["MPVFX_SMOKE_FILE_DROP": "100,200", "MPVFX_SMOKE_DROP_PATHS": "/a.wav:/b.png",
                                 "MPVFX_SMOKE_INSPECTOR": "opacity=0.5;bad;volume=2=3", "MPVFX_SMOKE_RIGHT_TAB": "renders",
                                 "MPVFX_SMOKE_EXPORT": "1", "MPVFX_SMOKE_POPOVER": "speed", "MPVFX_SMOKE_ADD_MEDIA": "/c.mov",
                                 "MPVFX_SMOKE_AUDIOFX_STRESS": "3", "MPVFX_SMOKE_AUDIOFX_SEEK": "1.25",
                                 "MPVFX_SMOKE_MEMORY": "4", "MPVFX_SMOKE_MEMORY_LIMIT_MB": "64",
                                 "MPVFX_SMOKE_MEMORY_MEDIA": "/x.mov:/y.mov", "MPVFX_SMOKE_MEMORY_VERBOSE": "1"])
        XCTAssertEqual(h.fileDrop, SmokeFileDrop(at: SmokePoint(100, 200), paths: ["/a.wav", "/b.png"]))
        XCTAssertEqual(h.inspector, [SmokeInspectorRow(key: "opacity", value: "0.5"), SmokeInspectorRow(key: "volume", value: "2=3")])
        XCTAssertTrue(h.rightTabRenders)
        XCTAssertTrue(h.export)
        XCTAssertEqual(h.popover, .speed)
        XCTAssertEqual(h.addMedia, "/c.mov")
        XCTAssertEqual(h.audioFxStress, 3)
        XCTAssertEqual(h.gestureDelay, 2.0, "the audio FX stress starts its hooks once the window is up")
        XCTAssertEqual(h.audioFxSeek, 1.25)
        XCTAssertEqual(h.memoryRounds, 4)
        XCTAssertEqual(h.memoryLimitMB, 64)
        XCTAssertEqual(h.memoryMedia, ["/x.mov", "/y.mov"])
        XCTAssertTrue(h.memoryVerbose)
        XCTAssertNil(SmokeHooks(env: ["MPVFX_SMOKE_FILE_DROP": "1,2"]).fileDrop, "a drop needs its paths")
    }

    /// A valid value for each name.
    static let sample: [SmokeHookName: String] = [
        .snapshot: "/s.png", .delayMS: "900", .seek: "1", .select: "clip:a", .setAppearance: "dark", .marquee: "1,2,3,4",
        .gapMenu: "1,2", .drag: "1,2,3,4", .click: "1,2", .popover: "volume", .razor: "1,2", .addMedia: "/m.mov",
        .binDrag: "1,2,3,4", .fileDrop: "1,2", .dropPaths: "/d.png", .inspector: "a=b", .rightTab: "renders", .export: "1",
        .audioFxStress: "1", .audioFxSeek: "2", .audioFxVerbose: "1", .audioFxStacks: "1", .memory: "2",
        .memoryLimitMB: "10", .memoryMedia: "/m.mov", .memoryVerbose: "1",
    ]

    /// Names whose sample value leaves the parsed hooks unchanged. A drop needs both its point and its paths, so
    /// each of those is measured against a base holding the other.
    func ignoredNames() -> [String] {
        let partner: [SmokeHookName: SmokeHookName] = [.fileDrop: .dropPaths, .dropPaths: .fileDrop]
        return SmokeHookName.allCases.filter { name in
            var base: [String: String] = [:]
            if let p = partner[name] { base[p.rawValue] = Self.sample[p] }
            var env = base; env[name.rawValue] = Self.sample[name]
            return SmokeHooks(env: env) == SmokeHooks(env: base)
        }.map(\.rawValue)
    }

    /// No name in `SmokeHookName` is listed but ignored by the parser.
    func testEveryHookNameChangesTheParsedHooks() {
        XCTAssertEqual(Set(Self.sample.keys), Set(SmokeHookName.allCases), "every name has a sample value")
        XCTAssertEqual(ignoredNames(), [])
    }
}
