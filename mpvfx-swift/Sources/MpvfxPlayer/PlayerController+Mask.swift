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
import MpvfxShared
import MpvfxTimeline

/// Editing one shape mask on the stage (issue #297): while a mask is the stage's target, its outline and handles are
/// drawn over its layer, a press on a handle or inside a rectangle or ellipse drags it (⇧ keeps the proportions, ⌥
/// resizes about the centre), arrow keys move the grabbed handle 1 px (⇧: 10 px) of the layer, and Esc leaves the mode.
/// A drag is one commit at pointer-up and an arrow burst one commit after it goes idle, so each is one undo step.
/// The geometry is MaskStageEditor's; this file only turns pointer points into layer pixels and back.
public struct MaskStageTarget: Equatable, Sendable {
    public var clipId: String, maskId: String
    public init(clipId: String, maskId: String) { self.clipId = clipId; self.maskId = maskId }
}

/// The stage's mask-editing state.
struct MaskStageSession {
    var target: MaskStageTarget?
    /// The handle arrow keys move: the last one pressed (the mask's body or centre to begin with).
    var handle: MaskHandle?
    var masks: ((String) -> [NativeClipMask])?
    var commit: ((MaskStageTarget, NativeClipMask) -> Void)?
    var drag: (handle: MaskHandle, start: NativeClipMask, origin: CanvasPoint)?
    /// The mask as the drag or the nudge burst has made it so far (drawn, not yet in the document).
    var draft: NativeClipMask?
    var nudgeStart: NativeClipMask?
}

extension PlayerController {
    /// Within this distance (view px) of a mask handle, a press grabs it.
    public static let maskHandleHit = 12.0

    /// The mask the stage edits; setting it (nil: none) leaves the draft and any nudge burst behind.
    public var maskTarget: MaskStageTarget? {
        get { maskStage.target }
        set {
            flushNudge()
            maskStage.target = newValue; maskStage.draft = nil; maskStage.drag = nil; maskStage.handle = nil
            refreshMaskOverlay(); needsDisplay?()
        }
    }
    /// The masks of a clip as the document holds them.
    public var maskProvider: ((String) -> [NativeClipMask])? {
        get { maskStage.masks }
        set { maskStage.masks = newValue }
    }
    /// The edited mask, once a drag ends or a nudge burst settles.
    public var onMaskCommit: ((MaskStageTarget, NativeClipMask) -> Void)? {
        get { maskStage.commit }
        set { maskStage.commit = newValue }
    }

    /// The target's mask: the draft while a drag or burst runs, otherwise the document's.
    var maskInEdit: NativeClipMask? {
        guard let t = maskStage.target else { return nil }
        return maskStage.draft ?? maskStage.masks?(t.clipId).first { $0.id == t.maskId }
    }

    /// The target's layer: the selected element it belongs to, unlocked.
    var maskElement: StageElement? {
        guard let t = maskStage.target, let e = selected, e.id == t.clipId, !e.locked else { return nil }
        return e
    }

    func maskLayerSize(_ e: StageElement) -> CanvasSize { CanvasSize(max(1, e.rect.width), max(1, e.rect.height)) }

    /// A layer pixel as a stage point, and back: the layer's box maps onto its on-screen box, turned with it.
    func maskViewPoint(_ ve: StageElement, _ lp: CanvasPoint, layerSize s: CanvasSize) -> CanvasPoint {
        PlayerView.rotate(CanvasPoint(ve.rect.x + lp.x / s.width * ve.rect.width, ve.rect.y + lp.y / s.height * ve.rect.height),
                          about: ve.centre, ve.rotation)
    }
    func maskLayerPoint(_ ve: StageElement, _ p: CanvasPoint, layerSize s: CanvasSize) -> CanvasPoint {
        let l = TransformBox.local(ve, p)
        return CanvasPoint((l.x - ve.rect.x) / max(ve.rect.width, 1e-9) * s.width, (l.y - ve.rect.y) / max(ve.rect.height, 1e-9) * s.height)
    }

    /// The handle of the target mask under `p` (view px): the nearest within `maskHandleHit`, else the body of a
    /// rectangle or ellipse, else nil.
    func maskHandle(under p: CanvasPoint, _ e: StageElement) -> MaskHandle? {
        guard let mask = maskInEdit else { return nil }
        let ve = view.chromeElement(e, in: size), s = maskLayerSize(e)
        var best: (MaskHandle, Double)?
        for h in MaskStageEditor.handles(of: mask, layerSize: s) {
            let v = maskViewPoint(ve, h.point, layerSize: s), d = hypot(v.x - p.x, v.y - p.y)
            if d <= Self.maskHandleHit, best == nil || d <= best!.1 { best = (h.handle, d) }
        }
        if let best { return best.0 }
        return MaskStageEditor.contains(mask, maskLayerPoint(ve, p, layerSize: s), layerSize: s) ? .body : nil
    }

    /// A press while a mask is the target: grabs its handle (or body). False when it landed elsewhere, so the
    /// transform box and selection go on as before.
    func pressMask(at p: CanvasPoint) -> Bool {
        guard let e = maskElement, let mask = maskInEdit, let handle = maskHandle(under: p, e) else { return false }
        let ve = view.chromeElement(e, in: size)
        flushNudge()
        maskStage.drag = (handle, mask, maskLayerPoint(ve, p, layerSize: maskLayerSize(e)))
        maskStage.handle = handle
        gesture = .maskHandle
        refreshMaskOverlay(); needsDisplay?()
        return true
    }

    func dragMask(to p: CanvasPoint) {
        guard let e = maskElement, let d = maskStage.drag else { return }
        let ve = view.chromeElement(e, in: size), s = maskLayerSize(e)
        maskStage.draft = MaskStageEditor.dragged(d.start, handle: d.handle, to: maskLayerPoint(ve, p, layerSize: s), from: d.origin, layerSize: s,
                                                  keepProportions: shiftDown, fromCenter: modifiers.contains(.alt))
        refreshMaskOverlay(); needsDisplay?()
    }

    /// Pointer-up: a moved handle is one commit; a click that did not travel changes nothing.
    func finishMaskDrag() {
        defer { maskStage.drag = nil; maskStage.draft = nil; refreshMaskOverlay(); needsDisplay?() }
        guard dragEngaged, let t = maskStage.target, let d = maskStage.drag, let draft = maskStage.draft, draft != d.start else { return }
        maskStage.commit?(t, draft)
    }

    /// Esc during a drag puts the mask back.
    func cancelMaskDrag() {
        maskStage.drag = nil; maskStage.draft = nil
        refreshMaskOverlay()
    }

    /// Plain or ⇧ arrows move the grabbed handle 1 / 10 layer px while a mask is the target; a burst commits once.
    func maskNudgeKey(_ k: EditorKey) -> Bool {
        guard maskStage.target != nil, !k.ctrl, !k.meta, !k.alt, gesture == nil, recorder == nil, !view.cropActive,
              let e = maskElement, let mask = maskInEdit else { return false }
        let step = k.shift ? Self.nudgeShiftStep : Self.nudgeStep
        var dx = 0.0, dy = 0.0
        switch k.code {
        case .left: dx = -step; case .right: dx = step; case .up: dy = -step; case .down: dy = step
        default: return false
        }
        let handle = maskStage.handle ?? (mask.kind == "linear" || mask.kind == "band" ? .center : .body)
        if maskStage.nudgeStart == nil { maskStage.nudgeStart = mask }
        maskStage.draft = MaskStageEditor.nudged(mask, handle: handle, dx: dx, dy: dy, layerSize: maskLayerSize(e))
        nudgeAt = view.now()
        view.requestAnimationFrame?()
        refreshMaskOverlay(); needsDisplay?()
        return true
    }

    /// Commits a pending arrow burst on the mask (called with the element nudge flush).
    func flushMaskNudge() {
        defer { maskStage.nudgeStart = nil; if maskStage.drag == nil { maskStage.draft = nil }; refreshMaskOverlay() }
        guard let start = maskStage.nudgeStart, let t = maskStage.target, let draft = maskStage.draft, draft != start else { return }
        maskStage.commit?(t, draft)
    }

    /// Esc leaves mask editing (after a drag in progress is cancelled).
    func maskEscape() -> Bool {
        guard maskStage.target != nil else { return false }
        maskTarget = nil
        return true
    }

    /// Tells the view what to draw: the mask being edited with its handles, or nothing.
    func refreshMaskOverlay() {
        guard let e = maskElement, let mask = maskInEdit else { view.maskOverlay = nil; return }
        view.maskOverlay = MaskOverlay(clipId: e.id, mask: mask, layerSize: maskLayerSize(e), active: maskStage.drag?.handle ?? maskStage.handle)
    }
}
