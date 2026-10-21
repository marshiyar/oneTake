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

/// The on-canvas transform box: eight handles (edges stretch one side, corners scale; ⇧ keeps or frees the aspect,
/// ⌥ scales about the anchor), rotation by the chip or just outside a corner (⇧ snaps to 15°) about a draggable
/// anchor (double-click puts it back in the centre), ⇧ axis lock on moves, ⌘/Ctrl to drag without snapping, the
/// live readout and the cursor. Locked layers select but do not transform.
extension PlayerController {
    public static let anchorDoubleClickSeconds = 0.4
    /// Within this distance (view px) of a handle point, the anchor snaps onto it.
    public static let anchorSnapPx = 8.0

    /// Shape the host should show for the pointer.
    public var stageCursor: StageCursor { view.transformChrome.cursor }

    /// Every element a gesture changed, at once (one undo step for the host); nil: `onCommit` per element.
    public var onCommitGroup: (([StageElement]) -> Void)? {
        get { transformSession.commitGroup }
        set { transformSession.commitGroup = newValue }
    }

    /// The point transform.position offsets for an element (composition px), so the move readout shows the same
    /// X / Y as the inspector. nil: the box's top-left corner.
    public var readoutOrigin: ((StageElement) -> CanvasPoint?)? {
        get { transformSession.readoutOrigin }
        set { transformSession.readoutOrigin = newValue }
    }

    var shiftDown: Bool { shiftHeld || modifiers.contains(.shift) }

    func commitAll(_ changed: [StageElement]) {
        guard !changed.isEmpty else { return }
        if let group = onCommitGroup { group(changed) } else { for e in changed { onCommit?(e) } }
    }

    // MARK: Hit testing

    /// The part of the selected element's transform box under `p` (view px), nil outside it.
    /// Order: the anchor, the handles (corners first), the rotate chip, the body, then the rotate zones just outside
    /// the corners.
    func transformHit(_ p: CanvasPoint, _ ve: StageElement) -> TransformHit? {
        let anchor = TransformBox.screenPoint(ve, unit: view.transformChrome.anchor(ve.id))
        if hypot(anchor.x - p.x, anchor.y - p.y) <= PlayerView.anchorHit { return .anchor }
        if let h = handle(under: p, ve) { return .handle(h) }
        let chip = view.rotateHandleCentre(ve)
        if hypot(chip.x - p.x, chip.y - p.y) <= PlayerView.handleHit / 2 { return .rotateChip }
        return outsideHit(p, ve)
    }

    /// The handle whose 24 pt square target holds `p`.
    func handle(under p: CanvasPoint, _ ve: StageElement) -> TransformHandle? {
        let half = PlayerView.handleHit / 2, lp = TransformBox.local(ve, p)
        return (TransformHandle.corners + TransformHandle.edges).first { h in
            let c = TransformBox.localPoint(ve, unit: h.unit)
            return view.showsHandle(h, of: ve) && abs(c.x - lp.x) <= half && abs(c.y - lp.y) <= half
        }
    }

    /// Inside the visible box: the body; just outside a corner: that corner's rotate zone.
    func outsideHit(_ p: CanvasPoint, _ ve: StageElement) -> TransformHit? {
        let lp = TransformBox.local(ve, p), v = ve.visibleRect
        if lp.x >= v.x && lp.x <= v.maxX && lp.y >= v.y && lp.y <= v.maxY { return .body }
        let reach = PlayerView.handleHit / 2 + PlayerView.rotateZone
        let corner = TransformHandle.corners.first { h in
            let c = TransformBox.localPoint(ve, unit: h.unit)
            return hypot(c.x - lp.x, c.y - lp.y) <= reach
        }
        return corner.map { .rotateZone($0) }
    }

    /// A press on the selected, unlocked element's box: starts a resize, rotate or anchor drag. False when the press
    /// is for the body or outside the box (moves and selection go on as before).
    func pressTransform(_ e: StageElement, at p: CanvasPoint) -> Bool {
        guard !e.locked else { return false }
        let ve = view.chromeElement(e, in: size)
        switch transformHit(p, ve) {
        case .anchor?:
            pressAnchor(e, at: p)
        case .rotateChip?, .rotateZone?:
            let pivot = TransformBox.screenPoint(ve, unit: view.transformChrome.anchor(e.id))
            gesture = .rotate(id: e.id, start: e, startAngle: TransformBox.angle(of: p, about: pivot))
        case .handle(let h)?:
            let lp = TransformBox.local(ve, p), c = TransformBox.localPoint(ve, unit: h.unit)
            resizeGrab = CanvasPoint(lp.x - c.x, lp.y - c.y)
            gesture = .resize(id: e.id, handle: h, start: e, uniform: shiftHeld)
        case .body?, nil:
            return false
        }
        view.transformChrome.active = transformHit(p, ve)
        updateCursor()
        needsDisplay?()
        return true
    }

    /// A press on the anchor drags it; a second press within 0.4 s puts it back in the centre.
    func pressAnchor(_ e: StageElement, at p: CanvasPoint) {
        let t = view.now()
        if let last = transformSession.lastAnchorPress, last.id == e.id, t - last.at <= Self.anchorDoubleClickSeconds,
           hypot(last.point.x - p.x, last.point.y - p.y) <= Self.dragThreshold {
            view.transformChrome.anchors[e.id] = nil
            transformSession.lastAnchorPress = nil
            gesture = nil
            return
        }
        transformSession.lastAnchorPress = (e.id, t, p)
        gesture = .anchor(id: e.id, start: e)
    }

    // MARK: Drags

    /// Handle drag: the element's box after the handle moved to `p`, snapped when the box is upright.
    func dragResize(_ g: Gesture, to p: CanvasPoint) {
        guard case let .resize(id, handle, start, uniform) = g else { return }
        let vs = view.chromeElement(start, in: size), raw = TransformBox.local(vs, p)
        var req = TransformResize(handle: handle, pointer: CanvasPoint(raw.x - resizeGrab.x, raw.y - resizeGrab.y),
                                  keepAspect: keepsAspect(start, handle, uniform: uniform), fromAnchor: modifiers.contains(.alt))
        req.anchor = view.transformChrome.anchor(id)
        var out = TransformBox.resized(vs, req)
        if let snap = resizeSnap(out, handle: handle, excluding: id) {
            req.pointer = CanvasPoint(req.pointer.x + snap.dx, req.pointer.y + snap.dy)
            out = TransformBox.resized(vs, req)
        }
        let doc = documentElement(out, start: start)
        update(id) { $0 = doc }
        let r = doc.rect
        showReadout("W \(Self.whole(r.width)) × H \(Self.whole(r.height))", at: p)
    }

    /// Corners on images and video keep their aspect unless ⇧ frees them; on text and shapes, and on every edge, ⇧
    /// keeps it. Media are fitted inside their box, so a free corner on a picture would only letterbox it.
    func keepsAspect(_ e: StageElement, _ handle: TransformHandle, uniform: Bool) -> Bool {
        let shift = uniform || shiftDown
        let media = e.kind == .video || e.kind == .image
        return handle.isCorner && media ? !shift : shift
    }

    /// Snaps the dragged side(s) of an upright box to the other layers, the frame and the grid (⌘/Ctrl: off).
    func resizeSnap(_ out: StageElement, handle: TransformHandle, excluding id: String) -> (dx: Double, dy: Double)? {
        view.snapGuides = []; view.spacingGuides = []
        guard view.toolbar.snapEnabled, !modifiers.command, dragEngaged, abs(remainder(out.rotation, 360)) < 1e-9 else { return nil }
        let b = out.visibleRect
        let x: Double? = handle.movesX ? (handle.unit.x == 0 ? b.x : b.maxX) : nil
        let y: Double? = handle.movesY ? (handle.unit.y == 0 ? b.y : b.maxY) : nil
        let t = snapTargets(excluding: [id])
        let r = SnapEngine.resolveEdges(x: x, y: y, targets: t.all, grid: t.grid)
        view.snapGuides = r.guides
        return r.dx == 0 && r.dy == 0 ? nil : (r.dx, r.dy)
    }

    /// Rotate drag (chip or corner zone) about the anchor; ⇧ snaps to 15°.
    func dragRotate(_ g: Gesture, to p: CanvasPoint) {
        guard case let .rotate(id, start, a0) = g else { return }
        let vs = view.chromeElement(start, in: size), anchor = view.transformChrome.anchor(id)
        let a = TransformBox.angle(of: p, about: TransformBox.screenPoint(vs, unit: anchor))
        let angle = TransformBox.rotation(start: start.rotation, from: a0, to: a, snap: shiftDown ? Self.rotationSnapDegrees : nil)
        if anchor == TransformBox.centreAnchor {
            update(id) { $0.rotation = angle }   // about the centre only the rotation changes
        } else {
            let doc = documentElement(TransformBox.rotated(vs, by: angle - start.rotation, anchor: anchor), start: start)
            update(id) { $0 = doc }
        }
        showReadout(String(format: "%.1f°", angle), at: p)
    }

    /// Anchor drag: follows the pointer, snapping onto the nine handle points (centre included).
    func dragAnchor(_ g: Gesture, to p: CanvasPoint) {
        guard case let .anchor(id, start) = g else { return }
        let ve = view.chromeElement(start, in: size)   // an anchor drag leaves the box where it is
        var unit = TransformBox.unit(ve, of: p)
        for u in TransformHandle.allCases.map(\.unit) + [TransformBox.centreAnchor] {
            let q = TransformBox.screenPoint(ve, unit: u)
            if hypot(q.x - p.x, q.y - p.y) <= Self.anchorSnapPx { unit = u; break }
        }
        view.transformChrome.anchors[id] = unit == TransformBox.centreAnchor ? nil : unit
        needsDisplay?()
    }

    /// Move delta from the press (view px): ⇧ keeps only the larger axis, then snapping, which may not bring the
    /// locked axis back.
    func moveDelta(x0: Double, y0: Double, to p: CanvasPoint, moving starts: [StageElement]) -> (dx: Double, dy: Double) {
        var dx = p.x - x0, dy = p.y - y0
        let lockX = shiftDown && abs(dy) > abs(dx), lockY = shiftDown && abs(dx) >= abs(dy)
        if lockX { dx = 0 }
        if lockY { dy = 0 }
        var d = snapped(moving: starts, dx: dx, dy: dy)
        if lockX { d.dx = 0; view.snapGuides.removeAll { $0.axis == .x } }
        if lockY { d.dy = 0; view.snapGuides.removeAll { $0.axis == .y } }
        return d
    }

    /// The move readout: the element's position as the inspector shows it.
    func moveReadout(_ id: String, at p: CanvasPoint) {
        guard let e = view.elements.first(where: { $0.id == id }) else { return }
        let o = readoutOrigin?(e) ?? CanvasPoint(0, 0)
        showReadout("X \(Self.whole(e.rect.x - o.x))  Y \(Self.whole(e.rect.y - o.y))", at: p)
    }

    // MARK: Conversion, readout, cursor

    /// A chrome (view px, uniformly scaled) element back in composition px: the box the preview scales by the
    /// element's uniform scale about its centre.
    func documentElement(_ out: StageElement, start: StageElement) -> StageElement {
        let k = PlayerView.chromeScale(start), s = max(view.scale(in: size), 1e-9), f = view.frameRect(in: size)
        let c = out.centre, bw = out.rect.width / k, bh = out.rect.height / k, ks = k * s
        var e = start
        e.rect = CanvasRect(x: (c.x - bw / 2 - f.x) / s, y: (c.y - bh / 2 - f.y) / s, width: bw / s, height: bh / s)
        e.crop = CropInsets(top: out.crop.top / ks, right: out.crop.right / ks, bottom: out.crop.bottom / ks, left: out.crop.left / ks)
        e.rotation = out.rotation
        return e
    }

    static func whole(_ v: Double) -> String { String(Int(v.rounded())) }

    func showReadout(_ text: String, at p: CanvasPoint) {
        view.transformChrome.readout = TransformReadout(text: text, at: p)
        view.transformChrome.pointer = p
    }

    /// Clears the drag-only chrome when a gesture ends.
    func endTransformGesture() {
        view.transformChrome.readout = nil
        view.transformChrome.active = nil
        transformSession.lockedPress = nil
        transformSession.lockedToastShown = false
        updateCursor()
    }

    /// Hover over the stage: which part of the selected box is under the pointer, and the cursor. Returns whether
    /// anything drawn changed.
    func updateTransformHover(_ p: CanvasPoint) -> Bool {
        let before = view.transformChrome
        view.transformChrome.pointer = p
        if let e = selected, !view.cropActive, !view.playback.isPlaying, !e.locked {
            view.transformChrome.hover = transformHit(p, view.chromeElement(e, in: size))
        } else {
            view.transformChrome.hover = nil
        }
        updateCursor()
        let rotateGlyph = view.transformChrome.cursor == .rotate || before.cursor == .rotate
        return before.hover != view.transformChrome.hover || before.cursor != view.transformChrome.cursor || rotateGlyph
    }

    func updateCursor() { view.transformChrome.cursor = currentCursor() }

    func currentCursor() -> StageCursor {
        if recorder != nil || view.cropActive { return .arrow }
        if let g = gesture { return Self.cursor(for: g) }
        if let h = view.transformChrome.hover, let e = selected { return Self.cursor(over: h, rotation: e.rotation) }
        guard let id = view.hoveredElement, let e = view.elements.first(where: { $0.id == id }) else { return .arrow }
        return e.locked ? .notAllowed : .move
    }

    static func cursor(for g: Gesture) -> StageCursor {
        switch g {
        case .move, .group: return .move
        case let .resize(_, h, start, _): return .resize(degrees: h.cursorAngle + start.rotation)
        case .rotate: return .rotate
        case .anchor: return .anchor
        case .pan, .marquee, .crop: return .arrow
        }
    }

    static func cursor(over hit: TransformHit, rotation: Double) -> StageCursor {
        switch hit {
        case .handle(let h): return .resize(degrees: h.cursorAngle + rotation)
        case .rotateZone, .rotateChip: return .rotate
        case .anchor: return .anchor
        case .body: return .move
        }
    }

    /// A drag that started on a locked layer moves nothing and says why once it passes the drag threshold.
    func lockedDragFeedback(_ p: CanvasPoint) {
        guard transformSession.lockedPress != nil, !transformSession.lockedToastShown,
              hypot(p.x - pressPoint.x, p.y - pressPoint.y) >= Self.dragThreshold else { return }
        transformSession.lockedToastShown = true
        view.showToast(Self.lockedMessage, isError: true)
        needsDisplay?()
    }

    public static let lockedMessage = "This layer's track is locked: unlock it to move or transform the layer"
}

extension PlayerController {
    /// Arrows with only locked layers selected: nothing moves and the stage says why (the key is still consumed,
    /// so it does not fall through to the playhead). Nothing selected on the stage: the key is not ours.
    /// A press inside the group box moves its unlocked members; with every member locked nothing moves and the drag
    /// gets the locked-layer message (a group gesture always has at least one element to move).
    func pressGroup(at p: CanvasPoint) {
        let starts = unlockedElements(view.selectedIds)
        if starts.isEmpty { transformSession.lockedPress = view.selection; return }
        gesture = .group(starts: starts, x: p.x, y: p.y)
    }

    /// The listed elements a nudge or drag may move (locked ones left out).
    func unlockedElements(_ ids: [String]) -> [StageElement] { view.elements.filter { ids.contains($0.id) && !$0.locked } }

    /// A move with no gesture running: the hover state, the transform box's hovered part and cursor, and the locked
    /// layer message for a drag that started on one.
    func idleMove(_ p: CanvasPoint) {
        lockedDragFeedback(p)
        hover(p)
        if updateTransformHover(p) { needsDisplay?() }
    }

    func refuseLockedNudge(_ ids: [String]) -> Bool {
        guard view.elements.contains(where: { ids.contains($0.id) }) else { return false }
        view.showToast(Self.lockedMessage, isError: true)
        needsDisplay?()
        return true
    }
}
