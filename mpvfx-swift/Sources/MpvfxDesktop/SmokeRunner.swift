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
// Smoke runs drive the editor through its own entry points (pointer handlers, panel actions, setAppearance) from
// the hooks `SmokeHooks(env:)` parsed, the same way under GTK, AppKit and Win32; before issue #28 each shell read
// the environment itself and macOS ignored MPVFX_SMOKE_SELECT and every gesture hook.
import Foundation
import MpvfxCanvas
import MpvfxDesktopCore
import MpvfxTheme

/// What a smoke run needs from the native shell; everything else runs on the session.
protocol SmokeHost: AnyObject {
    /// A UI-thread timer; the returned closure cancels it.
    func schedule(after seconds: Double, _ body: @escaping () -> Void) -> () -> Void
    func ensurePlayTimer()
    /// Writes the window as a PNG at `path` and prints `[MpVFX] smoke snapshot -> <path> …` (`CONTRACTS`).
    func writeSmokeSnapshot(_ path: String)
    /// Quits through the lifecycle and its save barrier (macOS: `requestTerminate`, see FOOTGUNS).
    func quitAfterSmoke()
    /// The smoke run switched the appearance (macOS updates its View menu checkmarks).
    func smokeAppearanceChanged()
}

extension SmokeHost {
    func smokeAppearanceChanged() {}
}

/// Applies every parsed hook to one session after the window is up. The shell keeps it alive for the run.
final class SmokeRunner {
    let hooks: SmokeHooks
    let session: EditorSession
    weak var host: SmokeHost?
    private(set) var audioFxStress: AudioFxStress?
    private(set) var memoryStress: MemoryStress?

    init(hooks: SmokeHooks, session: EditorSession, host: SmokeHost) {
        self.hooks = hooks; self.session = session; self.host = host
    }

    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        _ = host?.schedule(after: seconds, body)
    }

    /// Called once the window exists (shown, or hidden for a test run).
    func start() {
        if let path = hooks.snapshotPath { scheduleSnapshot(path) } else { scheduleAppearanceOnly() }
        // MPVFX_SMOKE_MEMORY=<rounds>: long play/scrub/grade/replay session, reports the footprint and exits.
        if let rounds = hooks.memoryRounds {
            after(1.0) { [self] in
                memoryStress = session.startMemoryStress(rounds: rounds, hooks: hooks) { [weak self] t, body in
                    self?.host?.schedule(after: t, body) ?? {}
                }
            }
        }
    }

    /// MPVFX_SMOKE_SET_APPEARANCE without a snapshot (a run captured from outside, e.g. `import -window root`):
    /// switches after MPVFX_SMOKE_DELAY_MS (default 1500) and keeps running.
    private func scheduleAppearanceOnly() {
        guard let a = hooks.setAppearance else { return }
        after(hooks.delay) { [self] in
            switchAppearance(a)
            print("[MpVFX] smoke appearance -> \(a.rawValue)")
        }
    }

    private func switchAppearance(_ a: ThemeAppearance) {
        session.setAppearance(a); host?.smokeAppearanceChanged()
    }

    /// Seek and select now; gestures, panels and the appearance switch after the first layout; the PNG after
    /// MPVFX_SMOKE_DELAY_MS, then quit.
    private func scheduleSnapshot(_ path: String) {
        if let t = hooks.seek { session.playback.seek(t); session.timeline.syncFromPlayback() }
        if let id = hooks.select { session.timeline.view.selection = [id] }
        session.syncStage(); session.redraw()
        after(hooks.gestureDelay) { [self] in
            applyTimelineGestures()
            applyPanelHooks()
            if let a = hooks.setAppearance { switchAppearance(a) }
            if let rounds = hooks.audioFxStress { startAudioFxStress(rounds) }
            session.redraw()
        }
        if hooks.export { scheduleExport() }
        after(hooks.delay) { [weak self] in
            self?.host?.writeSmokeSnapshot(path)
            self?.host?.quitAfterSmoke()
        }
    }

    private func applyTimelineGestures() {
        let tl = session.timeline
        if let m = hooks.marquee { tl.pointerDown(x: m.from.x, y: m.from.y); tl.pointerMove(x: m.to.x, y: m.to.y) }
        if let p = hooks.gapMenu {
            tl.secondaryClick(x: p.x, y: p.y)
            if let m = tl.view.gapMenu { tl.pointerMove(x: m.x + 20, y: m.y + 10) }
            if let m = tl.view.clipMenu, let r = m.itemRects().dropFirst().first?.1 { tl.pointerMove(x: r.x + 20, y: r.y + 10) }
        }
        if let d = hooks.drag { applyClipDrag(d) }
        if let p = hooks.click { tl.pointerDown(x: p.x, y: p.y); tl.pointerUp(x: p.x, y: p.y) }
        if let p = hooks.popover { openPopover(p) }
        if let r = hooks.razor { tl.tool = .razor; tl.pointerMove(x: r.x, y: r.y) }
    }

    /// Press, move and (when asked) release a clip; Option/Alt held stops the swap onto a busy row.
    private func applyClipDrag(_ d: SmokeClipDrag) {
        let tl = session.timeline, v = tl.view
        let y = { (row: Double) in v.rowTop(0) + row * v.trackHeight }
        tl.dragSwapDisabled = d.alt >= 1
        tl.pointerDown(x: v.x(for: d.from.x), y: y(d.from.y)); tl.pointerMove(x: v.x(for: d.from.x) + 4, y: y(d.from.y))
        tl.pointerMove(x: v.x(for: d.to.x), y: y(d.to.y))
        if d.alt == 2 { tl.dragSwapDisabled = false }
        print("[MpVFX] smoke drag landing: \(String(describing: v.dropTarget)) displaced: \(v.displacedDrop.map { "\($0.clipIds) -> \($0.target)" } ?? "none")")
        if d.release { tl.pointerUp(x: v.x(for: d.to.x), y: y(d.to.y)); tl.dragSwapDisabled = false }
        print("[MpVFX] smoke drag rows: \(v.tracks.map { $0.clips.map(\.id) })")
    }

    /// Transport popovers: speed hovers the 2x item, volume reveals the range, shortcuts opens the card.
    private func openPopover(_ which: SmokePopover) {
        let t = session.transport
        switch which {
        case .speed:
            _ = t.pointerDown(.init(t.speedTrigger().x + 4, t.speedTrigger().y + 4))
            let m = t.speed.menuRect(trigger: t.speedTrigger()); _ = t.pointerMove(.init(m.x + 10, m.maxY - 8))
        case .volume:
            _ = t.pointerMove(.init(t.volumeFrame().maxX - 6, t.volumeFrame().y + 6))
            while t.volume.tick(0.05) {}
            t.volume.setVolume(0.6)
        case .shortcuts:
            _ = t.pointerDown(.init(t.shortcutsTrigger().x + 4, t.shortcutsTrigger().y + 4))
        }
    }

    /// Side panels: add a bin file at the playhead (selects the new clip), drags from the bin and the file manager,
    /// inspector rows on the selection (after the add), the right panel tab.
    private func applyPanelHooks() {
        if let path = hooks.addMedia { session.panels?.addToTimeline(path: path, at: 0) }
        if let d = hooks.binDrag { applyBinDrag(d) }
        if let drop = hooks.fileDrop {
            let at = CanvasPoint(drop.at.x, drop.at.y)
            session.panels?.assetDrag?.filesDragged(over: at)
            let ok = session.panels?.assetDrag?.dropFiles(drop.paths, at: at) == true
            print("[MpVFX] smoke file drop: \(drop.paths.count) files, accepted \(ok)")
        }
        for row in hooks.inspector where session.panels?.applyInspectorRow(row.key, row.value) != true {
            print("[MpVFX] smoke: no inspector row \(row.key)")
        }
        if hooks.rightTabRenders { session.panels?.right.layout.setRightTab(.renders) }
        if hooks.settings { session.showSettings() }
    }

    /// Press, drag and (unless told not to) release through the shell router (bin → timeline/stage); without the
    /// release the snapshot shows the drag in flight.
    private func applyBinDrag(_ d: SmokeBinDrag) {
        guard let r = session.shell else { return }
        r.pointerDown(x: d.from.x, y: d.from.y, shift: false)
        for i in 1...8 {
            let f = Double(i) / 8
            r.pointerMove(x: d.from.x + (d.to.x - d.from.x) * f, y: d.from.y + (d.to.y - d.from.y) * f)
        }
        if d.release { r.pointerUp(x: d.to.x, y: d.to.y) }
        let clips = session.editor.document.sequence.tracks.flatMap(\.clips)
        print("[MpVFX] smoke bin drag: \(clips.count) clips; " + clips.map { "\($0.assetId)@\($0.startFrame)" }.joined(separator: " "))
    }

    /// MPVFX_SMOKE_AUDIOFX_STRESS: runs as long as it needs and exits with its verdict (0 pass, 3 fail).
    private func startAudioFxStress(_ rounds: Int) {
        guard let panels = session.panels else { return }
        let stress = AudioFxStress(session: session, panels: panels, rounds: rounds) { [weak self] t, body in
            self?.host?.schedule(after: t, body) ?? {}
        }
        stress.verbose = hooks.audioFxVerbose; stress.dumpStacks = hooks.audioFxStacks
        stress.start(seek: hooks.audioFxSeek, startPlayTimer: { [weak self] in self?.host?.ensurePlayTimer() }) { passed, report in
            print("[MpVFX] audiofx-stress \(passed ? "PASS" : "FAIL"): \(report)")
            exit(passed ? 0 : 3)
        }
        audioFxStress = stress
    }

    /// Renders tab, then Export pressed like a click 1.5 s in (the tab has painted); MPVFX_SMOKE_DELAY_MS has to
    /// leave time for the render to finish before the snapshot.
    private func scheduleExport() {
        after(1.0) { [self] in session.panels?.right.layout.setRightTab(.renders); session.redraw() }
        after(1.5) { [self] in pressExport(tries: 20) }
    }

    private func pressExport(tries: Int) {
        guard let right = session.panels?.rendersPanel, let b = right.hits.rect(where: { $0 == .export }) else {
            if tries > 0 { after(0.5) { [self] in pressExport(tries: tries - 1) } } else { print("[MpVFX] smoke export: no Export button") }
            session.redraw(); return
        }
        let p = CanvasPoint(b.x + b.width / 2, b.y + b.height / 2)
        _ = right.pointerDown(p); right.pointerUp(p); session.redraw()
        print("[MpVFX] smoke export: pressed Export")
    }
}
