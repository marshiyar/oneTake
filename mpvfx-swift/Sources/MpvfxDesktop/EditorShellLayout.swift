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
import MpvfxPanels
import MpvfxTimeline

/// The editor window's regions. Panels sit edge to edge; the 1px seams between them are the black shell
/// (`studioBg`) showing through (docs/DESIGN.md, principle 1):
///
///     top row:      [left sidebar | seam | preview: top bar (36px) / player | seam | right panel]
///     seam          the timeline resize divider (10px hit band)
///     timeline      height timelineH: toolbar + tracks
///     seam
///     status line   22px: the hint for what is under the pointer
///
/// Column widths come from `PanelFit`/`PanelLayoutState`; the timeline height is
/// `PanelFit.fitTimelineHeight` of the space above the status line, with a default of 360 points.
struct EditorShellFrames: Equatable {
    var size: CanvasSize
    var left: CanvasRect
    var leftSeam: CanvasRect?
    var leftSeamHit: CanvasRect?
    var preview: CanvasRect
    var previewTopBar: CanvasRect
    var player: CanvasRect           // below the top bar
    var rightSeam: CanvasRect?
    var rightSeamHit: CanvasRect?
    var right: CanvasRect
    var leftRail: Bool, rightRail: Bool
    var timelineDivider: CanvasRect  // the seam above the timeline
    var timelineDividerHit: CanvasRect
    var timeline: CanvasRect
    var statusLine: CanvasRect

    static let previewTopBarHeight = 36.0     // `top-9`
    static let defaultTimelineHeight = 360.0

    /// The height the top row, the divider and the timeline share: the window less the status line and its seam.
    static func timelineContainerHeight(_ windowHeight: Double) -> Double {
        max(0, windowHeight - ShellStatusLine.height - PanelTheme.seamWidth)
    }

    static func compute(size: CanvasSize, layout: PanelLayoutState, timelineHeight: Double, fullscreen: Bool) -> EditorShellFrames {
        let zero = CanvasRect(x: 0, y: 0, width: 0, height: 0)
        if fullscreen {
            // The preview drops its chrome in fullscreen and fills the screen; the stage starts at the top.
            let all = CanvasRect(x: 0, y: 0, width: size.width, height: size.height)
            return EditorShellFrames(size: size, left: zero, leftSeam: nil, leftSeamHit: nil, preview: all,
                                     previewTopBar: CanvasRect(x: 0, y: 0, width: size.width, height: 0), player: all,
                                     rightSeam: nil, rightSeamHit: nil, right: zero, leftRail: false, rightRail: false,
                                     timelineDivider: zero, timelineDividerHit: zero, timeline: zero, statusLine: zero)
        }
        let seam = PanelTheme.seamWidth
        let container = timelineContainerHeight(size.height)
        let th = PanelFit.fitTimelineHeight(container, timelineHeight)
        let topH = max(0, container - seam - th)
        let r = ShellRegions.compute(size: CanvasSize(size.width, topH), layout: layout)
        let barH = min(previewTopBarHeight, r.preview.height)
        let topBar = CanvasRect(x: r.preview.x, y: 0, width: r.preview.width, height: barH)
        let player = CanvasRect(x: r.preview.x, y: barH, width: r.preview.width, height: max(0, r.preview.height - barH))
        let divider = CanvasRect(x: 0, y: topH, width: size.width, height: seam)
        // Hit band: 4px above the seam to 5px below it.
        let dividerHit = CanvasRect(x: 0, y: topH - 4, width: size.width, height: 10)
        let timeline = CanvasRect(x: 0, y: topH + seam, width: size.width, height: max(0, container - topH - seam))
        let statusY = container + seam
        let statusLine = CanvasRect(x: 0, y: statusY, width: size.width, height: max(0, size.height - statusY))
        return EditorShellFrames(size: size, left: r.left, leftSeam: r.leftSeam, leftSeamHit: r.leftSeamHit, preview: r.preview,
                                 previewTopBar: topBar, player: player, rightSeam: r.rightSeam, rightSeamHit: r.rightSeamHit, right: r.right,
                                 leftRail: r.leftRail, rightRail: r.rightRail, timelineDivider: divider, timelineDividerHit: dividerHit,
                                 timeline: timeline, statusLine: statusLine)
    }
}

/// One region's content: a painter in region-local coordinates (origin top-left, y down) and its input sink.
/// The painter is clipped to the region; the input receives region-local coordinates and the region size.
final class ShellPane {
    var paint: (CanvasContext, CanvasSize) -> Void
    weak var input: CanvasInput?
    /// The status line's text for what is under the pointer in this pane (nil: the region's own hint).
    var hint: () -> String? = { nil }
    var lastSize = CanvasSize(-1, -1)
    init(input: CanvasInput? = nil, paint: @escaping (CanvasContext, CanvasSize) -> Void) { self.paint = paint; self.input = input }
}

/// A drag that starts in one pane and drops in another (a bin asset onto the timeline or the stage).
/// The router keeps sending the source pane its moves (pointer capture) and also reports where the pointer is.
protocol CrossPaneDrag: AnyObject {
    func isDragging(from region: EditorShellRouter.Region) -> Bool
    /// `local` is in `region`'s coordinates (nil region: outside every pane).
    func dragMoved(over region: EditorShellRouter.Region?, local: CanvasPoint, window: CanvasPoint)
    func dragEnded(over region: EditorShellRouter.Region?, local: CanvasPoint)
    /// Drawn above every pane, in window coordinates.
    func drawDrag(_ c: CanvasContext)
}

/// Lays the window out and routes drawing and input to the region panes. Host-neutral: a shell gives it one
/// full-window canvas (MacCanvasHost / GtkCanvasHost) and forwards that canvas's events here.
///
/// Panes are plugged in by whoever owns the content: `player` and `timeline` are the editor's; `left`, `right`,
/// `previewTopBar` and `timelineToolbar` are filled by the side-panel / toolbar ports. A region without a pane
/// is drawn as its empty panel so the proportions are right before its content lands. The router draws the
/// status line itself.
final class EditorShellRouter: CanvasInput {
    enum Region: Hashable, CaseIterable { case left, previewTopBar, player, right, timeline }
    weak var crossPaneDrag: CrossPaneDrag?
    enum Drag: Equatable { case leftSeam, rightSeam, timelineDivider(startY: Double, startH: Double) }

    let layout: PanelLayoutState
    var panes: [Region: ShellPane] = [:]
    /// User intent for the timeline height (persisted by `onTimelineHeightCommit`).
    var timelineHeight: Double
    var onTimelineHeightCommit: (Double) -> Void = { _ in }
    var isFullscreen: () -> Bool = { false }
    var needsDisplay: () -> Void = {}
    /// Hovered seam/divider, for the hover tint and the host's resize cursor.
    private(set) var hoveredHandle: Drag?
    private(set) var frames: EditorShellFrames?
    private(set) var drag: Drag?
    /// Pane that got the press; it receives moves/up until release (pointer capture).
    private var captured: Region?
    private var hovered: Region?
    /// Pane that takes keys (the last one pressed; the timeline until then).
    private(set) var focused: Region = .timeline
    private var size = CanvasSize(0, 0)

    init(layout: PanelLayoutState, timelineHeight: Double = EditorShellFrames.defaultTimelineHeight) {
        self.layout = layout
        self.timelineHeight = timelineHeight
    }

    func relayout() -> EditorShellFrames {
        let f = EditorShellFrames.compute(size: size, layout: layout, timelineHeight: timelineHeight, fullscreen: isFullscreen())
        frames = f
        return f
    }

    func rect(_ region: Region, _ f: EditorShellFrames) -> CanvasRect {
        switch region {
        case .left: return f.left
        case .previewTopBar: return f.previewTopBar
        case .player: return f.player
        case .right: return f.right
        case .timeline: return f.timeline
        }
    }

    // MARK: Draw

    func draw(_ c: CanvasContext, size: CanvasSize) {
        if size != self.size { self.size = size }
        let f = relayout()
        // The shell is black; it shows only through the seams between the panels.
        c.fillRect(CanvasRect(x: 0, y: 0, width: size.width, height: size.height), PanelTheme.studioBg)
        let fullscreen = isFullscreen()
        if !fullscreen {
            for region in Region.allCases {
                let r = rect(region, f)
                if r.width > 0, r.height > 0 { c.fillRect(r, PanelTheme.panelBg) }
            }
            ShellStatusLine.draw(c, f.statusLine, hint: statusHint)
        } else {
            c.fillRect(f.preview, PanelTheme.neutral950)
        }
        for region in Region.allCases {
            let r = rect(region, f)
            guard r.width > 0, r.height > 0, let pane = panes[region] else { continue }
            let local = CanvasSize(r.width, r.height)
            if local != pane.lastSize { pane.lastSize = local; pane.input?.resized(local) }
            c.save()
            c.translate(r.x, r.y)
            c.clip(CanvasRect(x: 0, y: 0, width: r.width, height: r.height))
            pane.paint(c, local)
            c.restore()
        }
        if !fullscreen { drawHandles(c, f) }
        crossPaneDrag?.drawDrag(c)
    }

    /// At rest the seams are the shell. The one under the pointer lights (`seamHover`) and the one being dragged
    /// is the accent; the timeline divider does the same across the window.
    private func drawHandles(_ c: CanvasContext, _ f: EditorShellFrames) {
        func paint(_ r: CanvasRect?, dragging: Bool, hovered: Bool) {
            guard let r else { return }
            if dragging { c.fillRect(r, PanelTheme.accent) } else if hovered { c.fillRect(r, PanelTheme.seamHover) }
        }
        paint(f.leftSeam, dragging: drag == .leftSeam, hovered: hoveredHandle == .leftSeam)
        paint(f.rightSeam, dragging: drag == .rightSeam, hovered: hoveredHandle == .rightSeam)
        func isDivider(_ d: Drag?) -> Bool { if case .timelineDivider? = d { return true }; return false }
        paint(f.timelineDivider, dragging: isDivider(drag), hovered: isDivider(hoveredHandle))
    }

    // MARK: Status line

    static let seamHint = "Drag to resize the panels"
    static let dividerHint = "Drag to resize the timeline"
    /// Hints for a region whose pane has nothing to say about the point under the pointer.
    static let regionHints: [Region: String] = [
        .timeline: "Space play / pause · S split at the playhead · I / O set the in and out points",
        .player: "Drag to move the selected element · ⇧ drag for a uniform resize · F fullscreen",
    ]

    /// What the status line says: the seam or divider under the pointer (or being dragged), else the hovered pane's
    /// own hint, else its region's.
    var statusHint: String? {
        if let h = drag ?? hoveredHandle {
            if case .timelineDivider = h { return Self.dividerHint }
            return Self.seamHint
        }
        guard let region = hovered else { return nil }
        return panes[region]?.hint() ?? Self.regionHints[region]
    }

    // MARK: Hit testing

    func region(at x: Double, _ y: Double) -> Region? {
        guard let f = frames ?? Optional(relayout()) else { return nil }
        let p = CanvasPoint(x, y)
        for region in [Region.previewTopBar, .player, .timeline, .left, .right] where rect(region, f).contains(p) { return region }
        return nil
    }

    func handle(at x: Double, _ y: Double) -> Drag? {
        guard let f = frames, !isFullscreen() else { return nil }
        let p = CanvasPoint(x, y)
        if f.timelineDividerHit.contains(p) { return .timelineDivider(startY: 0, startH: 0) }
        if !f.leftRail, f.leftSeamHit?.contains(p) == true { return .leftSeam }
        if !f.rightRail, f.rightSeamHit?.contains(p) == true { return .rightSeam }
        return nil
    }

    /// The cursor a host should show at a point: column resize over a seam, row resize over the divider.
    enum Cursor { case arrow, columnResize, rowResize }
    func cursor(at x: Double, _ y: Double) -> Cursor {
        if let d = drag ?? handle(at: x, y) { if case .timelineDivider = d { return .rowResize }; return .columnResize }
        return .arrow
    }

    /// The region under a window point and the point in that region's coordinates (file drops from the desktop).
    func hit(_ x: Double, _ y: Double) -> (region: Region, local: CanvasPoint)? {
        guard let r = region(at: x, y) else { return nil }
        let (lx, ly) = local(r, x, y)
        return (r, CanvasPoint(lx, ly))
    }

    private func local(_ region: Region, _ x: Double, _ y: Double) -> (Double, Double) {
        guard let f = frames else { return (x, y) }
        let r = rect(region, f)
        return (x - r.x, y - r.y)
    }

    // MARK: CanvasInput (window coordinates in, region-local coordinates out)

    func pointerDown(x: Double, y: Double, shift: Bool) { pointerDown(x: x, y: y, button: PointerButton.primary, modifiers: shift ? .shift : []) }
    func pointerMove(x: Double, y: Double) { pointerMove(x: x, y: y, modifiers: []) }
    func pointerUp(x: Double, y: Double) { pointerUp(x: x, y: y, button: PointerButton.primary) }

    func pointerDown(x: Double, y: Double, button: Int, modifiers: PointerModifiers) {
        // Seams and the divider take the primary button only; other buttons go to the pane under the pointer.
        if button == PointerButton.primary, let h = handle(at: x, y) {
            switch h {
            case .leftSeam: layout.beginResize(.left, x: x); drag = .leftSeam
            case .rightSeam: layout.beginResize(.right, x: x); drag = .rightSeam
            case .timelineDivider:
                let container = EditorShellFrames.timelineContainerHeight(size.height)
                drag = .timelineDivider(startY: y, startH: PanelFit.fitTimelineHeight(container, timelineHeight))
            }
            needsDisplay(); return
        }
        guard let region = region(at: x, y) else { return }
        captured = region; focused = region
        let (lx, ly) = local(region, x, y)
        panes[region]?.input?.pointerDown(x: lx, y: ly, button: button, modifiers: modifiers)
    }

    func pointerMove(x: Double, y: Double, modifiers: PointerModifiers) {
        if let d = drag {
            switch d {
            case .leftSeam, .rightSeam: layout.moveResize(x: x)
            case .timelineDivider:
                // TimelineResizeDivider: height = container height - pointer y, through fitTimelineHeight.
                let container = EditorShellFrames.timelineContainerHeight(size.height)
                timelineHeight = PanelFit.fitTimelineHeight(container, container - y)
            }
            needsDisplay(); return
        }
        let h = handle(at: x, y)
        if h != hoveredHandle { hoveredHandle = h; needsDisplay() }
        if let region = captured {
            let (lx, ly) = local(region, x, y)
            panes[region]?.input?.pointerMove(x: lx, y: ly, modifiers: modifiers)
            if let d = crossPaneDrag, d.isDragging(from: region) {
                let target = self.region(at: x, y)
                let (tx, ty) = target.map { local($0, x, y) } ?? (x, y)
                d.dragMoved(over: target, local: CanvasPoint(tx, ty), window: CanvasPoint(x, y))
                needsDisplay()
            }
            return
        }
        let region = h == nil ? region(at: x, y) : nil
        if region != hovered { needsDisplay() }   // the status line follows the pointer
        if let prev = hovered, prev != region {
            // Leaving a pane: one move outside its bounds clears its hover state.
            let (lx, ly) = local(prev, x, y)
            panes[prev]?.input?.pointerMove(x: lx, y: ly, modifiers: modifiers)
        }
        hovered = region
        if let region {
            let (lx, ly) = local(region, x, y)
            panes[region]?.input?.pointerMove(x: lx, y: ly, modifiers: modifiers)
        }
    }

    func pointerUp(x: Double, y: Double, button: Int) {
        if button == PointerButton.primary, let d = drag {
            drag = nil
            switch d {
            case .leftSeam, .rightSeam: layout.endResize()
            case .timelineDivider: onTimelineHeightCommit(timelineHeight)
            }
            needsDisplay(); return
        }
        guard let region = captured else { return }
        captured = nil
        let dragging = crossPaneDrag?.isDragging(from: region) == true
        let (lx, ly) = local(region, x, y)
        panes[region]?.input?.pointerUp(x: lx, y: ly, button: button)
        if dragging, let d = crossPaneDrag {
            let target = self.region(at: x, y)
            let (tx, ty) = target.map { local($0, x, y) } ?? (x, y)
            d.dragEnded(over: target, local: CanvasPoint(tx, ty))
            needsDisplay()
        }
    }

    func secondaryClick(x: Double, y: Double) {
        guard let region = region(at: x, y) else { return }
        focused = region
        let (lx, ly) = local(region, x, y)
        panes[region]?.input?.secondaryClick(x: lx, y: ly)
    }

    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool) {
        scroll(dx: dx, dy: dy, x: x, ctrl: ctrl, shift: shift, precise: false)
    }
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool, precise: Bool) {
        // Wheel goes to the pane under the pointer; `y` is tracked from the last move.
        guard let region = hovered ?? captured else { return }
        let (lx, _) = local(region, x, 0)
        panes[region]?.input?.scroll(dx: dx, dy: dy, x: lx, ctrl: ctrl, shift: shift, precise: precise)
    }

    func keyDown(_ k: EditorKey) -> Bool {
        if let input = panes[focused]?.input, input.keyDown(k) { return true }
        // Global shortcuts work from any focus: fall back to the timeline (which falls through to playback).
        if focused != .timeline, let t = panes[.timeline]?.input { return t.keyDown(k) }
        return false
    }

    func keyUp(_ k: EditorKey) { (panes[focused]?.input ?? panes[.timeline]?.input)?.keyUp(k) }

    func resized(_ size: CanvasSize) { self.size = size; _ = relayout() }
}

extension EditorSession {
    /// Builds the window router for this session (both shells call this): the player and timeline panes are the
    /// editor's own; side panels, the preview top bar and the timeline toolbar plug into `shell.panes` as they land.
    /// Panel widths/collapse and the timeline height persist in `<userData>/panel-layout.json`.
    func installShell(userData: String, afterKey: @escaping () -> Void) -> EditorShellRouter {
        let store = FilePanelPreferencesStore(url: URL(fileURLWithPath: userData).appendingPathComponent("panel-layout.json"))
        let layout = PanelLayoutState(store: store)
        let router = EditorShellRouter(layout: layout,
                                       timelineHeight: layout.prefs.timelineHeight ?? EditorShellFrames.defaultTimelineHeight)
        router.onTimelineHeightCommit = { [weak layout] h in layout?.update { $0.timelineHeight = h.rounded() } }
        router.isFullscreen = { [weak self] in self?.player.view.isFullscreen ?? false }
        installPreview(userData: userData)
        // Track height, zoom and the magnet persist with the UI preferences.
        let region = TimelineRegion(controller: timeline, preferences: FileTimelineUIPreferencesStore(
            url: URL(fileURLWithPath: userData).appendingPathComponent("timeline-ui.json")))
        timelineRegion = region
        region.media = makeTimelineMediaFeeder()
        installEditHistory(userData: userData)
        ensurePlayTimer = afterKey
        let ti = TimelineInput(self, region: region, afterKey: afterKey), pi = PlayerInput(self, afterKey: afterKey)
        shellInputs = [ti, pi]
        router.panes[.player] = ShellPane(input: pi) { [weak self] c, size in self?.drawPlayer(c, size: size) }
        router.panes[.timeline] = ShellPane(input: ti) { c, size in region.draw(c, size: size) }
        router.needsDisplay = { [weak self] in self?.redraw() }
        installPanels(router, userData: userData)
        installTimelineHooks()
        shell = router
        return router
    }
}
