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

/// The Keyframe Easing panel (docs/KEYFRAME_EASING.md): the selected property's value or speed graph, the focused
/// segment's timing curve with a motion preview, presets (with the project's own), influence and velocity numbers,
/// and copy / paste of an ease. It edits the keys `KeyframeEasingTarget` resolves from the host's clip, timeline key
/// selection and playhead; every edit is one undo step over all of them.
///
/// A self-contained view, so a docking model can host it (`dock`); until one exists the right panel shows it as its
/// "Easing" tab.
public final class KeyframeEasingPanel {
    /// What a docking host needs to place the panel.
    public struct Dock: Equatable, Sendable {
        public enum Edge: String, Sendable { case bottom, right, left }
        public let id: String, title: String, defaultEdge: Edge, minimumSize: CanvasSize
    }
    public static let dock = Dock(id: "keyframe-easing", title: "Keyframe Easing", defaultEdge: .bottom, minimumSize: CanvasSize(360, 300))

    public enum Hit: Equatable {
        case property, graphMode(KeyframeEasingState.Graph), zoomIn, zoomOut, fit, copy, paste
        case graph, speedHandle(KeyframeEasing.Side), curve, curveHandle(Int), preview
        case preset(String), customPreset(String), deletePreset(String), savePreset, field(String), disabled(String)
    }

    // Host inputs, set before each draw (the inspector's selection, the timeline's keys, the playhead in seconds).
    public var editor: TimelineEditor?
    public var clipId: String?
    public var selectedKeyframes: Set<TimelineKeyframeRef> = []
    public var time = 0.0
    /// After every document edit the panel made (the host saves and redraws).
    public var onEdited: (() -> Void)?
    /// Asks the host to call `tick` until it returns false (the motion preview's run).
    public var onAnimate: (() -> Void)?

    public let state = KeyframeEasingState()
    public let dropdown = PanelDropdown()
    public internal(set) var hits = HitMap<Hit>()
    public var hovered: Hit?
    var field: PanelTextField?
    var drag: Drag?
    /// The motion preview's run, 0…1, nil at rest.
    var previewPhase: Double?
    var bounds = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    /// Last draw's graph plot and the time range it shows (clip frames), for pointer mapping.
    var graphBox: GraphBox?
    /// Last draw's segment-curve plot and its value range, for the handle drags.
    var curveBox: (plot: CanvasRect, range: ClosedRange<Double>)?
    /// Value ranges captured when a handle drag starts, so the pointer maps through one scale until release
    /// (a range that followed the handle would make it run away from the pointer).
    var frozenSpeedRange: ClosedRange<Double>?
    var frozenCurveRange: ClosedRange<Double>?
    /// The tab layout scrolls when its column is taller than the panel (`contentHeight` from the last draw).
    var scrollY = 0.0
    var contentHeight = 0.0

    enum Drag: Equatable {
        case curveHandle(Int, CubicBezierControlPoints)
        case speedHandle(KeyframeEasing.Side, influence: Double, velocity: Double)
        case pan(startX: Double, startPan: Double)
    }

    struct GraphBox: Equatable {
        var plot: CanvasRect
        var frames: ClosedRange<Double>
        var values: ClosedRange<Double>
    }

    public init() {}

    /// The keys the panel edits now; nil when the clip has no easable keys.
    public var target: KeyframeEasingTarget? {
        guard let editor else { return nil }
        var selected = selectedKeyframes
        if let chosen = state.chosenProperty, state.pinnedSelection == selectedKeyframes, !selected.contains(where: { $0.parameterId == chosen }) {
            selected = []   // the user picked another property for this selection: edit its key at the playhead
        }
        return KeyframeEasingTarget.resolve(editor, clipId: clipId, selected: selected, time: time, chosen: state.chosenProperty)
    }

    /// Wide enough for the graph beside the controls (docked under the timeline).
    static let wideLayout = 640.0
    static let pad = 12.0, rowH = 24.0, controlsW = 300.0

    // MARK: Draw

    public func draw(_ c: CanvasContext, in r: CanvasRect) {
        bounds = r
        hits.reset()
        graphBox = nil
        c.fillRect(r, PanelTheme.panelBg)
        c.withState {
            c.clip(r)
            guard let editor, let t = target else { return drawEmpty(c, r) }
            if r.width >= Self.wideLayout {
                scrollY = 0
                drawWide(c, r, top: drawHeader(c, r, editor, t), editor, t)
            } else {
                let shifted = CanvasRect(x: r.x, y: r.y - scrollY, width: r.width, height: r.height)
                contentHeight = drawNarrow(c, shifted, top: drawHeader(c, shifted, editor, t), editor, t) + Self.pad - shifted.y
                scrollY = min(scrollY, maxScroll)
            }
        }
        dropdown.draw(c)
    }

    /// Docked under the timeline: the graph, then the curve and presets, then the numbers, side by side.
    func drawWide(_ c: CanvasContext, _ r: CanvasRect, top: Double, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) {
        let colW = min(Self.controlsW, (r.width - 2 * Self.pad) * 0.3), h = r.maxY - top
        let graph = CanvasRect(x: r.x + Self.pad, y: top, width: r.width - 2 * colW - Self.pad, height: max(0, h - Self.pad))
        drawGraph(c, graph, editor, t)
        let a = CanvasRect(x: graph.maxX, y: top - 4, width: colW, height: h)
        _ = drawCurveAndPresets(c, a, editor, t)
        _ = drawNumbersAndNotes(c, CanvasRect(x: a.maxX, y: top, width: colW, height: h), editor, t)
    }

    /// The right panel's tab: everything in one column under a graph that takes about a third of the height.
    /// Returns the bottom of the column.
    func drawNarrow(_ c: CanvasContext, _ r: CanvasRect, top: Double, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> Double {
        let gh = min(320, max(120, (r.maxY - top) * 0.36))
        drawGraph(c, CanvasRect(x: r.x + Self.pad, y: top, width: r.width - 2 * Self.pad, height: gh), editor, t)
        let y = drawCurveAndPresets(c, CanvasRect(x: r.x, y: top + gh + 8, width: r.width, height: r.maxY - top - gh - 8), editor, t)
        return drawNumbersAndNotes(c, CanvasRect(x: r.x, y: y, width: r.width, height: max(0, r.maxY - y)), editor, t)
    }

    var maxScroll: Double { max(0, contentHeight - bounds.height) }

    func drawEmpty(_ c: CanvasContext, _ r: CanvasRect) {
        let lines = ["No keyframes to ease", "Select a clip with keyframes, or keys on the timeline."]
        for (i, s) in lines.enumerated() {
            PanelDraw.text(c, s, in: CanvasRect(x: r.x + Self.pad, y: r.midY - 18 + Double(i) * 18, width: r.width - 2 * Self.pad, height: 16),
                           font: PanelTheme.font(i == 0 ? 11 : 10, i == 0 ? .medium : .regular), color: i == 0 ? PanelTheme.text2 : PanelTheme.text4,
                           align: .center)
        }
    }

    /// Property picker, key count, the graph switch, zoom and copy / paste: one row when wide, two in the tab.
    /// Returns the y below it.
    func drawHeader(_ c: CanvasContext, _ r: CanvasRect, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> Double {
        let wide = r.width >= Self.wideLayout, x = r.x + Self.pad, right = r.maxX - Self.pad
        let pick = CanvasRect(x: x, y: r.y + 10, width: min(180, (right - x) * 0.55), height: Self.rowH)
        PanelSelect.draw(c, pick, text: Self.label(t.parameterId), hovered: hovered == .property, disabled: t.properties.count < 2)
        if t.properties.count > 1 { hits.add(pick, .property) }
        let toolsY = wide ? pick.y : pick.maxY + 8
        var bx = wide ? pick.maxX + 12 : x
        for g in KeyframeEasingState.Graph.allCases {
            bx = chip(c, x: bx, y: toolsY, g == .value ? "Value" : "Speed", hit: .graphMode(g), active: state.graph == g) + 4
        }
        bx += 6
        for (label, hit) in [("−", Hit.zoomOut), ("+", .zoomIn), ("Fit", .fit)] { bx = chip(c, x: bx, y: toolsY, label, hit: hit, active: false) + 4 }
        let copyX = drawCopyPaste(c, right: right, y: toolsY, editor, t)
        let count = t.fromSelection ? "\(t.refs.count) key\(t.refs.count == 1 ? "" : "s") selected" : "Key at playhead"
        let countRect = wide ? CanvasRect(x: bx + 8, y: pick.y + 4, width: max(0, copyX - bx - 16), height: 16)
                             : CanvasRect(x: pick.maxX + 8, y: pick.y + 4, width: max(0, right - pick.maxX - 8), height: 16)
        PanelDraw.text(c, count, in: countRect, font: PanelTheme.font(10), color: PanelTheme.text4, align: .right)
        let y = toolsY + Self.rowH + 8
        PanelDraw.hline(c, x0: r.x, x1: r.maxX, y: y - 4, PanelTheme.panelBorder)
        return y + 4
    }

    /// Paste is live only once something was copied; the header lays the key count out up to the returned edge.
    func drawCopyPaste(_ c: CanvasContext, right: Double, y: Double, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> Double {
        let pw = chipWidth(c, "Paste"), cw = chipWidth(c, "Copy")
        chip(c, x: right - pw, y: y, "Paste", hit: .paste, active: false, enabled: state.clipboard != nil)
        chip(c, x: right - pw - 4 - cw, y: y, "Copy", hit: .copy, active: false, enabled: editor.outgoing(t.focused ?? Self.none) != nil)
        return right - pw - 4 - cw
    }

    static let none = TimelineKeyframeRef(clipId: "", parameterId: "", frame: -1)

    func chipWidth(_ c: CanvasContext, _ label: String) -> Double { c.measureText(label, font: PanelTheme.font(10)).width + 16 }

    /// One pill button; returns its right edge. Disabled chips draw dimmed and record a `.disabled` hit (their hint).
    @discardableResult
    func chip(_ c: CanvasContext, x: Double, y: Double, _ label: String, hit: Hit, active: Bool, enabled: Bool = true, disabledKey: String? = nil) -> Double {
        let r = CanvasRect(x: x, y: y, width: chipWidth(c, label), height: Self.rowH)
        let fill = active ? PanelTheme.panelHover : (hovered == hit && enabled ? PanelTheme.panelHover.withAlpha(0.6) : PanelTheme.panelInput)
        c.fillRoundedRect(r, radius: PanelTheme.radius, fill)
        if active { c.strokeRoundedRect(r.insetBy(0.5), radius: PanelTheme.radius, PanelTheme.accent, width: 1) }
        let color = !enabled ? PanelTheme.text5 : (active ? PanelTheme.text0 : PanelTheme.text2)
        PanelDraw.text(c, label, in: CanvasRect(x: r.x, y: r.y + 4, width: r.width, height: 16), font: PanelTheme.font(10), color: color, align: .center)
        if enabled { hits.add(r, hit) } else if let k = disabledKey { hits.add(r, .disabled(k)) }
        return r.maxX
    }

    /// Display names, units (per second) and the factor from stored values to shown ones, per property.
    static let properties: [String: (label: String, unit: String, factor: Double)] = [
        TimelineEditor.positionId: ("Position", "px/s", 1), POSITION_X_PARAMETER_ID: ("Position X", "px/s", 1),
        POSITION_Y_PARAMETER_ID: ("Position Y", "px/s", 1), TimelineEditor.widthId: ("Width", "px/s", 1),
        TimelineEditor.heightId: ("Height", "px/s", 1), TimelineEditor.rotationId: ("Rotation", "°/s", 1),
        TimelineEditor.scaleId: ("Scale", "%/s", 100), TimelineEditor.opacityId: ("Opacity", "%/s", 100),
        NativeTransform3D.zId: ("Depth", "px/s", 1), NativeTransform3D.rotationXId: ("Rotation X", "°/s", 1),
        NativeTransform3D.rotationYId: ("Rotation Y", "°/s", 1), NativeTransform3D.perspectiveId: ("Perspective", "px/s", 1),
        TimelineEditor.volumeId: ("Volume", "gain/s", 1),
    ]

    static func label(_ pid: String) -> String { properties[pid]?.label ?? pid }
    static func unit(_ pid: String) -> (unit: String, factor: Double) { properties[pid].map { ($0.unit, $0.factor) } ?? ("/s", 1) }

    /// What the status line says for the control under the pointer.
    public var hint: String? {
        switch hovered {
        case .disabled("spring")?, .disabled("bounce")?: "Spring and bounce need keyframe engine support (#192)"
        case .disabled("dimensions")?: "One curve times every component of a value today (#193)"
        case .speedHandle?: "Drag: across sets influence, up and down sets speed"
        case .graph?: "Scroll to pan, ⌘-scroll to zoom"
        case .copy?: "Copy this key's ease"
        case .paste?: "Paste the copied ease on every key shown"
        default: nil
        }
    }
}
