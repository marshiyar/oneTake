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
import MpvfxCanvas
import MpvfxTimeline
import MpvfxPlayer
import MpvfxPanels

/// The transport's right cluster with the real popovers: [volume ←slides] [speed] loop fullscreen [shortcuts].
/// PlayerView lays the slots out and draws play/time/loop/fullscreen; this overlay owns volume, speed and shortcuts.
final class TransportPopovers {
    let speed = SpeedPopover()
    let volume = VolumeSlider()
    let shortcuts = ShortcutsPanel()
    var speedHovered = false
    var size = CanvasSize(0, 0)
    weak var view: PlayerView?
    /// Text measurement for hit-testing outside of draw (ShortcutsPanel lays out with real font metrics).
    #if os(Linux)
    private let measure = CairoImageTarget(width: 4, height: 4)
    var measureContext: CanvasContext? { measure.canvas }
    #elseif os(macOS)
    private let measure = CoreGraphicsCanvas.offscreen()
    var measureContext: CanvasContext? { measure }
    #else
    var measureContext: CanvasContext? { nil }
    #endif

    // MARK: Layout (PlayerView.buttonRect owns the slot order)
    func slot(_ b: PlayerView.Button) -> CanvasRect { view?.buttonRect(b, in: size) ?? CanvasRect(x: 0, y: 0, width: 0, height: 0) }
    func speedTrigger() -> CanvasRect { slot(.speed) }
    func volumeFrame() -> CanvasRect { volume.frame(right: speedTrigger().x, y: size.height - PlayerView.controlsHeight + 6) }
    func shortcutsTrigger() -> CanvasRect { slot(.shortcuts) }
    /// The whole slot area this overlay owns (from the shortcuts trigger to the speed trigger).
    func clusterRect() -> CanvasRect {
        let v = volumeFrame(), s = shortcutsTrigger()
        return CanvasRect(x: v.x, y: v.y, width: s.maxX - v.x, height: v.height)
    }
    var anyOpen: Bool { speed.isOpen || shortcuts.isOpen }

    func draw(_ c: CanvasContext, size: CanvasSize, background: CanvasColor) {
        self.size = size
        shortcuts.draw(c, trigger: shortcutsTrigger())
        volume.draw(c, frame: volumeFrame())
        speed.draw(c, trigger: speedTrigger(), triggerHovered: speedHovered)
    }

    /// Returns true when the overlay consumed the press (open popovers are modal-ish: outside click closes).
    func pointerDown(_ p: CanvasPoint) -> Bool {
        if let m = measureContext, shortcuts.isOpen || shortcutsTrigger().contains(p) {
            let consumed = shortcuts.pointerDown(m, p, trigger: shortcutsTrigger())
            if shortcuts.isOpen { speed.isOpen = false }
            if consumed { return true }
        }
        if speed.isOpen || speedTrigger().contains(p) {
            let opened = speed.pointerDown(p, trigger: speedTrigger())
            if speed.isOpen { shortcuts.isOpen = false }
            if opened { return true }
        }
        if volume.pointerDown(p, frame: volumeFrame()) { return true }
        return volumeFrame().contains(p) || speedTrigger().contains(p) || shortcutsTrigger().contains(p)
    }

    /// Returns true if hover state changed in a way that needs a redraw.
    func pointerMove(_ p: CanvasPoint) -> Bool {
        let f = volumeFrame()
        let before = (speedHovered, volume.hovered, volume.buttonHovered, speed.hoveredIndex, shortcuts.hovered)
        speedHovered = speedTrigger().contains(p)
        // hover-reveal: the expanded slot stays open while the pointer is over the whole control.
        let hoverZone = CanvasRect(x: f.maxX - VolumeSlider.buttonSize - VolumeSlider.expandedWidth, y: f.y, width: VolumeSlider.buttonSize + VolumeSlider.expandedWidth, height: f.height)
        volume.hovered = volume.reveal > 0 ? hoverZone.contains(p) : volume.buttonRect(f).contains(p)
        volume.buttonHovered = volume.buttonRect(f).contains(p)
        volume.pointerDrag(p, frame: f)
        speed.pointerMove(p, trigger: speedTrigger())
        if let m = measureContext { shortcuts.pointerMove(m, p, trigger: shortcutsTrigger()) }
        let after = (speedHovered, volume.hovered, volume.buttonHovered, speed.hoveredIndex, shortcuts.hovered)
        return before != after
    }
    func pointerUp() { volume.pointerUp() }

    func scroll(_ p: CanvasPoint, dy: Double) -> Bool {
        guard let m = measureContext, shortcuts.isOpen, shortcuts.cardRect(m, trigger: shortcutsTrigger()).contains(p) else { return false }
        shortcuts.scrollBy(m, dy, trigger: shortcutsTrigger()); return true
    }

    /// Escape closes popovers; a focused jump field takes digits/Backspace/Enter.
    func keyDown(_ k: EditorKey) -> Bool {
        if case .escape = k.code {
            if speed.escape() { return true }
            if shortcuts.isOpen { return shortcuts.key("Escape", text: nil) }
            return false
        }
        guard shortcuts.isOpen, shortcuts.jumpFocused else { return false }
        switch k.code {
        case .enter: return shortcuts.key("Return", text: nil)
        case .backspace: return shortcuts.key("BackSpace", text: nil)
        case .char(let ch) where !k.command && !k.alt: return shortcuts.key(String(ch), text: String(ch))
        default: return false
        }
    }
}

extension EditorSession {
    func setupTransportPopovers() {
        let t = transport
        t.speed.onRateChange = { [weak self] r in self?.playback.setPlaybackRate(r); self?.redraw() }
        t.volume.onChange = { [weak self] _, muted in
            guard let self else { return }
            self.playback.audioMuted = muted; self.syncAudio(); self.redraw()
        }
        t.shortcuts.onSeek = { [weak self] s in self?.playback.seek(s); self?.timeline.syncFromPlayback(); self?.syncStage(); self?.redraw() }
        t.shortcuts.onUndo = { [weak self] in self?.editor.undo(); self?.syncStage(); self?.redraw() }
        t.shortcuts.onRedo = { [weak self] in self?.editor.redo(); self?.syncStage(); self?.redraw() }
        t.shortcuts.onClearIn = { [weak self] in self?.playback.inPoint = nil; self?.redraw() }
        t.shortcuts.onClearOut = { [weak self] in self?.playback.outPoint = nil; self?.redraw() }
        #if os(macOS)
        t.shortcuts.mac = true
        #endif
    }

    /// Mirror store state into the controls before drawing (M key, shuttle, I/O, history).
    func syncTransportState() {
        let t = transport
        t.speed.playbackRate = playback.playbackRate
        t.volume.muted = playback.audioMuted
        t.shortcuts.duration = playback.duration; t.shortcuts.fps = playback.fps
        t.shortcuts.inPoint = playback.inPoint; t.shortcuts.outPoint = playback.outPoint
        t.shortcuts.history = .init(canUndo: !editor.undoStack.isEmpty, canRedo: !editor.redoStack.isEmpty)
    }

    func drawPlayer(_ c: CanvasContext, size: CanvasSize) {
        syncTransportState()
        transport.view = player.view
        player.view.drawsPopoverSlots = false
        if player.measure == nil { player.measure = transport.measureContext }
        player.view.draw(c, size: size)
        transport.shortcuts.viewportHeight = size.height
        transport.draw(c, size: size, background: player.view.theme.shellBackground)
    }

    func playerPointerDown(x: Double, y: Double, shift: Bool) {
        if transport.pointerDown(CanvasPoint(x, y)) { redraw(); return }
        player.pointerDown(x: x, y: y, shift: shift)
    }
    func playerPointerMove(x: Double, y: Double) {
        let wasRevealTarget = transport.volume.hovered
        if transport.pointerMove(CanvasPoint(x, y)) { redraw() }
        if wasRevealTarget != transport.volume.hovered { animateVolumeReveal() }
        player.pointerMove(x: x, y: y)
    }
    func playerPointerUp(x: Double, y: Double) { transport.pointerUp(); player.pointerUp(x: x, y: y) }
    func playerScroll(x: Double, y: Double, dy: Double) -> Bool {
        guard transport.scroll(CanvasPoint(x, y), dy: dy) else { return false }
        redraw(); return true
    }
    func playerKey(_ k: EditorKey) -> Bool {
        guard transport.keyDown(k) else { return false }
        redraw(); return true
    }

    /// 150ms ease-out slide of the volume range, ticked on the UI thread.
    func animateVolumeReveal() {
        guard !volumeAnimating else { return }
        volumeAnimating = true
        Thread.detachNewThread { [weak self] in
            var running = true
            while running {
                Thread.sleep(forTimeInterval: 1.0 / 60)
                let sem = DispatchSemaphore(value: 0)
                self?.postToUI {
                    guard let self else { running = false; sem.signal(); return }
                    running = self.transport.volume.tick(1.0 / 60); self.redraw(); sem.signal()
                }
                sem.wait()
                if self == nil { break }
            }
            self?.postToUI { self?.volumeAnimating = false }
        }
    }
}
