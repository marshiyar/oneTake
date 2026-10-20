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
@testable import MpvfxDesktopCore

final class FakeEditor: EditorSaveChannel {
    var isLoading = false
    var prepared: [String] = [], cancelled: [String] = []
    func prepareClose(id: String) { prepared.append(id) }
    func cancelClose(id: String) { cancelled.append(id) }
}

final class ShellLifecycleTests: XCTestCase {
    var editor = FakeEditor()
    var timers: [(Double, () -> Void, Bool)] = []
    var actions: [ShellAction] = []
    var host: NativeSaveBarrierHost!
    var n = 0

    func make() -> ShellLifecycle {
        host = NativeSaveBarrierHost(editor: editor) { [unowned self] s, body in
            let i = timers.count; timers.append((s, body, false)); return { [unowned self] in timers[i].2 = true }
        }
        let barrier = SaveBarrier(host: host) { [unowned self] in n += 1; return "id\(n)" }
        return ShellLifecycle(barrier: barrier) { [unowned self] in actions.append($0) }
    }
    func fireTimers() { for t in timers where !t.2 { t.1() } }

    func testActivateCreatesThenPresents() {
        let l = make()
        l.activate(); XCTAssertEqual(actions, [.createWindow])
        l.windowCreated(); l.activate(); l.activate()   // second launches
        XCTAssertEqual(actions, [.createWindow, .presentWindow, .presentWindow])
    }

    func testCloseRoutedThroughBarrier() {
        let l = make(); l.windowCreated()
        XCTAssertTrue(l.closeRequested())
        XCTAssertTrue(l.closeRequested(), "duplicate close while saving is swallowed")
        XCTAssertEqual(editor.prepared, ["id1"])
        XCTAssertEqual(timers.first?.0, 120)
        l.barrier.closePrepared(id: .string("id1"), error: .null)
        XCTAssertEqual(actions, [.closeWindow])
        XCTAssertTrue(timers[0].2)
        XCTAssertFalse(l.closeRequested(), "approved close proceeds")
        XCTAssertTrue(l.windowDestroyed())
        XCTAssertFalse(l.hasWindow)
        l.activate(); XCTAssertEqual(actions, [.closeWindow], "no reopen while stopping")
    }

    func testCloseErrorKeepsWindowAndCancels() {
        let l = make(); l.windowCreated()
        _ = l.closeRequested()
        l.barrier.closePrepared(id: .string("id1"), error: .string("disk full"))
        XCTAssertEqual(actions, [.showError(title: ShellLifecycle.saveErrorTitle, message: "disk full")])
        XCTAssertEqual(editor.cancelled, ["id1"])
        XCTAssertFalse(l.closeInProgress)
        XCTAssertTrue(l.closeRequested()); XCTAssertEqual(editor.prepared, ["id1", "id2"], "retry starts a new barrier")
    }

    func testBackendCloseFailureStaysAliveWithoutWindow() {
        let l = make(); l.windowCreated()
        _ = l.closeRequested()
        l.barrier.closePrepared(id: .string("id1"), error: .null)
        XCTAssertFalse(l.closeRequested(), "approved")
        XCTAssertTrue(l.windowDestroyed(), "window gone first, then before-quit closes the backend")
        l.closeFailed()   // host showed the error box; app stays alive
        XCTAssertFalse(l.quitInProgress); XCTAssertTrue(l.stopping); XCTAssertFalse(l.hasWindow)
        l.activate(); XCTAssertEqual(actions, [.closeWindow], "relaunch does not reopen while stopping")
        l.quitRequested()   // a later quit retries
        XCTAssertEqual(actions, [.closeWindow, .destroyWindowAndQuit])
    }

    func testCloseTimeout() {
        let l = make(); l.windowCreated()
        _ = l.closeRequested(); fireTimers()
        XCTAssertEqual(actions, [.showError(title: ShellLifecycle.saveErrorTitle, message: SaveBarrierError.timedOut.description)])
        XCTAssertEqual(editor.cancelled, ["id1"])
    }

    func testWaitsForEditorLoad() {
        editor.isLoading = true
        let l = make(); l.windowCreated()
        _ = l.closeRequested(); XCTAssertTrue(editor.prepared.isEmpty)
        l.barrier.loadFinished(); XCTAssertEqual(editor.prepared, ["id1"])
    }

    func testQuitFlushesThenDestroys() {
        let l = make(); l.windowCreated()
        l.quitRequested(); l.quitRequested()
        XCTAssertEqual(editor.prepared, ["id1"])
        XCTAssertTrue(l.closeRequested(), "close during quit is held")
        l.barrier.closePrepared(id: .string("id1"), error: .null)
        XCTAssertEqual(actions, [.destroyWindowAndQuit])
        XCTAssertFalse(l.closeRequested())
    }

    func testQuitWithoutWindowSkipsBarrier() {
        let l = make(); l.quitRequested()
        XCTAssertTrue(editor.prepared.isEmpty)
        XCTAssertEqual(actions, [.destroyWindowAndQuit])
    }

    func testEditorDestroyedMidSave() {
        let l = make(); l.windowCreated()
        _ = l.closeRequested(); _ = l.windowDestroyed()
        XCTAssertEqual(actions, [.showError(title: ShellLifecycle.saveErrorTitle, message: SaveBarrierError.closedEarly.description)])
        XCTAssertTrue(editor.cancelled.isEmpty, "no cancelClose to a gone editor")
    }

    func testMenuModel() {
        XCTAssertEqual(MenuModel.bar(for: .linux), [])
        XCTAssertEqual(MenuModel.bar(for: .windows), [])
        // The standard macOS application menu, without web-only items.
        let mac = MenuModel.bar(for: .macOS)
        XCTAssertEqual(mac.map(\.label), ["MpVFX", "File", "Edit", "View", "Window"])
        XCTAssertEqual(mac[0].items.map(\.command), [.about, .services, .hide, .hideOthers, .showAll, .quit])
        XCTAssertEqual(mac[0].items.map(\.label), ["About MpVFX", "Services", "Hide MpVFX", "Hide Others", "Show All", "Quit MpVFX"])
        let quit = mac[0].items[5]
        XCTAssertEqual(quit.key, "q"); XCTAssertEqual(quit.modifiers, [.command]); XCTAssertTrue(quit.separatorBefore)
        XCTAssertEqual(mac[0].items[3].modifiers, [.command, .option])
        XCTAssertEqual(mac[1].items.map(\.command), [.closeWindow])
        XCTAssertEqual(mac[2].items.map(\.command), [.undo, .redo, .cut, .copy, .paste, .pasteAndMatchStyle, .delete, .selectAll])
        XCTAssertEqual(mac[2].items[1].key, "z"); XCTAssertEqual(mac[2].items[1].modifiers, [.command, .shift])
        XCTAssertEqual(mac[3].items.map(\.command), [.toggleFullScreen, .appearanceSystem, .appearanceLight, .appearanceDark])
        XCTAssertTrue(mac[3].items[1].separatorBefore)
        XCTAssertEqual(mac[3].items[0].modifiers, [.command, .control])
        XCTAssertEqual(mac[4].items.map(\.command), [.minimize, .zoom, .bringAllToFront])
        let all = mac.flatMap(\.items).map(\.label).joined(separator: " ")
        for webOnly in ["Reload", "Developer", "Actual Size", "Zoom In", "Learn More"] { XCTAssertFalse(all.contains(webOnly), webOnly) }
        #if os(macOS)
        XCTAssertEqual(MenuModel.current, .macOS)
        #elseif os(Windows)
        XCTAssertEqual(MenuModel.current, .windows)
        #else
        XCTAssertEqual(MenuModel.current, .linux)
        #endif
    }

    func testMacQuitMenuRoutesThroughBarrier() {
        // The macOS shell maps .quit -> lifecycle.quitRequested(); verify that path waits on the barrier.
        let l = make(); l.windowCreated()
        l.quitRequested()
        XCTAssertEqual(editor.prepared, ["id1"]); XCTAssertEqual(actions, [])
        l.barrier.closePrepared(id: .string("id1"), error: .null)
        XCTAssertEqual(actions, [.destroyWindowAndQuit])
    }
}

final class SingleInstanceTests: XCTestCase {
    func testApplicationIds() {
        XCTAssertTrue(SingleInstance.isValidApplicationId("com.mpvfx.editor"))
        XCTAssertTrue(SingleInstance.isValidApplicationId("com.mpvfx.editor.integration-preview"))
        for bad in ["", "mpvfx", ".com.x", "com.x.", "com..x", "com.1x", "com.mp vfx"] {
            XCTAssertFalse(SingleInstance.isValidApplicationId(bad), bad)
        }
    }

    func testLockPathSanitizes() {
        XCTAssertEqual(SingleInstance.lockPath(appId: "com.mpvfx/editor", runtimeDir: "/run/u"), "/run/u/com.mpvfx_editor.lock")
    }

    func testSecondLockIsRefusedUntilRelease() throws {
        let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/test-tmp/mpvfx-lock-\(UUID().uuidString)")   // inside the package
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = SingleInstance.lockPath(appId: "com.mpvfx.editor", runtimeDir: dir.path)
        let first = SingleInstanceLock(path: path), second = SingleInstanceLock(path: path)
        XCTAssertTrue(first.acquire()); XCTAssertTrue(first.acquire(), "re-acquire is idempotent")
        XCTAssertFalse(second.acquire())
        first.release()
        XCTAssertTrue(second.acquire())
        second.release()
    }
}

final class WindowsMutexNameTests: XCTestCase {
    func testMutexName() {
        XCTAssertEqual(SingleInstanceLock.mutexName(appId: "com.mpvfx.editor"), "Local\\com.mpvfx.editor")
        XCTAssertEqual(SingleInstanceLock.mutexName(appId: "a\\b"), "Local\\a_b")
    }
}
