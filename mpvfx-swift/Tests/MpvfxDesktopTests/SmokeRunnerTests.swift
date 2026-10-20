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
#if os(Linux)
import Foundation
import XCTest
import MpvfxDesktopCore
import MpvfxTheme
@testable import MpvfxDesktop

/// `SmokeRunner`: the one place every shell's smoke run applies its hooks (issue #28: macOS ignored
/// MPVFX_SMOKE_SELECT, so its appearance snapshots showed no selection). Driven on the built-in demo with a host
/// whose timers fire when the test says.
final class SmokeRunnerTests: XCTestCase {
    final class Host: SmokeHost {
        var timers: [(at: Double, body: () -> Void)] = []
        var snapshots: [String] = [], quits = 0, appearanceChanges = 0
        func schedule(after seconds: Double, _ body: @escaping () -> Void) -> () -> Void {
            timers.append((seconds, body)); return {}
        }
        func ensurePlayTimer() {}
        func writeSmokeSnapshot(_ path: String) { snapshots.append(path) }
        func quitAfterSmoke() { quits += 1 }
        func smokeAppearanceChanged() { appearanceChanges += 1 }
        /// Fires the pending timers in time order (timers they add run too).
        func fireAll() {
            while !timers.isEmpty {
                let next = timers.enumerated().min { $0.element.at < $1.element.at }!
                timers.remove(at: next.offset)
                next.element.body()
            }
        }
    }

    var dirs: [String] = []
    override func setUp() { Theme.setMode(.dark) }
    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        Theme.setMode(.dark)
    }

    func makeSession() throws -> EditorSession {
        let d = NSTemporaryDirectory() + "mpvfx-smoke-runner-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        _ = s.installShell(userData: d) {}
        s.installAppearance(userData: d, systemPrefersDark: { true })
        return s
    }

    func testSnapshotRunSelectsSeeksSwitchesAppearanceThenSnapshotsAndQuits() throws {
        let session = try makeSession(), host = Host()
        let hooks = SmokeHooks(env: ["MPVFX_SMOKE_SNAPSHOT": "/tmp/s.png", "MPVFX_SMOKE_SELECT": "clip:a",
                                     "MPVFX_SMOKE_SEEK": "1", "MPVFX_SMOKE_SET_APPEARANCE": "light", "MPVFX_SMOKE_DELAY_MS": "3000"])
        let runner = SmokeRunner(hooks: hooks, session: session, host: host)
        runner.start()
        XCTAssertEqual(session.timeline.view.selection, ["clip:a"], "selected before the first paint")
        XCTAssertEqual(session.playback.currentTime, 1, accuracy: 1e-9)
        XCTAssertEqual(host.timers.map(\.at).sorted(), [2.5, 3.0], "gestures and appearance 0.5 s before the snapshot")
        XCTAssertTrue(host.snapshots.isEmpty)
        host.fireAll()
        XCTAssertEqual(session.appearance?.appearance, .light)
        XCTAssertEqual(host.appearanceChanges, 1)
        XCTAssertEqual(host.snapshots, ["/tmp/s.png"])
        XCTAssertEqual(host.quits, 1)
    }

    func testAppearanceWithoutSnapshotSwitchesAndKeepsRunning() throws {
        let session = try makeSession(), host = Host()
        let runner = SmokeRunner(hooks: SmokeHooks(env: ["MPVFX_SMOKE_SET_APPEARANCE": "light"]), session: session, host: host)
        runner.start()
        XCTAssertEqual(host.timers.map(\.at), [1.5])
        host.fireAll()
        XCTAssertEqual(session.appearance?.appearance, .light)
        XCTAssertEqual(host.quits, 0)
        XCTAssertTrue(host.snapshots.isEmpty)
    }

    func testNoHooksSchedulesNothing() throws {
        let session = try makeSession(), host = Host()
        SmokeRunner(hooks: SmokeHooks(env: [:]), session: session, host: host).start()
        XCTAssertTrue(host.timers.isEmpty)
    }

    func testRightTabHookShowsTheRendersTab() throws {
        let session = try makeSession(), host = Host()
        let hooks = SmokeHooks(env: ["MPVFX_SMOKE_SNAPSHOT": "/tmp/s.png", "MPVFX_SMOKE_RIGHT_TAB": "renders"])
        SmokeRunner(hooks: hooks, session: session, host: host).start()
        host.fireAll()
        XCTAssertEqual(session.panels?.right.layout.rightPanelTab, .renders)
    }

    func testSettingsHookOpensTheSettingsCard() throws {
        let session = try makeSession(), host = Host()
        SmokeRunner(hooks: SmokeHooks(env: ["MPVFX_SMOKE_SNAPSHOT": "/tmp/s.png", "MPVFX_SMOKE_SETTINGS": "1"]), session: session, host: host).start()
        XCTAssertFalse(session.settingsPanel.isOpen)
        host.fireAll()
        XCTAssertTrue(session.settingsPanel.isOpen)
    }
}
#endif
