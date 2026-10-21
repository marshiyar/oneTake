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
import MpvfxShared

/// Stage pointer logic for the tools bar, transport, selection
/// (shift toggles, marquee on empty canvas), move with snapping, group move, corner resize (⇧ uniform), rotate
/// (⇧ snaps to 15°), the crop tool (draft insets; Apply / Cancel / Reset), hover outline, canvas menu, and
/// preview zoom (ctrl/⌘ + wheel about the cursor) and pan (wheel, middle-button drag).
/// Gestures edit `view.elements` live; `onCommit` fires once per changed element at pointer-up (crop: on Apply).
public final class PlayerController {
    public let view: PlayerView
    public var size = CanvasSize(0, 0) { didSet { if size != oldValue { clampZoomToViewport() } } }
    /// Measures text for hit-testing outside of draw (the host's offscreen context); nil estimates widths.
    public var measure: CanvasContext?
    public var needsDisplay: (() -> Void)?
    public var onSelect: ((String?) -> Void)?
    /// The whole selection changed (multi-select, marquee).
    public var onSelectionChange: (([String]) -> Void)?
    public var onCommit: ((StageElement) -> Void)?
    /// Canvas menu actions.
    public var onZOrder: (([String], StageZOrderAction) -> Void)?
    public var onDelete: (([String]) -> Void)?
    /// Which z actions would move an element (disabled ones are greyed in the menu). Defaults to all.
    public var zOrderEnabled: ((String) -> Set<StageZOrderAction>)?
    public static let rotationSnapDegrees = 15.0
    public static let cropEdgeHit = 12.0
    /// A press must travel this far (view px) before it moves or resizes anything; a shorter press is a click and
    /// leaves the element as it was (BLOCKED_MOVE_THRESHOLD_PX).
    public static let dragThreshold = 4.0

    enum Gesture {
        case move(id: String, start: StageElement, x: Double, y: Double)
        case group(starts: [StageElement], x: Double, y: Double)
        case resize(id: String, corner: PlayerView.HandleCorner, start: StageElement, uniform: Bool)
        case rotate(id: String, start: StageElement, startAngle: Double)
        case crop(id: String, edge: CropEdge, start: StageElement)
        case marquee(x: Double, y: Double, additive: Bool)
        case pan(x: Double, y: Double, panX: Double, panY: Double)
        case compare
    }
    var gesture: Gesture?
    /// Where the move / group / resize press landed (view px) and whether it has travelled past `dragThreshold`.
    var pressPoint = CanvasPoint(0, 0)
    var dragEngaged = false
    /// Resize: the press point's offset from the grabbed corner (element-local view px), kept for the whole drag
    /// so the corner moves with the cursor instead of jumping onto it.
    var resizeGrab = CanvasPoint(0, 0)
    var shiftHeld = false
    /// Modifiers of the latest pointer event (hosts set them before forwarding a move).
    public var modifiers: PointerModifiers = []
    /// The element as it was when the crop tool opened (Cancel restores it).
    var cropOriginal: StageElement?

    // Gesture recording (wired by `enableGestureRecording`).
    public var recordingDocument: (() -> NativeProjectDocument?)?
    public var recordingEngine: KeyframeEngine?
    /// Commits the recorded document as one undo step ("Gesture recording"); returns false when it was refused.
    public var onRecordingCommit: ((_ edited: NativeProjectDocument, _ before: NativeProjectDocument) -> Bool)?
    public internal(set) var recorder: GestureRecorder?
    var recordingStart: StageElement?
    var recordingProjectId: String?
    var recordingLimit = Double.infinity
    var lastPointer = CanvasPoint(0, 0)

    /// Inserts a dropped library/media asset at the playhead (TimelineEditor.insertClip, "Add at playhead"); returns the new clip id.
    public var onInsertAsset: ((_ assetId: String, _ time: Double) -> String?)?

    /// Arrow-key nudge burst: the elements as they were before it, and the last key time.
    var nudgeStarts: [StageElement] = []
    var nudgeAt: Double?
    public static let nudgeCommitSeconds = 0.4

    /// Persisted snap/grid/zoom preferences (ui-preferences.json); set by `attachPreferencesStore`.
    public internal(set) var preferences: PreviewPreferencesStore?
    var zoomTouchedAt: Double?
    var savedZoom = PreviewZoom.fit
    var savedMuted = false

    public init(view: PlayerView) {
        self.view = view
        view.beforeDraw = { [weak self] in self?.frameTick() }
        view.keepAnimating = { [weak self] in self?.wantsFrames ?? false }
        view.liveElementIds = { [weak self] in self?.editingIds ?? [] }
    }

    /// Elements a gesture or the crop tool is editing live (hosts keep these when they rebuild the stage).
    public var editingIds: Set<String> {
        var ids = Set<String>()
        switch gesture {
        case let .move(id, _, _, _)?, let .resize(id, _, _, _)?, let .rotate(id, _, _)?, let .crop(id, _, _)?: ids.insert(id)
        case let .group(starts, _, _)?: ids.formUnion(starts.map(\.id))
        default: break
        }
        if let r = recorder { ids.insert(r.clipId) }
        ids.formUnion(nudgeStarts.map(\.id))
        if view.cropActive, let id = view.selection { ids.insert(id) }
        return ids
    }

    var selected: StageElement? { view.selectedIds.count == 1 ? view.selection.flatMap { id in view.elements.first { $0.id == id } } : nil }
    var bounds: CanvasRect { CanvasRect(x: 0, y: 0, width: size.width, height: size.height) }

    /// View point -> element-local (unrotated, view-scale) point.
    func local(_ p: CanvasPoint, _ ve: StageElement) -> CanvasPoint { PlayerView.rotate(p, about: ve.centre, -ve.rotation) }

    func hitElement(_ p: CanvasPoint) -> StageElement? {
        view.elements.reversed().first { e in
            let ve = view.chromeElement(e, in: size), lp = local(p, ve), r = ve.visibleRect
            return lp.x >= r.x && lp.x <= r.maxX && lp.y >= r.y && lp.y <= r.maxY
        }
    }

    func setSelection(_ ids: [String]) {
        if ids != view.selectedIds {
            if view.cropActive { cancelCrop() }
            view.selectedIds = ids
            onSelect?(view.selection)
            onSelectionChange?(ids)
        }
    }

    // MARK: Pointer

    public func pointerDown(x: Double, y: Double, shift: Bool = false, button: Int = 0) {
        let p = CanvasPoint(x, y); shiftHeld = shift; lastPointer = p
        pressPoint = p; dragEngaged = false
        flushNudge()
        if let menu = view.contextMenu {
            let hit = menu.choice(at: p, bounds: bounds)
            if hit.inside {
                if let ch = hit.choice {
                    view.contextMenu = nil
                    switch ch { case .z(let a): onZOrder?(menu.targetIds, a); case .delete: onDelete?(menu.targetIds) }
                }
                needsDisplay?(); return
            }
            view.contextMenu = nil
        }
        let vp = view.viewportRect(in: size)
        if button == 1 {   // middle button pans the preview
            if vp.contains(p) { gesture = .pan(x: x, y: y, panX: view.zoom.panX, panY: view.zoom.panY) }
            return
        }
        guard button == 0 else { return }
        // Tools bar (and its popover, which hangs over the stage).
        let tb = view.toolbar
        if !view.isFullscreen {
            let item = tb.item(at: p, width: size.width, cropAvailable: view.cropAvailable, cropActive: view.cropActive, measure)
            if let item {
                if let cmd = tb.press(item) { runCrop(cmd) }
                needsDisplay?(); return
            }
            if tb.gridPopoverOpen { tb.gridPopoverOpen = false; needsDisplay?() }
            if y < view.toolbarHeight { return }
        }
        if view.toolbar.compareEnabled, view.selection != nil {
            let f = view.frameRect(in: size), divider = f.x + f.width * view.toolbar.comparePosition
            if f.contains(p), abs(p.x - divider) <= 12 { gesture = .compare; return }
        }
        if let fit = view.fitButtonRect(in: size, measure), fit.contains(p) {
            view.zoom = .fit; view.zoomChanged(); zoomTouched(); needsDisplay?(); return
        }
        if let b = view.button(at: p, in: size) { press(b); return }
        guard vp.contains(p), recorder == nil else { return }   // recording: the stage only follows the pointer

        if let e = selected {
            let ve = view.chromeElement(e, in: size)
            let lp = local(p, ve), r = ve.visibleRect
            if view.cropActive {
                for edge in CropEdge.allCases {
                    let d: Double
                    switch edge {
                    case .top: d = abs(lp.y - r.y); case .bottom: d = abs(lp.y - r.maxY)
                    case .left: d = abs(lp.x - r.x); case .right: d = abs(lp.x - r.maxX)
                    }
                    let along = edge == .top || edge == .bottom ? (lp.x >= r.x - 12 && lp.x <= r.maxX + 12) : (lp.y >= r.y - 12 && lp.y <= r.maxY + 12)
                    if d <= Self.cropEdgeHit / 2 && along { gesture = .crop(id: e.id, edge: edge, start: e); return }
                }
                return   // crop mode: the stage only edits the crop
            }
            let rh = view.rotateHandleCentre(ve)
            if hypot(rh.x - x, rh.y - y) <= 11 {
                gesture = .rotate(id: e.id, start: e, startAngle: atan2(y - ve.centre.y, x - ve.centre.x) * 180 / .pi); return
            }
            for h in PlayerView.HandleCorner.allCases {
                let c = view.handleCentre(h, of: r)
                if abs(c.x - lp.x) <= PlayerView.handleHit / 2 && abs(c.y - lp.y) <= PlayerView.handleHit / 2 {
                    resizeGrab = CanvasPoint(lp.x - c.x, lp.y - c.y)
                    gesture = .resize(id: e.id, corner: h, start: e, uniform: shift); return
                }
            }
        }
        if view.cropActive { return }
        // Group box: dragging inside it moves every member.
        if view.selectedIds.count > 1, !shift, let gb = view.groupBounds(in: size), gb.contains(p) {
            gesture = .group(starts: view.elements.filter { view.selectedIds.contains($0.id) }, x: x, y: y)
            needsDisplay?(); return
        }
        let frame = view.frameRect(in: size)
        if let hit = hitElement(p) {
            if shift {
                var ids = view.selectedIds
                if let i = ids.firstIndex(of: hit.id) { ids.remove(at: i) } else { ids.append(hit.id) }
                setSelection(ids)
            } else {
                setSelection([hit.id])
                gesture = .move(id: hit.id, start: hit, x: x, y: y)
            }
        } else if frame.contains(p) {
            if !shift { setSelection([]) }
            gesture = .marquee(x: x, y: y, additive: shift)
        } else {
            setSelection([])   // a press outside the composition frame clears the selection
        }
        needsDisplay?()
    }

    func press(_ b: PlayerView.Button) {
        let pb = view.playback
        switch b {
        case .play: pb.togglePlay()
        case .mute: pb.audioMuted.toggle()
        case .loop: pb.loopEnabled.toggle()
        case .fullscreen: view.isFullscreen.toggle()
        case .speed, .shortcuts: break   // the popover overlays (MpvfxPanels) own these
        }
        needsDisplay?()
    }

    /// Right click: the canvas menu for the element under the pointer (selecting it first).
    public func secondaryClick(x: Double, y: Double) {
        let p = CanvasPoint(x, y)
        guard view.viewportRect(in: size).contains(p), !view.cropActive, let hit = hitElement(p) else {
            if view.contextMenu != nil { view.contextMenu = nil; needsDisplay?() }
            return
        }
        if !view.selectedIds.contains(hit.id) { setSelection([hit.id]) }
        let ids = view.selectedIds
        let enabled = ids.count == 1 ? (zOrderEnabled?(hit.id) ?? Set(StageZOrderAction.allCases)) : Set(StageZOrderAction.allCases)
        view.contextMenu = StageContextMenu(origin: p, targetIds: ids, enabled: onZOrder == nil ? [] : enabled, canDelete: onDelete != nil)
        needsDisplay?()
    }

    public func pointerMove(x: Double, y: Double, shift: Bool? = nil) {
        if let shift { shiftHeld = shift }
        let p = CanvasPoint(x, y); lastPointer = p
        if recorder != nil { recorder?.pointerMoved(p, modifiers: modifiers) }
        guard let g = gesture else { hover(p); return }
        let s = max(view.scale(in: size), 1e-9)
        switch g {
        case .compare:
            let f = view.frameRect(in: size)
            view.toolbar.comparePosition = max(0, min(1, (x - f.x) / max(f.width, 1))); needsDisplay?()
        case let .pan(x0, y0, px, py):
            let f = view.fittedRect(in: size), vp = view.viewportRect(in: size)
            let (cx, cy) = PreviewZoom.clampPan(x: px + x - x0, y: py + y - y0, percent: view.zoom.percent,
                                                viewport: CanvasSize(vp.width, vp.height), content: CanvasSize(f.width, f.height))
            view.zoom.panX = cx; view.zoom.panY = cy; needsDisplay?()
        case let .marquee(x0, y0, _):
            let m = CanvasRect(x: min(x0, x), y: min(y0, y), width: abs(x - x0), height: abs(y - y0))
            view.marquee = m
            view.marqueeCandidates = view.elements.filter { e in
                let b = PlayerView.bounds(view.chromeElement(e, in: size))
                return b.x < m.maxX && b.maxX > m.x && b.y < m.maxY && b.maxY > m.y
            }.map(\.id)
            needsDisplay?()
        case .move, .group, .resize:
            // Under the threshold a press is a click: nothing moves. Past it, deltas run from the press point, so the
            // grab offset holds for the whole drag.
            if !dragEngaged {
                guard hypot(x - pressPoint.x, y - pressPoint.y) >= Self.dragThreshold else { return }
                dragEngaged = true
            }
            drag(g, p, scale: s)
        default:
            drag(g, p, scale: s)
        }
    }

    func drag(_ g: Gesture, _ p: CanvasPoint, scale s: Double) {
        let x = p.x, y = p.y
        switch g {
        case .pan, .marquee, .compare: break
        case let .move(id, start, x0, y0):
            let d = snapped(moving: [start], dx: x - x0, dy: y - y0)
            update(id) { $0.rect.x = start.rect.x + d.dx / s; $0.rect.y = start.rect.y + d.dy / s }
        case let .group(starts, x0, y0):
            let d = snapped(moving: starts, dx: x - x0, dy: y - y0)
            for st in starts { update(st.id) { $0.rect.x = st.rect.x + d.dx / s; $0.rect.y = st.rect.y + d.dy / s } }
        case let .resize(id, corner, start, uniform):
            // Work in the element's unrotated frame (composition px); the opposite corner stays fixed on screen.
            let vs = view.chromeElement(start, in: size), k = PlayerView.chromeScale(start)
            let raw = local(p, vs), lp = CanvasPoint(raw.x - resizeGrab.x, raw.y - resizeGrab.y)
            let r = vs.rect, f = view.frameRect(in: size)
            var l = r.x, t = r.y, rr = r.maxX, b = r.maxY
            switch corner { case .nw: l = lp.x; t = lp.y; case .ne: rr = lp.x; t = lp.y; case .sw: l = lp.x; b = lp.y; case .se: rr = lp.x; b = lp.y }
            var w = max(1, rr - l), h = max(1, b - t)
            // Media corners always scale proportionally ("Corner drag is ALWAYS
            // proportional; there is no free-form stretch gesture"); other elements stay free unless ⇧.
            if uniform || shiftHeld || start.kind == .video || start.kind == .image {
                let q = max(w / r.width, h / r.height); w = r.width * q; h = r.height * q
            }
            if corner == .nw || corner == .sw { l = rr - w } else { rr = l + w }
            if corner == .nw || corner == .ne { t = b - h } else { b = t + h }
            let anchorLocal: CanvasPoint
            switch corner { case .nw: anchorLocal = .init(r.maxX, r.maxY); case .ne: anchorLocal = .init(r.x, r.maxY)
            case .sw: anchorLocal = .init(r.maxX, r.y); case .se: anchorLocal = .init(r.x, r.y) }
            let anchorScreen = PlayerView.rotate(anchorLocal, about: vs.centre, vs.rotation)
            let anchorNew = PlayerView.rotate(anchorLocal, about: CanvasPoint(l + w / 2, t + h / 2), vs.rotation)
            let dx = anchorScreen.x - anchorNew.x, dy = anchorScreen.y - anchorNew.y
            // Back to the unscaled box (the preview scales it about its centre by k), in composition px.
            let cx = l + dx + w / 2, cy = t + dy + h / 2, bw = w / k, bh = h / k
            let out = CanvasRect(x: (cx - bw / 2 - f.x) / s, y: (cy - bh / 2 - f.y) / s, width: bw / s, height: bh / s)
            update(id) { e in
                e.rect = out
                e.crop = start.crop.scaled(from: CanvasSize(start.rect.width, start.rect.height), to: CanvasSize(out.width, out.height))
            }
        case let .rotate(id, start, a0):
            let ve = view.chromeElement(start, in: size)
            let a = atan2(y - ve.centre.y, x - ve.centre.x) * 180 / .pi
            var delta = a - a0; while delta > 180 { delta -= 360 }; while delta < -180 { delta += 360 }
            let angle = start.rotation + delta
            let out = shiftHeld ? (angle / Self.rotationSnapDegrees).rounded() * Self.rotationSnapDegrees : (angle * 100).rounded() / 100
            update(id) { $0.rotation = out }
        case let .crop(id, edge, start):
            let ve = view.chromeElement(start, in: size)
            let lp = local(p, ve)
            let r = ve.rect, cs = s * PlayerView.chromeScale(start)
            update(id) { e in
                var c = e.crop
                switch edge {
                case .top: c.top = max(0, min(start.rect.height - c.bottom - 1, (lp.y - r.y) / cs))
                case .bottom: c.bottom = max(0, min(start.rect.height - c.top - 1, (r.maxY - lp.y) / cs))
                case .left: c.left = max(0, min(start.rect.width - c.right - 1, (lp.x - r.x) / cs))
                case .right: c.right = max(0, min(start.rect.width - c.left - 1, (r.maxX - lp.x) / cs))
                }
                e.crop = c
            }
        }
    }

    /// Snaps a move's delta (view px) against the other elements, the frame and the grid; publishes the guides.
    func snapped(moving starts: [StageElement], dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        let tb = view.toolbar
        guard tb.snapEnabled, SnapEngine.engaged(dx: dx, dy: dy) else { view.snapGuides = []; view.spacingGuides = []; return (dx, dy) }
        let ids = Set(starts.map(\.id))
        let rects = starts.map { PlayerView.bounds(view.chromeElement($0, in: size)) }
        var moving = rects[0]
        for r in rects.dropFirst() {
            let minX = min(moving.x, r.x), minY = min(moving.y, r.y)
            moving = CanvasRect(x: minX, y: minY, width: max(moving.maxX, r.maxX) - minX, height: max(moving.maxY, r.maxY) - minY)
        }
        let frame = view.frameRect(in: size)
        var targets = view.elements.filter { !ids.contains($0.id) }.enumerated()
            .map { SnapEngine.Target(PlayerView.bounds(view.chromeElement($0.element, in: size)), id: "snap-target-\($0.offset)") }
        let others = targets
        targets.append(SnapEngine.Target(frame, id: "composition"))
        let grid = tb.snapToGrid ? SnapEngine.gridEdges(frame: frame, divisions: tb.gridDivisions) : nil
        let r = SnapEngine.resolve(moving: moving, dx: dx, dy: dy, targets: targets, grid: grid)
        view.snapGuides = r.guides
        let moved = CanvasRect(x: moving.x + r.dx, y: moving.y + r.dy, width: moving.width, height: moving.height)
        view.spacingGuides = SnapEngine.equidistance(moving: moved, targets: others + [SnapEngine.Target(frame, id: "composition")])
        return (r.dx, r.dy)
    }

    func hover(_ p: CanvasPoint) {
        var changed = false
        if let menu = view.contextMenu {
            let row = menu.row(at: p, bounds: bounds)
            if row != menu.hovered { view.contextMenu?.hovered = row; changed = true }
        }
        let item = view.isFullscreen ? nil : view.toolbar.item(at: p, width: size.width, cropAvailable: view.cropAvailable, cropActive: view.cropActive, measure)
        if item != view.toolbar.hovered { view.toolbar.hovered = item; changed = true }
        let b = view.button(at: p, in: size)
        if b != view.hoveredButton { view.hoveredButton = b; changed = true }
        let fit = view.fitButtonRect(in: size, measure)?.contains(p) ?? false
        if fit != view.hoveredFit { view.hoveredFit = fit; changed = true }
        let inStage = view.viewportRect(in: size).contains(p) && item == nil && !fit
        let h = inStage ? hitElement(p)?.id : nil
        if h != view.hoveredElement { view.hoveredElement = h; changed = true }
        if changed { needsDisplay?() }
    }

    func update(_ id: String, _ f: (inout StageElement) -> Void) {
        guard let i = view.elements.firstIndex(where: { $0.id == id }) else { return }
        f(&view.elements[i]); needsDisplay?()
    }

    public func pointerUp(x: Double, y: Double) {
        defer { gesture = nil; view.snapGuides = []; view.spacingGuides = [] }
        guard let g = gesture else { return }
        switch g {
        case .compare: needsDisplay?()
        case .pan: zoomTouched(); return
        case let .marquee(_, _, additive):
            let picked = view.marqueeCandidates
            view.marquee = nil; view.marqueeCandidates = []
            if !picked.isEmpty || !additive {
                var ids = additive ? view.selectedIds : []
                for id in picked where !ids.contains(id) { ids.append(id) }
                setSelection(ids)
            }
            needsDisplay?()
        case .crop:
            needsDisplay?()   // crop edits stay a draft until Apply
        case let .move(id, start, _, _), let .resize(id, _, start, _):
            if dragEngaged { commit(id, start) } else { needsDisplay?() }   // a click changes nothing
        case let .rotate(id, start, _): commit(id, start)
        case let .group(starts, _, _):
            guard dragEngaged else { needsDisplay?(); return }   // a click changes nothing
            // Collect first: committing one member may rebuild `view.elements` from the document.
            let changed = starts.compactMap { st in view.elements.first { $0.id == st.id && $0 != st } }
            for e in changed { onCommit?(e) }
            needsDisplay?()
        }
    }

    func commit(_ id: String, _ start: StageElement) {
        if let e = view.elements.first(where: { $0.id == id }), e != start { onCommit?(e) }
        needsDisplay?()
    }

    // MARK: Crop tool

    public func runCrop(_ cmd: PreviewToolbar.CropCommand) {
        switch cmd {
        case .start:
            guard view.cropAvailable, let e = selected else { return }
            cropOriginal = e; view.cropActive = true
        case .reset:
            guard view.cropActive, let id = view.selection else { return }
            update(id) { $0.crop = .zero }
        case .cancel: cancelCrop()
        case .apply:
            guard view.cropActive, let id = view.selection, let e = view.elements.first(where: { $0.id == id }) else { return }
            view.cropActive = false
            if let o = cropOriginal, o != e { onCommit?(e) }
            cropOriginal = nil
        }
        needsDisplay?()
    }

    func cancelCrop() {
        guard view.cropActive else { return }
        if let o = cropOriginal, let i = view.elements.firstIndex(where: { $0.id == o.id }) { view.elements[i].crop = o.crop }
        view.cropActive = false; cropOriginal = nil
        needsDisplay?()
    }

    // MARK: Wheel and keys

    /// Wheel over the preview: ctrl/⌘ zooms about the cursor (100–400 %), otherwise pans a zoomed frame.
    /// Returns true when the preview consumed it.
    @discardableResult
    public func scroll(x: Double, y: Double, dx: Double, dy: Double, zoom: Bool) -> Bool {
        let vp = view.viewportRect(in: size)
        guard vp.contains(CanvasPoint(x, y)) else { return false }
        if recorder != nil { recorder?.wheel(dy, modifiers: modifiers.union(zoom ? .ctrl : [])); return true }
        let f = view.fittedRect(in: size)
        let viewport = CanvasSize(vp.width, vp.height), content = CanvasSize(f.width, f.height)
        if zoom {
            let cursor = CanvasPoint(x - (vp.x + vp.width / 2), y - (vp.y + vp.height / 2))
            view.zoom = view.zoom.wheelZoom(deltaY: dy, cursor: cursor, viewport: viewport, content: content)
            view.zoomChanged()
        } else {
            view.zoom = view.zoom.wheelPan(dx: dx, dy: dy, viewport: viewport, content: content)
        }
        zoomTouched()
        needsDisplay?()
        return true
    }

    /// Stage-owned keys: C toggles the crop tool, Enter applies it, Esc cancels it (or closes a menu),
    /// G toggles the grid, R records a gesture (when wired).
    public func keyDown(_ k: EditorKey) -> Bool {
        guard !k.command, !k.alt else { return false }
        if nudgeKey(k) { return true }
        flushNudge()
        switch k.code {
        case .escape:
            if cancelGesture() { return true }
            if view.contextMenu != nil { view.contextMenu = nil; needsDisplay?(); return true }
            if view.toolbar.gridPopoverOpen { view.toolbar.gridPopoverOpen = false; needsDisplay?(); return true }
            if view.cropActive { cancelCrop(); return true }
            if view.isFullscreen { view.isFullscreen = false; needsDisplay?(); return true }   // Esc leaves fullscreen
            return false
        case .enter where view.cropActive: runCrop(.apply); return true
        case .char(let ch) where ch == "c" || ch == "C":
            guard view.cropAvailable || view.cropActive else { return false }
            runCrop(view.cropActive ? .cancel : .start); return true
        case .char(let ch) where !k.shift && (ch == "g" || ch == "G" || ch == "\\"):
            // Bare S stays Split (the app reserves it), so only G reaches the tools bar.
            let handled = view.toolbar.key(ch); if handled { needsDisplay?() }; return handled
        case .char(let ch) where !k.shift && !k.isRepeat && (ch == "r" || ch == "R" || ch == "f" || ch == "F"):
            return globalKey(k)
        default: return false
        }
    }
}
