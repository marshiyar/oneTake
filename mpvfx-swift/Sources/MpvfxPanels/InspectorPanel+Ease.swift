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
import MpvfxTheme

/// The Transform group's keyframe easing editor: the preset picker (Linear, Ease in,
/// Ease out, Ease in & out, Hold, Custom), and for a custom curve its X1/Y1/X2/Y2 handle fields (X clamped to 0–1, Y to
/// −1–2) and a curve graph whose two handles drag. It edits the keys selected on the timeline (focusedEaseSegment's
/// native targets) when any of the clip's eased channels are selected, else the key at/before the playhead of each
/// eased channel. Every edit is one undo step and re-times both the preview and the export.
extension InspectorPanel {
    /// DEFAULT_CUBIC: where Custom starts from a linear or hold key.
    public static let defaultCubic = CubicBezierControlPoints(x1: 0.33, y1: 0, x2: 0.67, y2: 1)
    public static let cubicYRange: ClosedRange<Double> = -1...2

    /// The keyframe menu's "Edit Easing…": selects the clip, makes `refs` the keys the easing rows edit and opens the
    /// group holding them, scrolled to its easing rows. False when no key has an easing editor (the panel is unchanged).
    @discardableResult
    public func showKeyframeEasing(clipId: String, refs: Set<TimelineKeyframeRef>) -> Bool {
        let keys = refs.filter { $0.clipId == clipId }
        guard let group = keys.sorted(by: { ($0.frame, $0.parameterId) < ($1.frame, $1.parameterId) })
            .lazy.compactMap({ TimelineEditor.keyframeEasingGroup($0.parameterId) }).first else { return false }
        audioGroupId = nil
        selection = [clipId]
        selectedKeyframes = keys
        openGroupId = group
        revealEasingRows = true   // also when the group is already open: its easing rows sit at its end
        return true
    }

    /// Presets in the picker's order; `value` nil is Custom.
    static let easePresets: [(key: String, label: String, value: NativeInterpolation?)] = [
        ("linear", "Linear", .linear),
        ("in", "In", .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 1, y2: 1))),
        ("out", "Out", .cubicBezier(CubicBezierControlPoints(x1: 0, y1: 0, x2: 0.58, y2: 1))),
        ("inout", "In & out", .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 0.58, y2: 1))),
        ("hold", "Hold", .hold),
        ("custom", "Custom", nil),
    ]

    static func easePresetKey(_ v: NativeInterpolation) -> String {
        easePresets.first { $0.value == v }?.key ?? "custom"
    }

    /// Clamp one handle coordinate (normalizeControl), rounded to 0.001 so typed and dragged values stay tidy.
    static func clampCubic(_ p: CubicBezierControlPoints) -> CubicBezierControlPoints {
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        func x(_ v: Double) -> Double { r(max(0, min(1, v))) }
        func y(_ v: Double) -> Double { r(max(cubicYRange.lowerBound, min(cubicYRange.upperBound, v))) }
        var q = p   // keeps any unknown keys the document carried
        q.x1 = x(p.x1); q.y1 = y(p.y1); q.x2 = x(p.x2); q.y2 = y(p.y2)
        return q
    }

    /// The keys the easing rows edit: the timeline's selected keys on this clip's eased channels, else the playhead's.
    func easeTargets(_ editor: TimelineEditor, _ s: Selected, channels: [String]) -> (refs: [TimelineKeyframeRef], selected: Bool) {
        let picked = selectedKeyframes.filter { $0.clipId == s.id && channels.contains($0.parameterId) && editor.outgoing($0) != nil }
            .sorted { ($0.frame, $0.parameterId) < ($1.frame, $1.parameterId) }
        if !picked.isEmpty { return (picked, true) }
        return (editor.keyframesAtOrBefore(clipId: s.id, parameterIds: channels, time: time), false)
    }

    func easingRows(_ editor: TimelineEditor, _ s: Selected, channels: [String]) -> [InspectorRow] {
        let (refs, selected) = easeTargets(editor, s, channels: channels)
        guard let first = refs.first, let cur = editor.outgoing(first) else { return [] }
        let trailing = selected ? "\(refs.count) selected" : (refs.count > 1 ? "\(refs.count) channels" : nil)
        var rows: [InspectorRow] = [.init(.spacer(PanelGrid.unit)), .init(.heading("Keyframe easing", trailing: trailing))]
        let active = Self.easePresetKey(cur)
        var points = Self.defaultCubic
        if case .cubicBezier(let p) = cur { points = p }
        let commit: (NativeInterpolation) -> Void = { [weak self] v in self?.edited(editor.setOutgoing(refs, v), label: "Edit keyframe easing") }
        let opts = Self.easePresets.map { (key: $0.key, label: $0.label, active: $0.key == active) }
        rows.append(.init(.segmented(.init(key: "easing", label: "Ease", options: opts, select: { k in
            guard let e = Self.easePresets.first(where: { $0.key == k }) else { return }
            commit(e.value ?? .cubicBezier(points))   // Custom keeps the current curve (`presets[next] ?? points`)
        }))))
        guard active == "custom" else { return rows }
        // Curve handles: the graph, then the four fields (`grid-cols-4`) and the range hint.
        rows.append(.init(.custom(easeGraphRow(points, commit: { commit(.cubicBezier($0)) }))))
        let fields: [(String, String, WritableKeyPath<CubicBezierControlPoints, Double>)] =
            [("cubicX1", "X1", \.x1), ("cubicY1", "Y1", \.y1), ("cubicX2", "X2", \.x2), ("cubicY2", "Y2", \.y2)]
        rows.append(.init(.quad(fields.map { key, label, path in
            numberRow(key: key, label: label, value: points[keyPath: path], decimals: 2, tier: .explicitCustom, step: 0.01,
                      apply: { v in
                          var p = points; p[keyPath: path] = v
                          return editor.setOutgoing(refs, .cubicBezier(Self.clampCubic(p)))
                      })
        })))
        rows.append(.init(.note("X handles: 0–1. Y handles: −1–2.")))
        return rows
    }

    /// The curve graph: time across, value up, over 0…1 widened to any handle outside it (fixed while a drag runs).
    /// Parts: 0 the plot, 1 the first handle, 2 the second.
    func easeGraphRow(_ points: CubicBezierControlPoints, commit: @escaping (CubicBezierControlPoints) -> Void) -> InspectorCustomRow {
        let id = "ease:curve"
        return InspectorCustomRow(id: id, height: 140, draw: { [weak self] c, r, panel in
            guard let self else { return }
            let p = self.easeDrag?.points ?? points
            let range = self.easeDrag?.range ?? (min(0, p.y1, p.y2)...max(1, p.y1, p.y2))
            let size = min(r.width, 200.0)
            let frame = CanvasRect(x: r.x + (r.width - size) / 2, y: r.y, width: size, height: r.height)
            let box = CanvasRect(x: frame.x + 10, y: frame.y + 10, width: frame.width - 20, height: frame.height - 20)
            self.easeGraphBox = EaseGraphBox(box: box, range: range)
            func v(_ x: Double, _ y: Double) -> CanvasPoint {
                CanvasPoint(box.x + x * box.width, box.maxY - (y - range.lowerBound) / (range.upperBound - range.lowerBound) * box.height)
            }
            c.fillRoundedRect(frame, radius: 4, PanelTheme.stageScrim.withAlpha(Theme.mode == .light ? 0.05 : 0.2))
            c.strokeRoundedRect(frame.insetBy(0.5), radius: 3.5, PanelTheme.panelBorderInput, width: 1)
            for y in [0.0, 1.0] {   // the start and end values
                var l = CanvasPath(); l.move(to: v(0, y)); l.line(to: v(1, y))
                c.stroke(l, PanelTheme.white.withAlpha(0.12), StrokeStyle(width: 0.5))
            }
            var diag = CanvasPath(); diag.move(to: v(0, 0)); diag.line(to: v(1, 1))   // linear, for reference
            c.stroke(diag, PanelTheme.white.withAlpha(0.08), StrokeStyle(width: 0.5))
            let h1 = v(p.x1, p.y1), h2 = v(p.x2, p.y2)
            for (a, b) in [(v(0, 0), h1), (v(1, 1), h2)] {
                var arm = CanvasPath(); arm.move(to: a); arm.line(to: b)
                c.stroke(arm, PanelTheme.text4, StrokeStyle(width: 1))
            }
            var curve = CanvasPath(); curve.move(to: v(0, 0)); curve.curve(to: v(1, 1), c1: h1, c2: h2)
            c.stroke(curve, PanelTheme.accent, StrokeStyle(width: 1.5))
            for (i, h) in [h1, h2].enumerated() {
                let on = self.easeDrag?.handle == i + 1 || panel.hovered == .custom(id, i + 1)
                let rad = on ? 4.5 : 3.5
                let dot = CanvasPath.roundedRect(CanvasRect(x: h.x - rad, y: h.y - rad, width: 2 * rad, height: 2 * rad), radius: rad)
                c.fill(dot, on ? PanelTheme.text0 : PanelTheme.accent)
                c.stroke(dot, PanelTheme.panelBg, StrokeStyle(width: 1))
            }
            panel.addHit(frame, .custom(id, 0))
            for (i, h) in [h1, h2].enumerated() { panel.addHit(CanvasRect(x: h.x - 7, y: h.y - 7, width: 14, height: 14), .custom(id, i + 1)) }
        }, pointer: { [weak self] part, pt, phase in
            guard let self, let g = self.easeGraphBox else { return }
            if phase == 0 {
                self.easeDrag = part == 0 ? nil : EaseDrag(handle: part, points: points, range: g.range)
                return
            }
            guard var d = self.easeDrag else { return }
            let x = (pt.x - g.box.x) / max(1, g.box.width)
            let y = g.range.upperBound - (pt.y - g.box.y) / max(1, g.box.height) * (g.range.upperBound - g.range.lowerBound)
            var p = d.points
            if d.handle == 1 { p.x1 = x; p.y1 = y } else { p.x2 = x; p.y2 = y }
            d.points = Self.clampCubic(p)
            self.easeDrag = d
            if phase == 2 {
                self.easeDrag = nil
                if d.points != points { commit(d.points) }
            }
        })
    }
}

/// The ease graph's plot area and value range from the last draw.
public struct EaseGraphBox: Equatable {
    public var box: CanvasRect
    public var range: ClosedRange<Double>
}

/// An ease-graph handle drag in flight: the handle (1 or 2), its live curve and the value range fixed at the press.
public struct EaseDrag: Equatable {
    public var handle: Int
    public var points: CubicBezierControlPoints
    public var range: ClosedRange<Double>
}
