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

/// The editor window: the dock (every panel in its group, with tab bars and splitters; `DockView`) above the 22 pt
/// status line, with the black shell (`studioBg`) showing through the 1 pt seams (docs/DESIGN.md, principle 1).
/// These are the content rects of the built-in panels at the last layout (zero when a panel is closed or behind
/// another tab); the Preview's content is its 36 pt top bar over the player.
struct EditorShellFrames: Equatable {
    var size: CanvasSize
    var dock: CanvasRect
    var left: CanvasRect
    var preview: CanvasRect
    var previewTopBar: CanvasRect
    var player: CanvasRect
    var right: CanvasRect
    var renders: CanvasRect
    var timeline: CanvasRect
    var statusLine: CanvasRect

    static let previewTopBarHeight = 36.0
    static let zero = CanvasRect(x: 0, y: 0, width: 0, height: 0)

    /// The dock's rect: the window less the status line and its seam.
    static func dockRect(_ size: CanvasSize) -> CanvasRect {
        CanvasRect(x: 0, y: 0, width: size.width, height: max(0, size.height - ShellStatusLine.height - PanelTheme.seamWidth))
    }

    static func compute(size: CanvasSize, dock: DockView, fullscreen: Bool) -> EditorShellFrames {
        if fullscreen {
            // The preview drops its chrome in fullscreen and fills the screen; the stage starts at the top.
            let all = CanvasRect(x: 0, y: 0, width: size.width, height: size.height)
            return EditorShellFrames(size: size, dock: all, left: zero, preview: all, previewTopBar: CanvasRect(x: 0, y: 0, width: size.width, height: 0),
                                     player: all, right: zero, renders: zero, timeline: zero, statusLine: zero)
        }
        let d = dockRect(size)
        dock.layout(in: d)
        func content(_ id: DockPanelID) -> CanvasRect { dock.contentRect(of: id) ?? zero }
        let preview = content(DockPanels.preview)
        let barH = min(previewTopBarHeight, preview.height)
        let statusY = d.maxY + PanelTheme.seamWidth
        return EditorShellFrames(
            size: size, dock: d, left: content(DockPanels.media), preview: preview,
            previewTopBar: CanvasRect(x: preview.x, y: preview.y, width: preview.width, height: barH),
            player: CanvasRect(x: preview.x, y: preview.y + barH, width: preview.width, height: max(0, preview.height - barH)),
            right: content(DockPanels.inspector), renders: content(DockPanels.renders), timeline: content(DockPanels.timeline),
            statusLine: CanvasRect(x: 0, y: statusY, width: size.width, height: max(0, size.height - statusY)))
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

/// Lays the window out through the dock and routes drawing and input to the panes. Host-neutral: a shell gives it
/// one full-window canvas (GtkCanvasHost / MacCanvasHost / WindowsCanvasHost) and forwards that canvas's events here,
/// so dragging, swapping, closing and opening panels work the same on Linux, macOS and Windows.
final class EditorShellRouter: CanvasInput, CanvasAccessibilityProvider {
    /// A pane: a dock panel's content, except the Preview, whose content is two panes (top bar, player).
    struct Region: Hashable, Sendable {
        let id: String
        init(_ id: String) { self.id = id }
        static let left = Region(DockPanels.media)
        static let player = Region(DockPanels.preview)
        static let previewTopBar = Region("preview-top-bar")
        static let right = Region(DockPanels.inspector)
        static let renders = Region(DockPanels.renders)
        static let timeline = Region(DockPanels.timeline)
        /// The dock panel the region belongs to.
        var panel: DockPanelID { self == .previewTopBar ? DockPanels.preview : id }
        /// The region a press in `panel`'s content lands in.
        static func of(_ panel: DockPanelID) -> Region { Region(panel) }
    }

    weak var crossPaneDrag: CrossPaneDrag?
    /// The Settings card: while open it is drawn above every pane and takes presses, moves, the wheel and keys
    /// (window coordinates) before any pane.
    var modal: SettingsPanel?
    var modalOpen: Bool { modal?.isOpen == true }

    let layout: PanelLayoutState
    let dock: DockView
    var panes: [Region: ShellPane] = [:]
    /// A group's ⋯ menu (and a secondary click on a tab bar): the panel menu, drawn above the dock.
    let dockMenu = PanelDropdown()
    /// Panels' own commands for their group's ⋯ menu, and who runs them.
    var menuExtras: [DockMenuItem] = []
    var onMenuExtra: (DockPanelID, String) -> Void = { _, _ in }
    var isFullscreen: () -> Bool = { false }
    var needsDisplay: () -> Void = {}
    /// Every workspace's layout as saved, and where it is saved (`restoreDock`).
    var dockFile: DockFile?
    var dockStore: DockLayoutStore?
    private(set) var frames: EditorShellFrames?
    /// Pane that got the press; it receives moves/up until release (pointer capture).
    var captured: Region?
    /// The dock's chrome (a tab, ×, splitter) got the press; it receives moves/up until release.
    var dockCaptured = false
    var hovered: Region?
    var size = CanvasSize(0, 0)

    init(layout: PanelLayoutState, dock: DockView) {
        self.layout = layout
        self.dock = dock
        dock.onMenu = { [weak self] group, anchor in self?.openDockMenu(group, anchor: anchor) }
    }

    /// The pane that takes keys: the dock's focused panel (the last one pressed or cycled to; the timeline at first).
    var focused: Region { dock.focused.map(Region.of) ?? .timeline }

    @discardableResult
    func relayout() -> EditorShellFrames {
        let f = EditorShellFrames.compute(size: size, dock: dock, fullscreen: isFullscreen())
        frames = f
        return f
    }

    func rect(_ region: Region, _ f: EditorShellFrames) -> CanvasRect {
        switch region {
        case .previewTopBar: return f.previewTopBar
        case .player: return f.player
        default: return isFullscreen() ? EditorShellFrames.zero : (dock.contentRect(of: region.id) ?? EditorShellFrames.zero)
        }
    }

    /// Controls from each pane translated from pane-local into window coordinates for the native host.
    var accessibilityControls: [CanvasAccessibilityControl] {
        let f = frames ?? relayout()
        return panes.keys.sorted { $0.id < $1.id }.flatMap { region -> [CanvasAccessibilityControl] in
            guard let provider = panes[region]?.input as? CanvasAccessibilityProvider else { return [] }
            let origin = rect(region, f)
            return provider.accessibilityControls.map { control in
                CanvasAccessibilityControl(label: control.label, value: control.value,
                    frame: CanvasRect(x: control.frame.x + origin.x, y: control.frame.y + origin.y,
                                      width: control.frame.width, height: control.frame.height), press: control.press)
            }
        }
    }

    // MARK: Status line

    static let regionHints: [Region: String] = [
        .timeline: "Space play / pause · S split at the playhead · I / O set the in and out points",
        .player: "Drag to move the selected element · ⇧ drag for a uniform resize · F fullscreen",
    ]

    /// What the status line says: the dock's chrome under the pointer (or its gesture), else the hovered pane's own
    /// hint, else its region's.
    var statusHint: String? {
        if let h = dock.hint { return h }
        guard let region = hovered else { return nil }
        return panes[region]?.hint() ?? Self.regionHints[region]
    }

    /// The cursor a host should show at a point: column resize over a vertical splitter, row resize over a horizontal one.
    enum Cursor { case arrow, columnResize, rowResize }
    func cursor(at x: Double, _ y: Double) -> Cursor {
        guard !isFullscreen(), !modalOpen else { return .arrow }
        switch dock.cursor(at: CanvasPoint(x, y)) {
        case .columnResize?: return .columnResize
        case .rowResize?: return .rowResize
        case .arrow?, nil: return .arrow
        }
    }

    // MARK: Hit testing

    func region(at x: Double, _ y: Double) -> Region? {
        let f = frames ?? relayout()
        let p = CanvasPoint(x, y)
        if isFullscreen() { return f.player.contains(p) ? .player : nil }
        guard let hit = dock.content(at: p) else { return nil }
        if hit.panel == DockPanels.preview { return f.previewTopBar.contains(p) ? .previewTopBar : .player }
        return .of(hit.panel)
    }

    /// The region under a window point and the point in that region's coordinates (file drops from the desktop).
    func hit(_ x: Double, _ y: Double) -> (region: Region, local: CanvasPoint)? {
        guard let r = region(at: x, y) else { return nil }
        let (lx, ly) = local(r, x, y)
        return (r, CanvasPoint(lx, ly))
    }

    func local(_ region: Region, _ x: Double, _ y: Double) -> (Double, Double) {
        guard let f = frames else { return (x, y) }
        let r = rect(region, f)
        return (x - r.x, y - r.y)
    }

    func resized(_ size: CanvasSize) { self.size = size; relayout() }

    // The wheel (CanvasInput); kept here with the router's state it reads.
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool) {
        scroll(dx: dx, dy: dy, x: x, ctrl: ctrl, shift: shift, precise: false)
    }
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool, precise: Bool) {
        if modalOpen { if modal?.scroll(dy: dy) == true { needsDisplay() }; return }
        if dockMenu.isOpen { dockMenu.scrollBy(dy); needsDisplay(); return }
        // Wheel goes to the pane under the pointer; `y` is tracked from the last move.
        guard let region = hovered ?? captured else { return }
        let (lx, _) = local(region, x, 0)
        panes[region]?.input?.scroll(dx: dx, dy: dy, x: lx, ctrl: ctrl, shift: shift, precise: precise)
    }

}
