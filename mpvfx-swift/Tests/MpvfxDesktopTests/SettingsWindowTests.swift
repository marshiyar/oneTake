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
import MpvfxAudio
import MpvfxAudioGraph
import MpvfxBackend
import MpvfxCanvas
import MpvfxDesktopCore
import MpvfxPanels
import MpvfxTheme
import MpvfxTimeline
@testable import MpvfxDesktop

/// Issue #32: Ctrl+, opens Settings; each change is applied at once and kept in `<userData>/preferences.json`.
final class SettingsWindowTests: XCTestCase {
    final class ChosenFolder: NativeDialogs, @unchecked Sendable {
        let choice: [String]
        private(set) var asked: [OpenDialogOptions] = []
        init(_ choice: [String]) { self.choice = choice }
        func showSave(_ options: SaveDialogOptions) async -> String? { nil }
        func showOpen(_ options: OpenDialogOptions) async -> [String] { asked.append(options); return choice }
        func showError(title: String, message: String) async {}
        func openPath(_ path: String) async {}
    }

    /// A device-selecting sink over the test sink: counts starts and remembers the device each start used.
    final class SelectingOutput: AudioOutput, AudioDeviceSelecting {
        let sink = NullAudioOutput()
        var device: String?
        private(set) var startedOn: [String?] = []
        var format: AudioFormat { sink.format }
        var framesPlayed: Int { sink.framesPlayed }
        init() { sink.capacityFrames = 4096; sink.keepSamples = false }
        func start() throws { startedOn.append(device); try sink.start() }
        func write(_ samples: [Float]) throws { try sink.write(samples) }
        func stop() { sink.stop() }
        func flush() { sink.flush() }
    }

    var dirs: [String] = []
    override func setUp() { Theme.setMode(.dark) }
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(atPath: d) }; Theme.setMode(.dark) }

    func temporaryDirectory() throws -> String {
        let d = NSTemporaryDirectory() + "mpvfx-settings-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return (d as NSString).resolvingSymlinksInPath
    }

    func waitUntil(_ what: String, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done(), what)
    }

    /// A render keeps its folder: deleting it after Settings changed the export folder removes it where it was written.
    func testDeletingARenderAfterTheExportFolderChangedFindsItsFile() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let first = try temporaryDirectory(), second = try temporaryDirectory()
        let backend = RuntimeDesktopBackend(userData: userData)
        let project = try backend.createProject(name: "Alpha", directory: root + "/Alpha")
        backend.preferences?.defaultExportFolder = first
        let jobId = "render-" + UUID().uuidString.lowercased()
        let output = try backend.renderOutputPath(projectId: project.id, jobId: jobId, format: "mp4")
        XCTAssertTrue(output.hasPrefix(first))
        XCTAssertTrue(FileManager.default.createFile(atPath: output, contents: Data([0])))
        backend.preferences?.defaultExportFolder = second
        try backend.deleteRender(projectId: project.id, id: jobId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output), "deleted from the folder it was written to")
    }

    /// Choosing a device while playing restarts the sound on it at the same position; playback keeps going.
    func testChoosingADeviceMovesPlayingAudioToIt() throws {
        let session = try EditorSession(projectPath: nil, demo: true)
        session.audio?.stop()
        session.graphUpdater?.waitUntilIdle()
        session.graphUpdater = nil
        let graph = GraphAudioSource(project: AudioGraphProject(duration: 3, sampleRate: 48000, tracks: []))
        let output = SelectingOutput()
        session.graph = graph
        session.audio = AudioPlayback(output: output, source: graph)
        defer { session.audio?.stop() }
        session.playback.externalClock = { [weak session] in session?.audio.flatMap { $0.isPlaying ? $0.currentTime : nil } }
        session.playback.duration = 3
        session.playback.seek(1.5)
        session.playback.play()
        session.syncAudio()
        XCTAssertEqual(output.startedOn, [nil])

        session.applyAudioDevice("sink.b")
        XCTAssertEqual(output.device, "sink.b")
        XCTAssertEqual(output.startedOn, [nil, "sink.b"], "restarted once, on the chosen device")
        XCTAssertTrue(session.playback.isPlaying)
        XCTAssertEqual(try XCTUnwrap(session.audio).currentTime, 1.5, accuracy: 0.05, "at the same position")
        session.applyAudioDevice("sink.b")
        XCTAssertEqual(output.startedOn.count, 2, "the same device again changes nothing")
    }

    /// MPVFX_PREVIEW_CACHE_MB (tests, low-memory runs) wins over the Settings value.
    func testPreviewCacheEnvironmentOverrideWins() throws {
        let session = try EditorSession(projectPath: nil, demo: true)
        defer { session.audio?.stop() }
        let before = session.compositor.cache.budgetBytes
        setenv("MPVFX_PREVIEW_CACHE_MB", "64", 1)
        defer { unsetenv("MPVFX_PREVIEW_CACHE_MB") }
        session.applyPreviewCache(1024)
        XCTAssertEqual(session.compositor.cache.budgetBytes, before)
        unsetenv("MPVFX_PREVIEW_CACHE_MB")
        session.applyPreviewCache(1024)
        XCTAssertEqual(session.compositor.cache.budgetBytes, 1024 << 20)
    }

    func testCtrlCommaOpensSettingsAndChangesPersist() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory(), exports = try temporaryDirectory()
        let project = try RuntimeDesktopBackend(userData: userData).createProject(name: "Alpha", directory: root + "/Alpha")
        let backend = RuntimeDesktopBackend(userData: userData)
        let session = try EditorSession(backend: backend, projectPath: project.directory)
        session.postToUI = { body in DispatchQueue.main.async(execute: body) }
        let router = session.installShell(userData: userData) {}
        session.installAppearance(userData: userData, systemPrefersDark: { true })
        let dialogs = ChosenFolder([exports])
        session.panels?.dialogs = dialogs
        let panel = session.settingsPanel
        let projectId = try XCTUnwrap(session.project?.id)
        XCTAssertEqual(try backend.rendersDirectory(projectId: projectId), userData + "/renders")

        // Ctrl+, opens the card over the editor; while open it takes plain keys.
        XCTAssertTrue(router.keyDown(EditorKey(.char(","), ctrl: true)))
        XCTAssertTrue(panel.isOpen)
        let c = PanelMeasureCanvas()
        router.draw(c, size: CanvasSize(1440, 900))
        XCTAssertTrue(c.drawnStrings.contains("Settings"))
        XCTAssertTrue(router.keyDown(EditorKey(.space)), "Space does not reach playback under the card")
        XCTAssertFalse(session.playback.isPlaying)

        // Each row applies and persists its value.
        panel.onChange?(.init(appearance: .light, audioDevice: nil, previewCacheMB: 1024, exportFolder: nil))
        XCTAssertEqual(session.appearance?.appearance, .light)
        XCTAssertEqual(session.compositor.cache.budgetBytes, 1024 << 20)
        router.pointerDown(x: 10, y: 10, button: PointerButton.primary, modifiers: [])   // outside the card: closes it
        XCTAssertFalse(panel.isOpen)
        session.showSettings()
        router.draw(c, size: CanvasSize(1440, 900))
        let choose = try XCTUnwrap(panel.hits.rect { $0 == .chooseFolder })
        router.pointerDown(x: choose.x + choose.width / 2, y: choose.y + choose.height / 2, button: PointerButton.primary, modifiers: [])
        waitUntil("Choose… stores the folder the dialog returned") { DesktopPreferences(userData: userData).defaultExportFolder == exports }
        XCTAssertEqual(dialogs.asked.map(\.directory), [true])
        XCTAssertEqual(try backend.rendersDirectory(projectId: projectId), exports, "standalone projects export to the chosen folder")

        // The chosen folder's own videos are not taken for renders.
        XCTAssertTrue(FileManager.default.createFile(atPath: exports + "/holiday.mp4", contents: Data([0])))
        XCTAssertTrue(FileManager.default.createFile(atPath: exports + "/render-final.mp4", contents: Data([0])),
                      "named like a render, but not render-<uuid>: the user's file")
        XCTAssertEqual(try backend.renders(projectId: projectId), [])
        let renderName = "render-0b9e7c1a-5f3d-4c2e-9a8b-7d6c5e4f3a2b.mp4"
        XCTAssertTrue(FileManager.default.createFile(atPath: exports + "/" + renderName, contents: Data([0])))
        XCTAssertEqual(try backend.renders(projectId: projectId).map(\.filename), [renderName])

        let stored = DesktopPreferences(userData: userData)
        XCTAssertEqual(stored.previewCacheMB, 1024)
        XCTAssertEqual(stored.value(ThemeAppearance.preferenceKey)?.string, "light")
        XCTAssertTrue(router.keyDown(EditorKey(.char(","), ctrl: true)), "Ctrl+, closes it again")
        XCTAssertFalse(panel.isOpen)

        // A relaunch reads them back.
        let again = try EditorSession(backend: RuntimeDesktopBackend(userData: userData), projectPath: project.directory)
        _ = again.installShell(userData: userData) {}
        again.installAppearance(userData: userData, systemPrefersDark: { true })
        XCTAssertEqual(again.compositor.cache.budgetBytes, 1024 << 20)
        again.showSettings()
        XCTAssertEqual(again.settingsPanel.values, .init(appearance: .light, audioDevice: nil, previewCacheMB: 1024, exportFolder: exports))
    }
}
#endif
