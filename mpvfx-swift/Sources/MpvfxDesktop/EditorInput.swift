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

/// Input sink for a canvas host (GtkCanvasHost on Linux, MacCanvasHost on macOS).
/// Coordinates are view-local logical points, origin top-left, y down.
protocol CanvasInput: AnyObject {
    func pointerDown(x: Double, y: Double, shift: Bool)
    func pointerMove(x: Double, y: Double)
    func pointerUp(x: Double, y: Double)
    func secondaryClick(x: Double, y: Double)
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool)
    /// The same with how the deltas were measured: `precise` for trackpad pixel deltas (momentum included), false for
    /// wheel notches already turned into line steps of ~53pt. The default drops the flag.
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool, precise: Bool)
    func keyDown(_ k: EditorKey) -> Bool
    func keyUp(_ k: EditorKey)
    func resized(_ size: CanvasSize)
    /// Any button (DOM numbering, PointerButton) with the modifiers held. Hosts call these; the defaults forward
    /// the primary button to the plain methods above and drop the rest, so sinks that only know a left button
    /// keep working unchanged.
    func pointerDown(x: Double, y: Double, button: Int, modifiers: PointerModifiers)
    func pointerMove(x: Double, y: Double, modifiers: PointerModifiers)
    func pointerUp(x: Double, y: Double, button: Int)
}

extension CanvasInput {
    func pointerDown(x: Double, y: Double, button: Int, modifiers: PointerModifiers) {
        if button == PointerButton.primary { pointerDown(x: x, y: y, shift: modifiers.contains(.shift)) }
    }
    func pointerMove(x: Double, y: Double, modifiers: PointerModifiers) { pointerMove(x: x, y: y) }
    func pointerUp(x: Double, y: Double, button: Int) { if button == PointerButton.primary { pointerUp(x: x, y: y) } }
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool, precise: Bool) { scroll(dx: dx, dy: dy, x: x, ctrl: ctrl, shift: shift) }
}

/// Thin adapters from host input to the pure controllers. Keys not handled by the timeline fall
/// through to playback (global shortcuts work from either view).
final class TimelineInput: CanvasInput {
    let s: EditorSession; let region: TimelineRegion; let afterKey: () -> Void
    init(_ s: EditorSession, region: TimelineRegion, afterKey: @escaping () -> Void) {
        self.s = s; self.region = region; self.afterKey = afterKey
        s.installSceneSplitHook()
    }
    func pointerDown(x: Double, y: Double, shift: Bool) { region.pointerDown(x: x, y: y, shift: shift) }
    func pointerMove(x: Double, y: Double) { region.pointerMove(x: x, y: y) }
    func pointerUp(x: Double, y: Double) { region.pointerUp(x: x, y: y) }
    /// Option/Alt held turns the clip swap off for a drop (the original placement); hosts re-send the pointer when
    /// only the modifier changes, so the landing preview follows it mid-drag.
    func pointerDown(x: Double, y: Double, button: Int, modifiers: PointerModifiers) {
        s.timeline.dragSwapDisabled = modifiers.contains(.alt)
        // ⌘/Ctrl-click adds to the selection like ⇧ (clips and keyframe diamonds); ⌘/Ctrl+⌥ drag slips a clip, ⇧ drag on
        // an edge rolls the cut, ⌥ on an edge ripple-trims (TimelineController.pointerDown).
        guard button == PointerButton.primary else { return }
        region.pointerDown(x: x, y: y, keys: TimelineGestureKeys(shift: modifiers.contains(.shift), alt: modifiers.contains(.alt),
                                                                 command: modifiers.command))
    }
    func pointerMove(x: Double, y: Double, modifiers: PointerModifiers) {
        s.timeline.dragSwapDisabled = modifiers.contains(.alt); region.pointerMove(x: x, y: y)
    }
    func secondaryClick(x: Double, y: Double) { region.secondaryClick(x: x, y: y) }
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool) { region.scroll(dx: dx, dy: dy, x: x, ctrl: ctrl, shift: shift) }
    func keyDown(_ k: EditorKey) -> Bool {
        // Record's Esc comes before the timeline, which consumes Esc.
        let h = s.player.recordEscapeKey(k) || s.sceneSplitKey(k) || s.commandKey(k) || s.keyframeKey(k) || s.timeline.keyDown(k) || s.player.globalKey(k)
        afterKey(); return h
    }
    func keyUp(_ k: EditorKey) { s.playback.keyUp(k) }
    func resized(_ size: CanvasSize) { region.resized(size) }
}

final class PlayerInput: CanvasInput {
    let s: EditorSession; let afterKey: () -> Void
    init(_ s: EditorSession, afterKey: @escaping () -> Void) { self.s = s; self.afterKey = afterKey }
    func pointerDown(x: Double, y: Double, shift: Bool) { s.playerPointerDown(x: x, y: y, shift: shift); afterKey() }
    func pointerMove(x: Double, y: Double) { pointerMove(x: x, y: y, modifiers: []) }
    func pointerUp(x: Double, y: Double) { s.playerPointerUp(x: x, y: y) }
    /// Middle-button pan and other buttons go to the stage; moves carry modifiers (gesture recording reads them).
    func pointerDown(x: Double, y: Double, button: Int, modifiers: PointerModifiers) {
        s.player.modifiers = modifiers   // a Record take starts on the property set held at the press
        if button == PointerButton.primary { pointerDown(x: x, y: y, shift: modifiers.contains(.shift)); return }
        s.player.pointerDown(x: x, y: y, shift: modifiers.contains(.shift), button: button); afterKey()
    }
    func pointerMove(x: Double, y: Double, modifiers: PointerModifiers) {
        lastY = y; s.player.modifiers = modifiers; s.playerPointerMove(x: x, y: y)
    }
    func pointerUp(x: Double, y: Double, button: Int) {
        if button == PointerButton.primary { pointerUp(x: x, y: y) } else { s.player.pointerUp(x: x, y: y) }
    }
    func secondaryClick(x: Double, y: Double) { s.player.secondaryClick(x: x, y: y) }
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool) {
        if !s.playerScroll(x: x, y: lastY, dy: dy) { s.player.scroll(x: x, y: lastY, dx: dx, dy: dy, zoom: ctrl) }
    }
    var lastY = 0.0
    func keyDown(_ k: EditorKey) -> Bool {
        // Stage text editing gets first refusal; an unhandled M only adds markers in the timeline pane.
        let markerKey = !k.command && !k.alt && (k.code == .char("m") || k.code == .char("M"))
        let h = s.sceneSplitKey(k) || s.commandKey(k) || s.playerKey(k) || s.keyframeKey(k) || s.player.keyDown(k) || (!markerKey && s.timeline.keyDown(k)) || s.player.globalKey(k)
        afterKey(); return h
    }
    func keyUp(_ k: EditorKey) { s.playback.keyUp(k) }
    func resized(_ size: CanvasSize) { s.player.size = size }
}
