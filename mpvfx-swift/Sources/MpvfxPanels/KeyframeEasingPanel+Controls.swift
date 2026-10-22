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

/// The panel's controls: the focused segment's timing curve and motion preview, presets (built in, disabled engine
/// ones, the project's own), influence / speed and X1…Y2 numbers, and the notes.
extension KeyframeEasingPanel {
    /// Built-in presets in order (the inspector's and the keyframe menu's curves), then the ones the engine lacks.
    static let presets: [(key: String, label: String, value: NativeInterpolation)] =
        InspectorPanel.easePresets.compactMap { p in p.value.map { (p.key, p.label, $0) } }
    static let enginePending = [("spring", "Spring"), ("bounce", "Bounce")]

    /// The segment curve with the motion preview, then the presets; returns the y below them.
    func drawCurveAndPresets(_ c: CanvasContext, _ r: CanvasRect, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> Double {
        let current = t.focused.flatMap { editor.outgoing($0) }
        let y = drawCurveRow(c, CanvasRect(x: r.x + Self.pad, y: r.y + 4, width: r.width - 2 * Self.pad, height: 108), current) + 10
        return drawPresets(c, r, y: y, editor, current) + 10
    }

    /// Influence and speed, X1…Y2, and the notes; returns the y below them.
    func drawNumbersAndNotes(_ c: CanvasContext, _ r: CanvasRect, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> Double {
        let current = t.focused.flatMap { editor.outgoing($0) }
        let y = drawNumbers(c, r, y: r.y, editor, t, current) + 10
        return drawNotes(c, r, y: y, editor, t, current)
    }

    // MARK: Curve and preview

    func curvePoints(_ v: NativeInterpolation?) -> CubicBezierControlPoints? {
        if case .curveHandle(_, let p)? = drag { return p }
        switch v {
        case .cubicBezier(let p)?: return p
        case .linear?: return CubicBezierControlPoints(x1: 1.0 / 3, y1: 1.0 / 3, x2: 2.0 / 3, y2: 2.0 / 3)
        default: return nil
        }
    }

    func drawCurveRow(_ c: CanvasContext, _ r: CanvasRect, _ v: NativeInterpolation?) -> Double {
        let box = CanvasRect(x: r.x, y: r.y, width: r.height, height: r.height)
        c.fillRoundedRect(box, radius: PanelTheme.radius, PanelTheme.panelBgInset)
        c.strokeRoundedRect(box.insetBy(0.5), radius: PanelTheme.radius, PanelTheme.panelBorderInput, width: 1)
        hits.add(box, .curve)
        let plot = box.insetBy(14)
        let ease = drag.flatMap { d -> NativeInterpolation? in if case .curveHandle(_, let p) = d { return .cubicBezier(p) }; return nil } ?? v ?? .linear
        let lo = min(0, curvePoints(v).map { min($0.y1, $0.y2) } ?? 0), hi = max(1, curvePoints(v).map { max($0.y1, $0.y2) } ?? 1)
        let range = frozenCurveRange ?? lo...hi
        func pt(_ x: Double, _ y: Double) -> CanvasPoint {
            CanvasPoint(plot.x + x * plot.width, plot.maxY - (y - range.lowerBound) / (range.upperBound - range.lowerBound) * plot.height)
        }
        var line = CanvasPath()
        for i in 0...48 { let x = Double(i) / 48; let p = pt(x, KeyframeEase.progress(ease, at: x)); if i == 0 { line.move(to: p) } else { line.line(to: p) } }
        c.stroke(line, PanelTheme.accent, StrokeStyle(width: 1.5))
        if let p = curvePoints(v) {
            for (i, (a, h)) in [(pt(0, 0), pt(p.x1, p.y1)), (pt(1, 1), pt(p.x2, p.y2))].enumerated() {
                var arm = CanvasPath(); arm.move(to: a); arm.line(to: h)
                c.stroke(arm, PanelTheme.text4, StrokeStyle(width: 1))
                let dot = CanvasPath.roundedRect(CanvasRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7), radius: 3.5)
                c.fill(dot, hovered == .curveHandle(i + 1) ? PanelTheme.text0 : PanelTheme.accent)
                hits.add(CanvasRect(x: h.x - 7, y: h.y - 7, width: 14, height: 14), .curveHandle(i + 1))
            }
        }
        curveBox = (plot, range)
        drawPreview(c, CanvasRect(x: box.maxX + 10, y: r.y, width: max(0, r.maxX - box.maxX - 10), height: r.height), ease)
        return r.maxY
    }

    /// The motion preview: the eased dot (accent) over a linear reference (dim), at the run's phase; at rest, ten
    /// ghost positions at equal times, so the spacing shows the ease.
    func drawPreview(_ c: CanvasContext, _ r: CanvasRect, _ ease: NativeInterpolation) {
        guard r.width > 40 else { return }
        hits.add(r, .preview)
        PanelDraw.text(c, previewPhase == nil ? "Motion · click to play" : "Motion", in: CanvasRect(x: r.x, y: r.y, width: r.width, height: 14),
                       font: PanelTheme.font(9), color: PanelTheme.text4)
        let x0 = r.x + 6, x1 = r.maxX - 6
        for (row, timing) in [(0, ease), (1, NativeInterpolation.linear)].map({ ($0.0, $0.1) }) {
            let y = r.y + 40 + Double(row) * 34
            PanelDraw.hline(c, x0: x0, x1: x1, y: y, PanelTheme.panelBorder)
            let phases = previewPhase.map { [$0] } ?? (0...9).map { Double($0) / 9 }
            for t in phases {
                let x = x0 + (x1 - x0) * KeyframeEase.progress(timing, at: t)
                let rad = previewPhase == nil ? 3.0 : 5.0
                let color = row == 0 ? PanelTheme.accent : PanelTheme.text5
                c.fill(.roundedRect(CanvasRect(x: x - rad, y: y - rad, width: 2 * rad, height: 2 * rad), radius: rad), color.withAlpha(previewPhase == nil ? 0.75 : 1))
            }
        }
        PanelDraw.text(c, "linear", in: CanvasRect(x: x0, y: r.y + 80, width: 60, height: 12), font: PanelTheme.font(9), color: PanelTheme.text5)
    }

    // MARK: Presets

    func drawPresets(_ c: CanvasContext, _ r: CanvasRect, y top: Double, _ editor: TimelineEditor, _ current: NativeInterpolation?) -> Double {
        var x = r.x + Self.pad, y = top
        let maxX = r.maxX - Self.pad
        func place(_ label: String, _ hit: Hit, active: Bool = false, enabled: Bool = true, disabledKey: String? = nil) {
            if x + chipWidth(c, label) > maxX, x > r.x + Self.pad { x = r.x + Self.pad; y += Self.rowH + 4 }
            x = chip(c, x: x, y: y, label, hit: hit, active: active, enabled: enabled, disabledKey: disabledKey) + 4
        }
        for p in Self.presets { place(p.label, .preset(p.key), active: current == p.value) }
        for (key, label) in Self.enginePending { place(label, .disabled(key), enabled: false, disabledKey: key) }
        for p in editor.easingPresets {   // the trailing × deletes the preset
            place("\(p.name)  ×", .customPreset(p.id), active: current == p.outgoing)
            hits.add(CanvasRect(x: x - 4 - 18, y: y, width: 18, height: Self.rowH), .deletePreset(p.id))
        }
        if field?.key == "presetName" {   // wraps like a chip, so the field is never squeezed off the row
            if x + 140 > maxX, x > r.x + Self.pad { x = r.x + Self.pad; y += Self.rowH + 4 }
            drawField(c, CanvasRect(x: x, y: y, width: min(140, maxX - x), height: Self.rowH), key: "presetName", text: "")
            x += 144
        } else {
            place("+ Save", .savePreset, enabled: current != nil)
        }
        return y + Self.rowH
    }

    // MARK: Numbers

    func drawNumbers(_ c: CanvasContext, _ r: CanvasRect, y top: Double, _ editor: TimelineEditor, _ t: KeyframeEasingTarget,
                     _ current: NativeInterpolation?) -> Double {
        let x = r.x + Self.pad, w = r.width - 2 * Self.pad, gap = 8.0, colW = (w - gap) / 2
        guard let f = t.focused, let sides = KeyframeEasing.sides(editor, f) else {
            let why = current == .hold ? "A hold jumps at the next key: it has no handles." : "The last key has no segment to ease."
            PanelDraw.text(c, why, in: CanvasRect(x: x, y: top, width: w, height: 16), font: PanelTheme.font(10), color: PanelTheme.text4)
            return top + 16
        }
        let u = Self.unit(t.parameterId)
        let cells: [(String, String, String)] = [
            ("outInfluence", "Out influence", "\(PanelFormat.number(sides.outInfluence * 100, decimals: 1)) %"),
            ("outVelocity", "Out speed", "\(PanelFormat.number(sides.outVelocity * u.factor, decimals: 1)) \(u.unit)"),
            ("inInfluence", "In influence", "\(PanelFormat.number(sides.inInfluence * 100, decimals: 1)) %"),
            ("inVelocity", "In speed", "\(PanelFormat.number(sides.inVelocity * u.factor, decimals: 1)) \(u.unit)"),
        ]
        var y = top
        for (i, cell) in cells.enumerated() {
            let cx = x + Double(i % 2) * (colW + gap)
            if i == 2 { y += 44 }
            PanelDraw.text(c, cell.1, in: CanvasRect(x: cx, y: y, width: colW, height: 14), font: PanelTheme.font(9), color: PanelTheme.text4)
            drawField(c, CanvasRect(x: cx, y: y + 16, width: colW, height: Self.rowH), key: cell.0, text: cell.2)
        }
        y += 44
        return drawCubicFields(c, x: x, y: y, w: w, current)
    }

    func drawCubicFields(_ c: CanvasContext, x: Double, y: Double, w: Double, _ current: NativeInterpolation?) -> Double {
        guard case .cubicBezier(let p)? = current else { return y }
        let gap = 6.0, cw = (w - 3 * gap) / 4
        for (i, (key, label, v)) in [("x1", "X1", p.x1), ("y1", "Y1", p.y1), ("x2", "X2", p.x2), ("y2", "Y2", p.y2)].enumerated() {
            let cx = x + Double(i) * (cw + gap)
            PanelDraw.text(c, label, in: CanvasRect(x: cx, y: y, width: cw, height: 14), font: PanelTheme.font(9), color: PanelTheme.text4)
            drawField(c, CanvasRect(x: cx, y: y + 16, width: cw, height: Self.rowH), key: key, text: PanelFormat.number(v, decimals: 2))
        }
        return y + 16 + Self.rowH
    }

    func drawField(_ c: CanvasContext, _ r: CanvasRect, key: String, text: String) {
        let editing = field?.key == key
        c.fillRoundedRect(r, radius: PanelTheme.radius, hovered == .field(key) || editing ? PanelTheme.panelHover : PanelTheme.panelInput)
        PanelDraw.text(c, editing ? (field?.draft ?? "") : text, in: CanvasRect(x: r.x + 6, y: r.y + 4, width: r.width - 12, height: 16),
                       font: PanelTheme.mono(10), color: editing ? PanelTheme.text0 : PanelTheme.text1)
        if editing { PanelDraw.focusRing(c, r, radius: PanelTheme.radius) }
        hits.add(r, .field(key))
    }

    // MARK: Notes

    func drawNotes(_ c: CanvasContext, _ r: CanvasRect, y top: Double, _ editor: TimelineEditor, _ t: KeyframeEasingTarget,
                   _ current: NativeInterpolation?) -> Double {
        var y = top
        let x = r.x + Self.pad, w = r.width - 2 * Self.pad
        if [TimelineEditor.positionId, POSITION_X_PARAMETER_ID, POSITION_Y_PARAMETER_ID].contains(t.parameterId) {
            chip(c, x: x, y: y, "Separate dimensions", hit: .dimensions, active: t.parameterId != TimelineEditor.positionId, enabled: editor.canTogglePositionDimensions(clipId: t.clipId), disabledKey: "dimensions")
            y += Self.rowH + 6
        }
        if overshootsWhileAutoOrienting(editor, t, current) {
            for line in InspectorPanel.wrap("This curve overshoots: auto-orient can point the wrong way while it runs back.", perLine: max(20, Int(w / 5.2))) {
                PanelDraw.text(c, line, in: CanvasRect(x: x, y: y, width: w, height: 14), font: PanelTheme.font(9), color: PanelTheme.red400)
                y += 14
            }
        }
        return y
    }

    /// The tangent direction the engine reports is wrong while a cubic runs backwards (a known engine limitation),
    /// so an auto-orienting position key with an overshooting curve gets a warning.
    func overshootsWhileAutoOrienting(_ editor: TimelineEditor, _ t: KeyframeEasingTarget, _ v: NativeInterpolation?) -> Bool {
        guard case .cubicBezier(let p)? = v, let f = t.focused, editor.parameterTrack(f)?.autoRotate == true else { return false }
        return [p.y1, p.y2].contains { $0 < 0 || $0 > 1 }
    }
}
