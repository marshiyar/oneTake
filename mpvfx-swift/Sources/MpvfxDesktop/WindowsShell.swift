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
#if os(Windows)
import CMpvfxWin32
import Foundation
import MpvfxCanvas
import MpvfxDesktopCore
import MpvfxShared
import MpvfxTheme
import WinSDK

/// Result of backend.close(), boxed so a background Task can hand it to the UI thread via PostMessageW.
private final class BackendCloseResult { let error: Error?; init(_ e: Error?) { error = e } }
/// A closure posted to the UI thread (WM_APP + 3).
private final class UIWork { let body: () -> Void; init(_ body: @escaping () -> Void) { self.body = body } }

/// Win32 main process: startup, app lifecycle, window policy and the save barrier around one full-window
/// Direct2D canvas (WindowsCanvasHost) on which EditorShellRouter lays out the editor, as LinuxShell and MacShell
/// do. Lifecycle decisions live in MpvfxDesktopCore.ShellLifecycle. A hidden message-only window owns the timers
/// and the posted messages, so scheduling works before the main window exists and after it is gone; the Win32
/// message loop does not drain the main dispatch queue, so work for the UI thread is posted there (`post`).
final class WindowsShell: EditorSaveChannel, @unchecked Sendable {
    static var current: WindowsShell!
    static let className = "MpVFXWindow"
    static let messageClassName = "MpVFXMessageWindow"
    /// WM_APP + 1: posted by any thread to the main hwnd; marshals quitRequested() onto the UI thread.
    static let quitMessage = UINT(WM_APP + 1)
    /// WM_APP + 2: backend.close() finished; lParam = retained BackendCloseResult.
    static let backendClosedMessage = UINT(WM_APP + 2)
    /// WM_APP + 3: lParam = retained UIWork to run on the UI thread.
    static let uiWorkMessage = UINT(WM_APP + 3)
    /// The editor's minimum client size in DIPs (the window policy of every shell).
    static let minimumSize = (width: 1024.0, height: 640.0)

    let paths: AppPaths
    let backend: DesktopBackend
    lazy var barrierHost = NativeSaveBarrierHost(editor: self) { [weak self] s, body in self?.schedule(after: s, body) ?? {} }
    lazy var barrier = SaveBarrier(host: barrierHost)
    lazy var lifecycle = ShellLifecycle(barrier: barrier) { [weak self] in self?.perform($0) }
    lazy var lock = SingleInstanceLock(path: paths.appId)   // named mutex Local\<appId>
    lazy var dialogs = WindowsDialogs(post: { [weak self] body in self?.post(body) }, owner: { [weak self] in self?.hwnd })
    var hwnd: HWND?
    var messageHwnd: HWND?
    var timers: [UINT_PTR: () -> Void] = [:]
    var nextTimer: UINT_PTR = 1
    var backendClosing = false
    var backendDetached = false
    var session: EditorSession?
    var host: WindowsCanvasHost?
    var playTimerRunning = false
    var smokeRunner: SmokeRunner?
    var reportedDrawError = false
    let env = ProcessInfo.processInfo.environment
    var hiddenTestWindow: Bool { env["MPVFX_HIDDEN_TEST_WINDOW"] == "1" }

    init(paths: AppPaths, backend: DesktopBackend) { self.paths = paths; self.backend = backend }

    // MARK: EditorSaveChannel
    // prepareClose saves the open project through the backend; a failed save keeps the window open.
    var isLoading: Bool { false }
    func prepareClose(id: String) {
        post { self.barrier.closePrepared(id: .string(id), error: self.session?.flushForClose().map { .string($0) } ?? .null) }
    }
    func cancelClose(id: String) {}

    // MARK: Startup

    func run() -> Int32 {
        // Per-monitor DPI (v2): the canvas draws in DIPs and follows WM_DPICHANGED.
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
        // Single instance lock: a second instance focuses the first and exits.
        guard lock.acquire() else {
            let existing = Self.className.withCString(encodedAs: UTF16.self) { FindWindowW($0, nil) }
            if let existing {
                if IsIconic(existing) { ShowWindow(existing, SW_RESTORE) }
                SetForegroundWindow(existing)
            }
            return 0
        }
        defer { lock.release() }
        guard registerClasses(), createMessageWindow() else {
            box(nil, "MpVFX could not start", "RegisterClassExW/CreateWindowExW(HWND_MESSAGE) failed (error \(GetLastError()))")
            return 1
        }
        MemoryPressureMonitor.shared.deliverOnUIThread = { [weak self] body in self?.post(body) }
        // Ctrl+C / Ctrl+Break / console close: the same quit as closing the window (the handler runs on its own thread).
        SetConsoleCtrlHandler({ _ in WindowsShell.current.postQuit(); return true }, true)
        lifecycle.activate()
        var msg = MSG()
        while GetMessageW(&msg, nil, 0, 0) { TranslateMessage(&msg); DispatchMessageW(&msg) }
        if let messageHwnd { DestroyWindow(messageHwnd) }
        return Int32(msg.wParam)
    }

    private func registerClasses() -> Bool {
        let inst = GetModuleHandleW(nil)
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
        wc.lpfnWndProc = { hwnd, msg, wp, lp in WindowsShell.current.wndProc(hwnd, msg, wp, lp) }
        wc.hInstance = inst
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDC_ARROW
        let main = Self.className.withCString(encodedAs: UTF16.self) { wc.lpszClassName = $0; return RegisterClassExW(&wc) }
        var mc = WNDCLASSEXW()
        mc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        mc.lpfnWndProc = { hwnd, msg, wp, lp in WindowsShell.current.messageProc(hwnd, msg, wp, lp) }
        mc.hInstance = inst
        let message = Self.messageClassName.withCString(encodedAs: UTF16.self) { mc.lpszClassName = $0; return RegisterClassExW(&mc) }
        return main != 0 && message != 0
    }

    private func createMessageWindow() -> Bool {
        messageHwnd = Self.messageClassName.withCString(encodedAs: UTF16.self) { cls in
            CreateWindowExW(0, cls, nil, 0, 0, 0, 0, 0, HWND(bitPattern: -3), nil, GetModuleHandleW(nil), nil)   // HWND_MESSAGE
        }
        return messageHwnd != nil
    }

    /// Thread-safe quit request (console control handler, background tasks).
    func postQuit() {
        if let target = messageHwnd ?? hwnd { PostMessageW(target, Self.quitMessage, 0, 0) }
    }

    /// Runs `body` on the UI thread from any thread.
    func post(_ body: @escaping () -> Void) {
        guard let target = messageHwnd else { body(); return }   // before the loop exists: already on the UI thread
        let work = Unmanaged.passRetained(UIWork(body)).toOpaque()
        if !PostMessageW(target, Self.uiWorkMessage, 0, LPARAM(Int(bitPattern: work))) {
            Unmanaged<UIWork>.fromOpaque(work).release()
            FileHandle.standardError.write(Data("[MpVFX] PostMessageW failed (error \(GetLastError())); UI work dropped\n".utf8))
        }
    }

    func perform(_ action: ShellAction) {
        switch action {
        case .createWindow:
            do { try createWindow() } catch { box(nil, "MpVFX could not start", "\(error)"); exit(1) }
        case .presentWindow: if let hwnd { if IsIconic(hwnd) { ShowWindow(hwnd, SW_RESTORE) }; SetForegroundWindow(hwnd) }
        case .closeWindow: if let hwnd { PostMessageW(hwnd, UINT(WM_CLOSE), 0, 0) }
        case .destroyWindowAndQuit: closeBackendThenQuit()   // destroys the window, then closes the backend
        case .showError(let title, let message): box(hwnd, title, message)
        case .none: break
        }
    }

    // MARK: Window

    func createWindow() throws {
        try FileManager.default.createDirectory(atPath: paths.userData, withIntermediateDirectories: true)
        // No menu: MenuModel.bar(for: .windows) == [].
        let created = Self.className.withCString(encodedAs: UTF16.self) { cls in
            "MpVFX".withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(0, cls, title, DWORD(WS_OVERLAPPEDWINDOW),
                                Int32(bitPattern: 0x8000_0000), Int32(bitPattern: 0x8000_0000),   // CW_USEDEFAULT
                                1440, 900, nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let created else { throw DesktopError("CreateWindowExW failed (error \(GetLastError()))") }
        hwnd = created
        // 1440 x 900 DIPs on the window's monitor.
        let scale = Double(max(96, GetDpiForWindow(created))) / 96
        SetWindowPos(created, nil, 0, 0, Int32(1440 * scale), Int32(900 * scale), UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
        let session = try makeEditorSession()
        self.session = session
        installEditor(session, on: created)
        lifecycle.windowCreated()
        if !hiddenTestWindow { ShowWindow(created, SW_SHOW); UpdateWindow(created) }
        // Every MPVFX_SMOKE_* hook, applied as on Linux and macOS.
        smokeRunner = SmokeRunner(hooks: SmokeHooks(env: env), session: session, host: self)
        smokeRunner?.start()
    }

    /// One full-window canvas; EditorShellRouter lays out [left | preview | right] over the timeline and routes
    /// drawing and input to each region.
    private func installEditor(_ session: EditorSession, on window: HWND) {
        // Before installShell: it starts background work (natural-size probes) whose results must land on the UI thread.
        session.postToUI = { [weak self] body in self?.post(body) }
        let router = session.installShell(userData: paths.userData) { [weak self] in self?.ensurePlayTimer() }
        session.panels?.dialogs = dialogs
        session.panels?.copyToClipboard = { [weak self] text in
            let hr = text.withCString(encodedAs: UTF16.self) { mpvfx_clipboard_set_text(self?.hwnd.map { UnsafeMutableRawPointer($0) }, $0) }
            if hr < 0 { self?.session?.onError("Could not copy", "The clipboard is in use by another app (HRESULT \(hr)).") }
        }
        session.panels?.revealPath = { [weak self] path in
            let hr = path.withCString(encodedAs: UTF16.self) { mpvfx_reveal_in_explorer($0) }
            if hr < 0 { self?.session?.onError("Could not show \(path) in Explorer", "HRESULT \(hr)") }
        }
        let host = WindowsCanvasHost(hwnd: window) { [router] c, size in router.draw(c, size: size) }
        host.input = router
        host.cursorAt = { [router] x, y in router.cursor(at: x, y) }
        host.onFilesDragged = { [weak session] p in session?.panels?.assetDrag?.filesDragged(over: p) }
        host.onFilesDropped = { [weak session] paths, p in session?.panels?.assetDrag?.dropFiles(paths, at: p) }
        host.onDrawError = { [weak self] error in self?.drawFailed(error) }
        self.host = host
        session.redraw = { [weak host] in host?.invalidate() }
        session.documentStateChanged = { [weak self, weak session] in
            guard let session, let window = self?.hwnd else { return }
            _ = withWide(session.markedWindowTitle) { SetWindowTextW(window, $0) }
        }
        session.documentStateChanged()
        // Appearance: System follows the Windows app theme (AppsUseLightTheme); WM_SETTINGCHANGE "ImmersiveColorSet"
        // reports a switch, and the window frame follows the editor's mode.
        session.installAppearance(userData: paths.userData, systemPrefersDark: { mpvfx_system_prefers_dark() != 0 }) { mode in
            _ = mpvfx_window_set_dark_frame(UnsafeMutableRawPointer(window), mode == .light ? 0 : 1)
        }
    }

    /// The first failed frame is reported once (later frames keep drawing and usually recover with a new target).
    private func drawFailed(_ error: Error) {
        FileHandle.standardError.write(Data("[MpVFX] drawing failed: \(error)\n".utf8))
        guard !reportedDrawError else { return }
        reportedDrawError = true
        box(hwnd, "MpVFX could not draw the editor", "\(error)")
    }

    /// The editor on MPVFX_PROJECT, else the default project; the demo for smoke runs (MPVFX_SMOKE_SNAPSHOT or
    /// MPVFX_DEMO=1 without MPVFX_PROJECT). Ctrl+I imports media through the open dialog.
    func makeEditorSession() throws -> EditorSession {
        let project = env["MPVFX_PROJECT"]
        let demo = project == nil && (SmokeHooks(env: env).snapshotPath != nil || env["MPVFX_DEMO"] == "1")
        let session: EditorSession
        do { session = try EditorSession(backend: backend, projectPath: project, demo: demo) }
        catch {
            box(nil, "Could not open the project", "\(error)")
            session = try EditorSession(backend: backend, projectPath: nil, demo: true)
        }
        session.onError = { [weak self] title, message in box(self?.hwnd, title, message) }
        session.schedule = { [weak self] seconds, body in self?.schedule(after: seconds, body) ?? {} }
        session.onExternalConflict = { [weak self] answer in
            let text = "It was changed outside MpVFX while you have unsaved edits.\n\nYes: keep my edits.\nNo: use the file on disk."
            let choice = withWide("The project file changed on disk") { t in
                withWide(text) { m in MessageBoxW(self?.hwnd, m, t, UINT(MB_YESNO | MB_ICONWARNING)) }
            }
            answer(choice == IDYES)
        }
        session.onImportRequested = { [weak self, weak session] in
            guard let self else { return }
            Task {
                let files = await self.dialogs.showOpen(.init(title: "Import Media", directory: false, multiple: true))
                self.post { session?.importMedia(paths: files) }
            }
        }
        return session
    }

    /// ~60 Hz playback clock on the UI thread's timers while playing.
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

    // MARK: Close

    /// before-quit -> controller.close(): the window is destroyed FIRST, then backend.close() runs off the UI thread
    /// and posts its result back.
    func closeBackendThenQuit() {
        if backendDetached { PostQuitMessage(0); return }   // retry after a failure: runtime already detached
        if backendClosing { return }
        backendClosing = true
        if let hwnd { DestroyWindow(hwnd) }   // WM_DESTROY re-enters here; guarded by backendClosing
        guard let target = messageHwnd else { PostQuitMessage(0); return }
        let backend = self.backend
        let targetBits = Int(bitPattern: target)
        Task.detached {
            var failure: Error?
            do { try await backend.close() } catch { failure = error }
            let box = Unmanaged.passRetained(BackendCloseResult(failure)).toOpaque()
            PostMessageW(HWND(bitPattern: targetBits), WindowsShell.backendClosedMessage, 0, LPARAM(Int(bitPattern: box)))
        }
    }

    func backendCloseFinished(_ error: Error?) {
        backendClosing = false
        backendDetached = true   // the runtime is detached before close; never closed twice
        guard let error else { PostQuitMessage(0); return }
        // The app stays alive with no window; relaunch/activate is a no-op until a later quit (which then exits).
        box(nil, ShellLifecycle.saveErrorTitle, "\(error)")
        lifecycle.closeFailed()
    }

    // MARK: Window procedures

    func wndProc(_ h: HWND?, _ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) -> LRESULT {
        switch Int32(msg) {
        case WM_GETMINMAXINFO:   // window policy: the minimum client size, in DIPs on this monitor
            if let h, let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lp)) {
                let scale = Double(max(96, GetDpiForWindow(h))) / 96
                info.pointee.ptMinTrackSize = POINT(x: LONG(Self.minimumSize.width * scale), y: LONG(Self.minimumSize.height * scale))
            }
            return 0
        case WM_CLOSE:           // window "close" -> save barrier
            if lifecycle.closeRequested() { return 0 }
            DestroyWindow(h); return 0
        case WM_DESTROY:
            // The window is already gone when controller.close() runs; on failure the error box is shown and the
            // app stays alive with no window.
            hwnd = nil
            host = nil
            if lifecycle.windowDestroyed() { closeBackendThenQuit() }
            return 0
        case WM_SETTINGCHANGE:
            let setting = UnsafePointer<UInt16>(bitPattern: Int(lp))
            if mpvfx_is_appearance_change(setting) != 0 { session?.appearance?.systemAppearanceChanged() }
            return DefWindowProcW(h, msg, wp, lp)
        default:
            if msg == Self.quitMessage { lifecycle.quitRequested(); return 0 }
            if let result = host?.handle(msg, wp, lp) { return result }
            return DefWindowProcW(h, msg, wp, lp)
        }
    }

    func messageProc(_ h: HWND?, _ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) -> LRESULT {
        switch msg {
        case UINT(WM_TIMER):
            let id = UINT_PTR(wp)
            KillTimer(h, id)
            if let body = timers.removeValue(forKey: id) { body() }
            return 0
        case Self.quitMessage:
            lifecycle.quitRequested(); return 0
        case Self.uiWorkMessage:
            guard let p = UnsafeMutableRawPointer(bitPattern: Int(lp)) else { return 0 }
            Unmanaged<UIWork>.fromOpaque(p).takeRetainedValue().body()
            return 0
        case Self.backendClosedMessage:
            guard let p = UnsafeMutableRawPointer(bitPattern: Int(lp)) else { return 0 }
            backendCloseFinished(Unmanaged<BackendCloseResult>.fromOpaque(p).takeRetainedValue().error)
            return 0
        default:
            return DefWindowProcW(h, msg, wp, lp)
        }
    }

    /// UI-thread timer on the message-only window; works with or without the main window.
    func schedule(after seconds: Double, _ body: @escaping () -> Void) -> () -> Void {
        let id = nextTimer; nextTimer += 1
        timers[id] = body
        SetTimer(messageHwnd, id, UINT(max(1, seconds * 1000)), nil)
        return { [weak self] in
            guard let self else { return }
            self.timers[id] = nil
            if let m = self.messageHwnd { KillTimer(m, id) }
        }
    }
}

/// MPVFX_SMOKE_SNAPSHOT=out.png: the editor painted at the window's client size into an offscreen Direct2D bitmap
/// with the window's own painter, written as a PNG.
extension WindowsShell: SmokeHost {
    func writeSmokeSnapshot(_ path: String) {
        guard let host else { print("[MpVFX] smoke snapshot: no window"); return }
        let size = host.size
        do {
            let target = try Direct2DImageTarget(width: max(1, Int(size.width.rounded())), height: max(1, Int(size.height.rounded())))
            host.paint(target.canvas, size)
            try target.writePNG(path)
            print("[MpVFX] smoke snapshot -> \(path) (\(target.width)x\(target.height), ok)")
        } catch {
            print("[MpVFX] smoke snapshot -> \(path) failed: \(error)")
        }
    }

    func quitAfterSmoke() { lifecycle.quitRequested() }
}
#endif
