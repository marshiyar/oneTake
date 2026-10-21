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
import CGtk3
import MpvfxCanvas
import Foundation
import Glibc
import MpvfxDesktopCore
import MpvfxTimeline
import MpvfxTheme

/// Native GTK3 main process for Linux (startup, app lifecycle, window policy and the
/// save barrier). No web view: the window hosts native GTK widgets.
/// Lifecycle decisions live in MpvfxDesktopCore.ShellLifecycle.
final class LinuxShell: EditorSaveChannel, @unchecked Sendable {
    static var current: LinuxShell!

    let paths: AppPaths
    let backend: DesktopBackend
    lazy var dialogs = GtkDialogs { [weak self] in self?.window.flatMap { typed(raw($0), GtkWindow.self) } }
    lazy var barrierHost = NativeSaveBarrierHost(editor: self) { [weak self] s, body in self?.schedule(after: s, body) ?? {} }
    lazy var barrier = SaveBarrier(host: barrierHost)
    lazy var lifecycle = ShellLifecycle(barrier: barrier) { [weak self] in self?.perform($0) }

    var app: UnsafeMutablePointer<GtkApplication>!
    var window: UnsafeMutablePointer<GtkWidget>?
    var backendClosing = false
    var backendDetached = false
    var holding = false
    var session: EditorSession?
    var shellHost: GtkCanvasHost?
    var playTimerRunning = false
    var smokeRunner: SmokeRunner?
    let hiddenTestWindow = ProcessInfo.processInfo.environment["MPVFX_HIDDEN_TEST_WINDOW"] == "1"
    let smoke = SmokeHooks(env: ProcessInfo.processInfo.environment)

    init(paths: AppPaths, backend: DesktopBackend) { self.paths = paths; self.backend = backend }

    // MARK: EditorSaveChannel
    // prepareClose saves the open project through the backend; a failed save keeps the window open.
    var isLoading: Bool { false }
    func prepareClose(id: String) {
        onMain { self.barrier.closePrepared(id: .string(id), error: self.session?.flushForClose().map { .string($0) } ?? .null) }
    }
    func cancelClose(id: String) {}

    // MARK: Startup

    func run() -> Int32 {
        precondition(SingleInstance.isValidApplicationId(paths.appId), "invalid application id \(paths.appId)")
        // GApplication uniqueness = requestSingleInstanceLock; a second launch re-activates this one.
        app = gtk_application_new(paths.appId, G_APPLICATION_DEFAULT_FLAGS)
        g_set_application_name("MpVFX")
        connect(raw(app), "activate", unsafeBitCast({ (_: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?) in
            LinuxShell.current.lifecycle.activate()
        } as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void, to: GCallback.self))
        for sig in [SIGINT, SIGTERM] {
            g_unix_signal_add(sig, { _ in LinuxShell.current.lifecycle.quitRequested(); return 1 }, nil)
        }
        let status = g_application_run(typed(raw(app), GApplication.self), CommandLine.argc, CommandLine.unsafeArgv)
        g_object_unref(app)
        return status
    }

    func perform(_ action: ShellAction) {
        switch action {
        case .createWindow:
            do { try createWindow() } catch {
                mpvfx_error_box(nil, "MpVFX could not start", "\(error)"); exit(1)
            }
        case .presentWindow:
            if let window { gtk_window_present(typed(raw(window), GtkWindow.self)) }
        case .closeWindow:
            if let window { gtk_window_close(typed(raw(window), GtkWindow.self)) }
        case .destroyWindowAndQuit:
            if let window { gtk_widget_destroy(window) } else { closeRuntime() }
        case .showError(let title, let message):
            mpvfx_error_box(window.flatMap { typed(raw($0), GtkWindow.self) }, title, message)
        case .none: break
        }
    }

    // MARK: Window

    func createWindow() throws {
        try FileManager.default.createDirectory(atPath: paths.userData, withIntermediateDirectories: true)
        let w = gtk_application_window_new(app)!
        window = w
        let gw = typed(raw(w), GtkWindow.self)
        gtk_window_set_title(gw, "MpVFX")
        gtk_window_set_default_size(gw, 1440, 900)
        var geo = GdkGeometry(); geo.min_width = 1024; geo.min_height = 640
        gtk_window_set_geometry_hints(gw, nil, &geo, GDK_HINT_MIN_SIZE)
        gtk_application_window_set_show_menubar(typed(raw(w), GtkApplicationWindow.self), 0)   // no menu bar: MenuModel.bar(for: .linux) == []
        mpvfx_set_background(w)
        // Native editor: one full-window canvas; EditorShellRouter lays out [left | preview | right] over the
        // timeline and routes drawing and input to each region.
        let session = try makeEditorSession()
        self.session = session
        // Before installShell: it starts background work (natural-size probes) whose results must land on the UI thread.
        session.postToUI = { body in onMain(body) }
        let router = session.installShell(userData: paths.userData) { [weak self] in self?.ensurePlayTimer() }
        session.panels?.dialogs = dialogs
        session.panels?.copyToClipboard = { text in
            gtk_clipboard_set_text(gtk_clipboard_get(gdk_atom_intern("CLIPBOARD", 0)), text, -1)
        }
        session.panels?.revealPath = { [weak self] path in
            // No portable "select in file manager" on Linux: open the containing folder.
            Task { await self?.dialogs.openPath((path as NSString).deletingLastPathComponent) }
        }
        let host = GtkCanvasHost { [router] c, size in router.draw(c, size: size) }
        host.input = router
        host.cursorAt = { [router] x, y in router.cursor(at: x, y) }
        host.onFilesDragged = { [weak session] p in session?.panels?.assetDrag?.filesDragged(over: p) }
        host.onFilesDropped = { [weak session] paths, p in session?.panels?.assetDrag?.dropFiles(paths, at: p) }
        shellHost = host
        session.redraw = { [weak host] in host?.invalidate() }
        // Appearance (System follows GNOME color-scheme / GTK prefer-dark; switches repaint live).
        // The canvas paints the whole window, so the GTK window background needs no retint.
        session.installAppearance(userData: paths.userData, systemPrefersDark: { mpvfx_system_prefers_dark() != 0 })
        mpvfx_watch_system_appearance(unsafeBitCast({ (_: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?) in
            LinuxShell.current.session?.appearance?.systemAppearanceChanged()
        } as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void, to: GCallback.self))
        gtk_container_add(typed(raw(w), GtkContainer.self), host.widget)
        connect(raw(w), "delete-event", unsafeBitCast({ (_: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?) -> gboolean in
            LinuxShell.current.lifecycle.closeRequested() ? 1 : 0
        } as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean, to: GCallback.self))
        connect(raw(w), "destroy", unsafeBitCast({ (_: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?) in
            LinuxShell.current.windowDestroyed()
        } as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void, to: GCallback.self))
        lifecycle.windowCreated()
        if !hiddenTestWindow { gtk_widget_show_all(w) } else { gtk_widget_realize(w) }
        // Every MPVFX_SMOKE_* hook, applied as on macOS and Windows.
        smokeRunner = SmokeRunner(hooks: smoke, session: session, host: self)
        smokeRunner?.start()
    }

    /// The editor on MPVFX_PROJECT, else the default project; the demo for smoke runs (MPVFX_SMOKE_SNAPSHOT or
    /// MPVFX_DEMO=1 without MPVFX_PROJECT). Ctrl+I imports media through a file chooser.
    func makeEditorSession() throws -> EditorSession {
        let env = ProcessInfo.processInfo.environment
        let project = env["MPVFX_PROJECT"]
        let demo = project == nil && (smoke.snapshotPath != nil || env["MPVFX_DEMO"] == "1")
        let session: EditorSession
        do { session = try EditorSession(backend: backend, projectPath: project, demo: demo) }
        catch {
            mpvfx_error_box(nil, "Could not open the project", "\(error)")
            session = try EditorSession(backend: backend, projectPath: nil, demo: true)
        }
        session.onError = { title, message in mpvfx_error_box(nil, title, message) }
        session.schedule = { [weak self] seconds, body in self?.schedule(after: seconds, body) ?? {} }
        session.onExternalConflict = { answer in
            answer(mpvfx_choice_box(nil, "The project file changed on disk",
                "It was changed outside MpVFX while you have unsaved edits.", "Keep My Edits", "Use the File on Disk") == 1)
        }
        session.onProjectMoved = { message, answer in
            answer(mpvfx_choice_box(nil, "The project folder is missing", message, "Locate Folder…", "Keep Editing") == 1)
        }
        session.onImportRequested = { [weak self, weak session] in
            guard let self else { return }
            Task {
                let files = await self.dialogs.showOpen(.init(title: "Import Media", directory: false, multiple: true))
                onMain { session?.importMedia(paths: files) }
            }
        }
        return session
    }

    /// ~60 Hz playback clock on the GTK main loop while playing.
    func ensurePlayTimer() {
        guard let session, session.playback.isPlaying, !playTimerRunning else { return }
        playTimerRunning = true
        var last = Date()
        func step() {
            let now = Date(); let dt = now.timeIntervalSince(last); last = now
            if session.tick(dt) { _ = schedule(after: 1.0 / 60, step) } else { playTimerRunning = false; session.redraw() }
        }
        _ = schedule(after: 1.0 / 60, step)
    }

    func windowDestroyed() {
        window = nil
        if lifecycle.windowDestroyed() { closeRuntime() }
    }

    /// before-quit -> controller.close(). Always reached
    /// after the window is destroyed (window "destroy" or .destroyWindowAndQuit with no window).
    /// Success: quit. Failure: error dialog, app stays alive with no window (held), activate is a
    /// no-op (lifecycle.stopping stays true), and a later quit exits at once: the backend is
    /// detached after the first attempt and never closed twice.
    func closeRuntime() {
        if backendDetached { quitApp(); return }
        if backendClosing { return }
        backendClosing = true
        if !holding { g_application_hold(typed(raw(app), GApplication.self)); holding = true }
        let backend = self.backend
        Task {
            var failure: Error?
            do { try await backend.close() } catch { failure = error }
            onMain {   // back on the GTK main thread
                self.backendClosing = false
                self.backendDetached = true
                guard let failure else { self.quitApp(); return }
                mpvfx_error_box(nil, ShellLifecycle.saveErrorTitle, "\(failure)")
                self.lifecycle.closeFailed()   // keep the hold: alive with no window
            }
        }
    }

    func quitApp() {
        if holding { g_application_release(typed(raw(app), GApplication.self)); holding = false }
        g_application_quit(typed(raw(app), GApplication.self))
    }

    func schedule(after seconds: Double, _ body: @escaping () -> Void) -> () -> Void {
        var cancelled = false
        let work = MainWork { if !cancelled { body() } }
        let p = Unmanaged.passRetained(work).toOpaque()
        _ = g_timeout_add_full(G_PRIORITY_DEFAULT, guint(seconds * 1000), { data in
            Unmanaged<MainWork>.fromOpaque(data!).takeRetainedValue().body(); return 0
        }, p, nil)
        return { cancelled = true }
    }
}

extension LinuxShell: SmokeHost {
    func writeSmokeSnapshot(_ path: String) {
        guard let window else { return }
        let status = mpvfx_snapshot_window(window, path)
        print("[MpVFX] smoke snapshot -> \(path) (cairo status \(status))")
    }

    func quitAfterSmoke() { lifecycle.quitRequested() }
}
#endif
