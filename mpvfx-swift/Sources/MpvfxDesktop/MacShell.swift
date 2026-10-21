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
#if os(macOS)
// Native AppKit shell. The window hosts the same custom-drawn editor as the Linux shell: the player stage on top
// and the timeline below, each a MacCanvasHost painting through CoreGraphicsCanvas.
// Single instance on macOS is handled by LaunchServices (a second `open` activates the
// running app and delivers applicationShouldHandleReopen); no lock is taken here.
import AppKit
import MpvfxAudio
import MpvfxDesktopCore
import MpvfxTimeline
import MpvfxTheme

final class MacShell: NSObject, NSApplicationDelegate, NSWindowDelegate, EditorSaveChannel, @unchecked Sendable {
    static var current: MacShell!
    let paths: AppPaths
    let backend: DesktopBackend
    lazy var barrierHost = NativeSaveBarrierHost(editor: self) { s, body in
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: item)
        return { item.cancel() }
    }
    lazy var barrier = SaveBarrier(host: barrierHost)
    lazy var lifecycle = ShellLifecycle(barrier: barrier) { [weak self] in self?.perform($0) }
    var window: NSWindow?
    var session: EditorSession?
    var shellHost: MacCanvasHost?
    var playTimer: Timer?
    var smokeRunner: SmokeRunner?
    var lastTick = Date()
    /// Set while applicationShouldTerminate returned .terminateLater.
    var pendingTerminate = false
    /// View menu appearance items (checkmark follows the setting) and the system appearance observation.
    var appearanceItems: [ThemeAppearance: NSMenuItem] = [:]
    /// Window > Panels, filled from the dock each time it opens (menuNeedsUpdate).
    var panelsMenu: NSMenu?
    var appearanceObservation: NSKeyValueObservation?

    init(paths: AppPaths, backend: DesktopBackend) { self.paths = paths; self.backend = backend }

    var isLoading: Bool { false }
    func prepareClose(id: String) {
        DispatchQueue.main.async { self.barrier.closePrepared(id: .string(id), error: self.session?.flushForClose().map { .string($0) } ?? .null) }
    }
    func cancelClose(id: String) {}

    func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        app.mainMenu = buildMenu()
        app.run()
        return 0
    }

    func buildMenu() -> NSMenu {
        let main = NSMenu()
        for menu in MenuModel.bar(for: .macOS) {
            let top = NSMenuItem(); main.addItem(top)
            let sub = NSMenu(title: menu.label)
            for item in menu.items {
                if item.separatorBefore { sub.addItem(.separator()) }
                if item.command == .openRecent || item.command == .panels { sub.addItem(filledOnOpen(item)); continue }
                if item.command == .services {
                    let services = NSMenu(title: item.label)
                    let mi = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
                    mi.submenu = services; NSApp.servicesMenu = services
                    sub.addItem(mi); continue
                }
                // Edit actions go up the responder chain (nil target), as standard menu roles do: the editor views
                // take ⌘Z/⌘X/⌘C/⌘V first (MacCanvasHost.performKeyEquivalent), so these only act on text.
                let selector: Selector
                switch item.command {
                case .about: selector = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
                case .services, .openRecent, .panels: continue
                case .openProject, .settings, .closePanel, .keyframeEasing:
                    let action = item.command == .settings ? #selector(openSettings(_:))
                        : item.command == .closePanel ? #selector(closePanel(_:))
                        : item.command == .keyframeEasing ? #selector(openKeyframeEasing(_:)) : #selector(openProject(_:))
                    let mi = NSMenuItem(title: item.label, action: action, keyEquivalent: item.key ?? "")
                    mi.keyEquivalentModifierMask = Self.modifierMask(item.modifiers)
                    mi.target = self
                    sub.addItem(mi); continue
                case .hide: selector = #selector(NSApplication.hide(_:))
                case .hideOthers: selector = #selector(NSApplication.hideOtherApplications(_:))
                case .showAll: selector = #selector(NSApplication.unhideAllApplications(_:))
                case .quit: selector = #selector(NSApplication.terminate(_:))   // -> applicationShouldTerminate -> barrier
                case .closeWindow: selector = #selector(NSWindow.performClose(_:))   // -> windowShouldClose -> barrier
                case .undo: selector = Selector(("undo:"))
                case .redo: selector = Selector(("redo:"))
                case .cut: selector = #selector(NSText.cut(_:))
                case .copy: selector = #selector(NSText.copy(_:))
                case .paste: selector = #selector(NSText.paste(_:))
                case .pasteAndMatchStyle: selector = #selector(NSTextView.pasteAsPlainText(_:))
                case .delete: selector = #selector(NSText.delete(_:))
                case .selectAll: selector = #selector(NSText.selectAll(_:))
                case .toggleFullScreen: selector = #selector(NSWindow.toggleFullScreen(_:))
                case .minimize: selector = #selector(NSWindow.performMiniaturize(_:))
                case .zoom: selector = #selector(NSWindow.performZoom(_:))
                case .bringAllToFront: selector = #selector(NSApplication.arrangeInFront(_:))
                case .appearanceSystem, .appearanceLight, .appearanceDark:
                    let a: ThemeAppearance = item.command == .appearanceSystem ? .system : item.command == .appearanceLight ? .light : .dark
                    let mi = NSMenuItem(title: item.label, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
                    mi.target = self; mi.representedObject = a.rawValue
                    appearanceItems[a] = mi
                    sub.addItem(mi); continue
                }
                let mi = NSMenuItem(title: item.label, action: selector, keyEquivalent: item.key ?? "")
                mi.keyEquivalentModifierMask = Self.modifierMask(item.modifiers)
                sub.addItem(mi)
            }
            top.submenu = sub
            if menu.label == "Window" { NSApp.windowsMenu = sub }
        }
        return main
    }

    /// A submenu filled each time it opens (menuNeedsUpdate): Open Recent from the backend's recent projects,
    /// Window > Panels from the dock.
    func filledOnOpen(_ item: MenuItem) -> NSMenuItem {
        let menu = NSMenu(title: item.label)
        menu.delegate = self
        if item.command == .panels { panelsMenu = menu }
        let mi = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
        mi.submenu = menu
        return mi
    }

    static func modifierMask(_ modifiers: Set<MenuItem.Modifier>) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.control) { mask.insert(.control) }
        return mask
    }

    /// MpVFX > Settings… (⌘, in the editor reaches the same card through EditorSession.commandKey).
    @objc func openSettings(_ sender: NSMenuItem) { session?.showSettings() }

    /// View > Keyframe Easing: the Keyframe Easing panel.
    @objc func openKeyframeEasing(_ sender: NSMenuItem) { session?.showKeyframeEasingPanel() }

    /// File > Open…: the folder dialog (⌘O in the editor reaches the same call through EditorSession.commandKey).
    @objc func openProject(_ sender: NSMenuItem) { session?.requestOpenProject() }

    /// Window > Close Panel (⌘⇧W in the editor reaches the same call through the dock's keys).
    @objc func closePanel(_ sender: NSMenuItem) { session?.shell?.closeFocusedPanel() }

    /// Window > Panels > <panel>: opens it at its last place, or closes it when it is open.
    @objc func togglePanel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        session?.shell?.togglePanelFromMenu(id)
    }

    @objc func openRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        session?.openProject(path: path)
    }

    @objc func clearRecentProjects(_ sender: NSMenuItem) { session?.clearRecentProjects() }

    @objc func chooseAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = ThemeAppearance(rawValue: raw) else { return }
        session?.setAppearance(a)
        syncAppearanceMenu()
    }

    func syncAppearanceMenu() {
        let current = session?.appearance?.appearance ?? .system
        for (a, mi) in appearanceItems { mi.state = a == current ? .on : .off }
    }

    func perform(_ action: ShellAction) {
        switch action {
        case .createWindow: createWindow()
        case .presentWindow: window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        case .closeWindow: window?.close()
        case .destroyWindowAndQuit:
            window?.close()
            if !pendingTerminate { requestTerminate() }
            else { finishTerminate(true) }
        case .showError(let title, let message):
            if pendingTerminate { finishTerminate(false) }
            let alert = NSAlert(); alert.alertStyle = .critical
            alert.messageText = title; alert.informativeText = message
            alert.runModal()
        case .none: break
        }
    }

    func finishTerminate(_ ok: Bool) {
        guard pendingTerminate else { return }
        pendingTerminate = false
        if ok {
            let backend = self.backend
            Task { try? await backend.close(); await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) } }
        } else {
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    func createWindow() {
        let session: EditorSession
        do {
            try FileManager.default.createDirectory(atPath: paths.userData, withIntermediateDirectories: true)
            // MPVFX_PROJECT, else the default project; the demo for smoke runs (MPVFX_SMOKE_SNAPSHOT / MPVFX_DEMO=1).
            let env = ProcessInfo.processInfo.environment
            let project = env["MPVFX_PROJECT"]
            session = try EditorSession(backend: backend, projectPath: project,
                                        demo: project == nil && (SmokeHooks(env: env).snapshotPath != nil || env["MPVFX_DEMO"] == "1"))
            session.onError = { title, message in
                let alert = NSAlert(); alert.alertStyle = .warning
                alert.messageText = title; alert.informativeText = message
                alert.runModal()
            }
        } catch {
            let alert = NSAlert(); alert.alertStyle = .critical
            alert.messageText = "MpVFX could not start"; alert.informativeText = "\(error)"
            alert.runModal()
            exit(1)
        }
        self.session = session
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "MpVFX"
        w.minSize = NSSize(width: 1024, height: 640)
        let bg = ThemeTokens.studioBgPair.dark   // retinted by installAppearance below
        w.backgroundColor = NSColor(srgbRed: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = makeEditorView(session)
        // Appearance: System follows NSApp.effectiveAppearance (the app's, which a window override does not change).
        session.installAppearance(userData: paths.userData, systemPrefersDark: {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }) { [weak self, weak w] mode in
            w?.appearance = NSAppearance(named: mode == .light ? .aqua : .darkAqua)
            let bg = ThemeTokens.studioBgPair.value(mode)
            w?.backgroundColor = NSColor(srgbRed: bg.r, green: bg.g, blue: bg.b, alpha: 1)
            self?.syncAppearanceMenu()
        }
        syncAppearanceMenu()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { MacShell.current.session?.appearance?.systemAppearanceChanged() }
        }
        w.center()
        window = w
        lifecycle.windowCreated()
        if ProcessInfo.processInfo.environment["MPVFX_HIDDEN_TEST_WINDOW"] != "1" { w.makeKeyAndOrderFront(nil) }
        w.makeFirstResponder(shellHost)
        // Every MPVFX_SMOKE_* hook, applied as on Linux and Windows (MPVFX_SMOKE_SELECT was ignored here, #28).
        smokeRunner = SmokeRunner(hooks: SmokeHooks(env: ProcessInfo.processInfo.environment), session: session, host: self)
        smokeRunner?.start()
    }

    /// One full-window canvas; EditorShellRouter lays out [left | preview | right] over the timeline
    /// and routes drawing and input to each region.
    func makeEditorView(_ session: EditorSession) -> NSView {
        // Before installShell: it starts background work (natural-size probes) whose results must land on the UI thread.
        session.postToUI = { body in DispatchQueue.main.async(execute: body) }
        let router = session.installShell(userData: paths.userData) { [weak self] in self?.ensurePlayTimer() }
        let host = MacCanvasHost { [router] c, size in router.draw(c, size: size) }
        host.input = router
        host.accessibilityControls = { [router] in router.accessibilityControls }
        host.onFilesDragged = { [weak session] p in session?.panels?.assetDrag?.filesDragged(over: p) }
        host.onFilesDropped = { [weak session] paths, p in session?.panels?.assetDrag?.dropFiles(paths, at: p) }
        host.cursorAt = { [router] x, y in
            MacShell.nsCursor(router.cursor(at: x, y))
        }
        shellHost = host
        session.schedule = { seconds, body in
            let work = DispatchWorkItem(block: body)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
            return { work.cancel() }
        }
        session.onExternalConflict = { answer in
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "The project file changed on disk"
            alert.informativeText = "It was changed outside MpVFX while you have unsaved edits."
            alert.addButton(withTitle: "Keep My Edits"); alert.addButton(withTitle: "Use the File on Disk")
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
        session.onProjectMoved = { message, answer in
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "The project folder is missing"
            alert.informativeText = message
            alert.addButton(withTitle: "Locate Folder…"); alert.addButton(withTitle: "Keep Editing")
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
        session.redraw = { [weak host] in host?.invalidate() }
        let dialogs = MacDialogs()
        session.panels?.dialogs = dialogs
        session.panels?.copyToClipboard = { text in
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
        session.panels?.revealPath = { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        session.onImportRequested = { [weak session] in
            Task {
                let files = await dialogs.showOpen(.init(title: "Import Media", directory: false, multiple: true))
                session?.postToUI { session?.importMedia(paths: files) }
            }
        }
        return host
    }

    /// ~60 Hz playback clock on the main run loop while playing (common modes: keeps running during
    /// window resizes and mouse tracking).
    func ensurePlayTimer() {
        guard let session, session.playback.isPlaying, playTimer == nil else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(playTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        playTimer = t
    }

    @objc func playTick() {
        let now = Date(), dt = now.timeIntervalSince(lastTick); lastTick = now
        guard let session, session.tick(dt) else {
            playTimer?.invalidate(); playTimer = nil
            session?.redraw()
            return
        }
    }

    /// Quit from a run-loop block, never from inside a main-queue block.
    /// `applicationShouldTerminate` answers `.terminateLater`, and the reply
    /// arrives on the main queue; terminating from within a main-queue block
    /// would spin the nested loop while that serial queue is still busy.
    func requestTerminate() {
        RunLoop.main.perform { NSApp.terminate(nil) }
    }

    // MARK: NSApplicationDelegate
    func applicationDidFinishLaunching(_ n: Notification) { lifecycle.activate(); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { lifecycle.activate(); return true }
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        if lifecycle.stopping && !lifecycle.hasWindow && !pendingTerminate { return .terminateNow }
        pendingTerminate = true
        lifecycle.quitRequested()   // SaveBarrier; answered from perform()
        return .terminateLater
    }
    // macOS keeps running with no windows (shouldQuitWhenAllWindowsClosed is false there).
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // MARK: NSWindowDelegate
    func windowShouldClose(_ sender: NSWindow) -> Bool { !lifecycle.closeRequested() }
    func windowWillClose(_ n: Notification) {
        playTimer?.invalidate(); playTimer = nil
        session?.audio?.stop()
        window = nil
        _ = lifecycle.windowDestroyed()
    }
}

/// MPVFX_SMOKE_SNAPSHOT=out.png: renders the window contents to a PNG; `SmokeRunner` then quits.
extension MacShell: SmokeHost {
    /// Main-queue timer (the shell's other timers run there too).
    func schedule(after seconds: Double, _ body: @escaping () -> Void) -> () -> Void {
        let work = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return { work.cancel() }
    }

    func writeSmokeSnapshot(_ path: String) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
        print("[MpVFX] smoke snapshot -> \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh), \(ok ? "ok" : "write failed"))")
    }

    /// Called from a main-queue timer, so it goes through `requestTerminate` (FOOTGUNS: quit hang).
    func quitAfterSmoke() { requestTerminate() }

    func smokeAppearanceChanged() { syncAppearanceMenu() }
}

/// File > Open Recent: the recent projects (title, folder as tooltip), then Clear Menu.
extension MacShell: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === panelsMenu { fillPanelsMenu(menu); return }
        let recent = session?.recentProjects ?? []
        for p in recent {
            let mi = NSMenuItem(title: p.title, action: #selector(openRecentProject(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = p.directory; mi.toolTip = p.directory
            menu.addItem(mi)
        }
        if !recent.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: recent.isEmpty ? nil : #selector(clearRecentProjects(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }
}

extension MacShell {
    /// Window > Panels: every panel, a checkmark on the open ones.
    func fillPanelsMenu(_ menu: NSMenu) {
        for p in session?.shell?.windowMenuPanels ?? [] {
            let mi = NSMenuItem(title: p.title, action: #selector(togglePanel(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = p.id; mi.state = p.checked ? .on : .off
            menu.addItem(mi)
        }
    }
}

/// The appearance items show a checkmark on the current setting whenever the View menu opens.
extension MacShell: NSMenuItemValidation {
    func validateMenuItem(_ mi: NSMenuItem) -> Bool {
        if mi.action == #selector(chooseAppearance(_:)), let raw = mi.representedObject as? String {
            mi.state = (session?.appearance?.appearance ?? .system).rawValue == raw ? .on : .off
        }
        return true
    }
}
#endif
