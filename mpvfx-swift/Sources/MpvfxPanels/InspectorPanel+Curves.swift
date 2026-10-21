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
import MpvfxTheme
import MpvfxShared
import MpvfxTimeline

/// Grade group, Curves section: the curve tabs, the curve graph, the selected point's fields and the footer.
/// Point rules are `CurveEditing`'s; the evaluator is `GradeCurve` (MpvfxShared), the renderer's.
extension InspectorPanel {
    typealias CurveTab = (key: String, label: String, color: ThemePair, hue: Bool, min: Double, max: Double)
    /// Curve tabs; `color` is the tab's line/point token (ThemeTokens.curve*Pair), so light mode draws dark ink.
    static let curveTabs: [CurveTab] = [
        ("master", "Master", ThemeTokens.curveMasterPair, false, 0, 1), ("red", "R", ThemeTokens.curveRedPair, false, 0, 1),
        ("green", "G", ThemeTokens.curveGreenPair, false, 0, 1), ("blue", "B", ThemeTokens.curveBluePair, false, 0, 1),
        ("hueVsHue", "Hue/Hue", ThemeTokens.curveHueHuePair, true, -180, 180),
        ("hueVsSaturation", "Hue/Sat", ThemeTokens.curveHueSatPair, true, -1, 1),
        ("hueVsLuma", "Hue/Luma", ThemeTokens.curveHueLumaPair, true, -1, 1),
    ]

    // MARK: Curves (the curve modes and the curve graph)

    /// Curve tabs (`flex flex-wrap gap-x-2 border-b border-panel-hairline`): `border-b-2 px-0.5 py-1 text-[9px]`,
    /// active text-1 over the accent, the rest text-4 (hover text-2).
    func curveTabsRow() -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:curvetabs", height: 24.5, draw: { [weak self] c, r, panel in
            guard let self else { return }
            var x = r.x
            c.fillRect(CanvasRect(x: r.x, y: r.maxY - 1, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
            for (i, t) in Self.curveTabs.enumerated() {
                let w = c.measureText(t.label, font: PanelTheme.font(9)).width + 4
                let tr = CanvasRect(x: x, y: r.y, width: w, height: 23.5)
                let on = self.grade.curveTab == t.key
                PanelDraw.text(c, t.label, in: CanvasRect(x: tr.x, y: tr.y + 4, width: w, height: 13.5), font: PanelTheme.font(9),
                               color: on ? PanelTheme.text1 : (panel.hovered == .custom("grade:curvetabs", i) ? PanelTheme.text2 : PanelTheme.text4), align: .center)
                if on { c.fillRect(CanvasRect(x: tr.x, y: tr.maxY - 2, width: tr.width, height: 2), PanelTheme.accent) }
                panel.addHit(tr, .custom("grade:curvetabs", i))
                x = tr.maxX + 8
            }
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0, Self.curveTabs.indices.contains(part) else { return }
            self.grade.curveTab = Self.curveTabs[part].key; self.grade.selectedPoint = nil
        })
    }

    /// The open curve tab; a key that names no tab (the field is public) reads as Master.
    var openCurveTab: CurveTab { Self.curveTabs.first { $0.key == grade.curveTab } ?? Self.curveTabs[0] }
    /// The point rules of the open tab.
    var curveEditing: CurveEditing { let t = openCurveTab; return CurveEditing(hue: t.hue, limit: t.min...t.max) }
    /// A curve point's pointer target: a circle of this radius, so 24 pt across.
    static let curvePointHitRadius = 12.0
    /// The smallest pointer target of a curve control, in points.
    static let curveMinTarget = 24.0

    /// The open tab's points as they render (`CurveEditing.displayed`), or the live points while one is dragged.
    func currentCurvePoints(_ g: ColorGrading) -> [[Double]] {
        if let d = grade.curveDraft { return d }
        let tab = openCurveTab
        return curveEditing.displayed(tab.hue ? g.hueCurve(tab.key) : g.curve(tab.key))
    }

    func writeCurve(_ g: ColorGrading, _ pts: [[Double]]) -> ColorGrading {
        var n = g
        let tab = openCurveTab, stored = curveEditing.stored(pts)
        if tab.hue { n.hueCurves[tab.key] = stored } else { n.curves[tab.key] = stored }
        return n
    }

    /// A point of the open tab in view coordinates; a stored point outside the range sits on the edge.
    func curveToView(_ pt: [Double]) -> CanvasPoint {
        let tab = openCurveTab, box = grade.curveBox
        let nx = tab.hue ? pt[0] / 360 : pt[0], ny = (pt[1] - tab.min) / (tab.max - tab.min)
        return CanvasPoint(box.x + max(0, min(1, nx)) * box.width, box.maxY - max(0, min(1, ny)) * box.height)
    }

    /// The open tab's (input, output) under a view point, clamped to the graph, at 1/1000.
    func curveFromView(_ p: CanvasPoint) -> [Double] {
        let tab = openCurveTab, box = grade.curveBox
        let nx = max(0, min(1, (p.x - box.x) / box.width)), ny = max(0, min(1, (box.maxY - p.y) / box.height))
        let x = tab.hue ? min(359.9, nx * 360) : nx
        return [(x * 1000).rounded() / 1000, ((tab.min + ny * (tab.max - tab.min)) * 1000).rounded() / 1000]
    }

    func curveGraph(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:curve", height: 200, draw: { [weak self] c, r, panel in
            self?.drawCurveGraph(c, r, panel, g)
        }, pointer: { [weak self] _, p, phase in
            guard let self else { return }
            switch phase {
            case 0: self.curvePress(g, p)
            case 1: self.curveDrag(p)
            default: self.curveRelease(g, commit: commit)
            }
        }, key: { [weak self] _, k in self?.curveKey(g, k, commit: commit) ?? false })
    }

    /// Keys on the focused curve graph (issue #171): Left / Right select the previous / next point, Up / Down move
    /// the selected point's output and Alt+Left / Alt+Right its input, by 1% of the axis (Shift: 10%); Enter adds a
    /// point (`addCurvePoint`), Delete / Backspace removes the selected one, Space does nothing (a replayed press
    /// would add a point at the graph's centre). A held arrow folds into one undo step.
    func curveKey(_ g: ColorGrading, _ k: EditorKey, commit: @escaping (ColorGrading) -> Void) -> Bool {
        let step = k.shift ? 0.1 : 0.01
        switch k.code {
        case .space: return true
        case .enter: addCurvePoint(g, commit: commit); return true
        case .delete, .backspace: deleteSelectedCurvePoint(g, commit: commit); return true
        case .left, .right:
            let d = k.code == .left ? -1.0 : 1.0
            if k.alt { nudgeCurvePoint(g, dx: d * step, dy: 0, commit: commit) } else { selectNextCurvePoint(g, by: Int(d)) }
            return true
        case .up, .down: nudgeCurvePoint(g, dx: 0, dy: (k.code == .up ? 1 : -1) * step, commit: commit); return true
        default: return false
        }
    }

    /// Selects the point `by` places from the selected one (from the first or last when none is selected).
    func selectNextCurvePoint(_ g: ColorGrading, by: Int) {
        let n = currentCurvePoints(g).count
        guard n > 0 else { return }
        let i = grade.selectedPoint.map { $0 + by } ?? (by > 0 ? 0 : n - 1)
        grade.selectedPoint = min(n - 1, max(0, i))
    }

    /// Moves the selected point by fractions of the tab's axes, through `CurveEditing.moving`.
    func nudgeCurvePoint(_ g: ColorGrading, dx: Double, dy: Double, commit: @escaping (ColorGrading) -> Void) {
        let tab = openCurveTab, pts = currentCurvePoints(g)
        guard let i = grade.selectedPoint, pts.indices.contains(i), let editor else { return }
        let span = tab.hue ? 360.0 : 1.0
        let moved = curveEditing.moving(i, to: [pts[i][0] + dx * span, pts[i][1] + dy * (tab.max - tab.min)], in: pts)
        guard moved != pts else { return }
        editor.withHistory("Edit color grade", coalesceKey: "grade:curve:nudge:\(tab.key):\(i)") { commit(writeCurve(g, moved)) }
    }

    /// CurveGraph: `max-w-[200px] rounded border border-panel-border-input bg-black/20`, view box 160 with the plot
    /// area at 8…152. The line is the curve the grade applies (ColorCurveMath = the renderer's GradeCurve):
    /// normalized, monotone and inside the range. Line and points are clipped to the graph.
    func drawCurveGraph(_ c: CanvasContext, _ r: CanvasRect, _ panel: InspectorPanel, _ g: ColorGrading) {
        let tab = openCurveTab
        let size = min(r.width, 200)
        let frame = CanvasRect(x: r.x + (r.width - size) / 2, y: r.y, width: size, height: size)
        let u = (size - 2) / 160
        grade.curveBox = CanvasRect(x: frame.x + 1 + 8 * u, y: frame.y + 1 + 8 * u, width: 144 * u, height: 144 * u)
        c.fillRoundedRect(frame, radius: 4, PanelTheme.stageScrim.withAlpha(Theme.mode == .light ? 0.05 : 0.2))
        c.strokeRoundedRect(frame.insetBy(0.5), radius: 3.5, PanelTheme.panelBorderInput, width: 1)
        Self.drawCurveGrid(c, frame: frame, u: u)
        if tab.hue { Self.drawHueAxis(c, frame: frame, u: u) }
        let pts = currentCurvePoints(g)
        let color = CanvasColor(tab.color.now)
        c.save()
        c.clip(.roundedRect(frame.insetBy(1), radius: 3))
        var path = CanvasPath()
        for (k, s) in ColorCurveMath.samples(pts, hue: tab.hue, limit: tab.min...tab.max, count: 144).enumerated() {
            let vp = curveToView([s.x, s.y])
            if k == 0 { path.move(to: vp) } else { path.line(to: vp) }
        }
        c.stroke(path, color, StrokeStyle(width: 1.5 * u))
        for (i, pt) in pts.enumerated() {   // r 2.5 (selected 3.5 white), #111 1-unit outline
            let vp = curveToView(pt)
            let sel = grade.selectedPoint == i
            let rad = (sel ? 3.5 : 2.5) * u
            let dot = CanvasPath.roundedRect(CanvasRect(x: vp.x - rad, y: vp.y - rad, width: 2 * rad, height: 2 * rad), radius: rad)
            c.fill(dot, sel ? PanelTheme.white : color)
            c.stroke(dot, CanvasColor(ThemeTokens.curvePointOutlinePair.now), StrokeStyle(width: u))
        }
        c.restore()
        // The target reaches a point's full hit radius past the plot area, so the end points are as easy to grab.
        panel.addHit(grade.curveBox.insetBy(-Self.curvePointHitRadius), .custom("grade:curve", 0))
    }

    /// Quarter lines (rgba(255,255,255,.08), 0.5 wide) over the plot area of a graph `frame` at `u` per view unit.
    static func drawCurveGrid(_ c: CanvasContext, frame: CanvasRect, u: Double) {
        func v(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(frame.x + 1 + x * u, frame.y + 1 + y * u) }
        for ratio in [0.25, 0.5, 0.75] {
            var h = CanvasPath(); h.move(to: v(8, 8 + ratio * 144)); h.line(to: v(152, 8 + ratio * 144))
            var w = CanvasPath(); w.move(to: v(8 + ratio * 144, 8)); w.line(to: v(8 + ratio * 144, 152))
            c.stroke(h, PanelTheme.white.withAlpha(0.08), StrokeStyle(width: 0.5 * u))
            c.stroke(w, PanelTheme.white.withAlpha(0.08), StrokeStyle(width: 0.5 * u))
        }
    }

    /// The hue axis: a 3-unit line at y 157 through #f33 #ff3 #3f3 #3ff #33f #f3f #f33.
    static func drawHueAxis(_ c: CanvasContext, frame: CanvasRect, u: Double) {
        func v(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(frame.x + 1 + x * u, frame.y + 1 + y * u) }
        let stops: [(Double, Double, Double)] = [(1, 0.2, 0.2), (1, 1, 0.2), (0.2, 1, 0.2), (0.2, 1, 1), (0.2, 0.2, 1), (1, 0.2, 1), (1, 0.2, 0.2)]
        let n = 72
        for k in 0..<n {
            let t = (Double(k) + 0.5) / Double(n) * 6, i = min(5, Int(t)), f = t - Double(i)
            let a = stops[i], b = stops[i + 1]
            let x0 = v(8 + 144 * Double(k) / Double(n), 155.5), x1 = v(8 + 144 * Double(k + 1) / Double(n), 158.5)
            c.fillRect(CanvasRect(x: x0.x, y: x0.y, width: x1.x - x0.x + 0.3, height: x1.y - x0.y),
                       CanvasColor(r: a.0 + (b.0 - a.0) * f, g: a.1 + (b.1 - a.1) * f, b: a.2 + (b.2 - a.2) * f))
        }
    }

    /// The nearest point within `curvePointHitRadius` of `p`, if any.
    func nearestCurvePoint(_ pts: [[Double]], to p: CanvasPoint) -> Int? {
        let d = pts.map { pt -> Double in let v = curveToView(pt); return hypot(v.x - p.x, v.y - p.y) }
        guard let i = d.indices.min(by: { d[$0] < d[$1] }), d[i] <= Self.curvePointHitRadius else { return nil }
        return i
    }

    /// A press selects the point under it, or adds one there (where the curve has room for it).
    func curvePress(_ g: ColorGrading, _ p: CanvasPoint) {
        grade.curveDraft = nil
        let pts = currentCurvePoints(g)
        if let i = nearestCurvePoint(pts, to: p) {
            let v = curveToView(pts[i])
            grade.selectedPoint = i; grade.curveDraft = pts
            grade.curveGrab = (v.x - p.x, v.y - p.y, p, false)
        } else if let added = curveEditing.inserting(curveFromView(p), into: pts) {
            grade.selectedPoint = added.index; grade.curveDraft = added.points
            grade.curveGrab = (0, 0, p, true)
        } else {
            grade.selectedPoint = nil; grade.curveGrab = nil
        }
    }

    /// A drag moves the pressed point by the pointer's motion, once it is 3 pt from the press.
    func curveDrag(_ p: CanvasPoint) {
        guard var grab = grade.curveGrab, let i = grade.selectedPoint, let pts = grade.curveDraft else { return }
        if !grab.moved && hypot(p.x - grab.start.x, p.y - grab.start.y) < 3 { return }
        grab.moved = true
        grade.curveGrab = grab
        grade.curveDraft = curveEditing.moving(i, to: curveFromView(CanvasPoint(p.x + grab.dx, p.y + grab.dy)), in: pts)
    }

    /// The release commits the edited curve as one undo step; a press that changed nothing commits nothing.
    func curveRelease(_ g: ColorGrading, commit: (ColorGrading) -> Void) {
        let draft = grade.curveDraft
        grade.curveDraft = nil; grade.curveGrab = nil
        guard let draft, draft != currentCurvePoints(g) else { return }
        commit(writeCurve(g, draft))
    }

    /// The tab's curve at `x` as the grade applies it (an RGB curve, or a hue curve: flat below three points).
    static func curveValue(hue: Bool, limit: ClosedRange<Double>, _ pts: [[Double]], at x: Double) -> Double {
        CurveEditing(hue: hue, limit: limit).value(pts, at: x)
    }

    /// A dragged point keeps its place in the order: it stays at least 0.01 (RGB) / 1° (hue) inside its neighbours,
    /// so no two points share an input (which the renderer rejects, dropping the whole curve) and the selection
    /// index keeps naming the dragged point. (`CurveEditing.moving` adds the pinned RGB end points.)
    static func draggedCurvePoint(_ p: [Double], index i: Int, in pts: [[Double]], hue: Bool) -> [Double] {
        [CurveEditing(hue: hue, limit: 0...1).constrainedInput(i, p[0], in: pts), p[1]]
    }

    /// At least `curveMinTarget` square around `glyph`, kept inside `row`.
    static func curveTarget(_ glyph: CanvasRect, in row: CanvasRect) -> CanvasRect {
        let w = max(glyph.width + 6, curveMinTarget), h = max(glyph.height + 6, curveMinTarget)
        let x = min(max(glyph.midX - w / 2, row.x), row.maxX - w), y = min(max(glyph.midY - h / 2, row.y), row.maxY - h)
        return CanvasRect(x: x, y: y, width: w, height: h)
    }

    /// Footer (`flex min-h-7 items-end gap-2`): the hint (9px text-5) or, with a removable point selected, a
    /// `Delete` text button; the 11px reset at the right (`pb-0.5`).
    func curveFooter(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:curvefoot", height: 28, draw: { [weak self] c, r, panel in
            self?.drawCurveFooter(c, r, panel, g)
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0 else { return }
            if part == 0 { self.grade.selectedPoint = nil; commit(self.writeCurve(g, self.openCurveTab.hue ? [] : GradeCurve.identity)) }
            else { self.deleteSelectedCurvePoint(g, commit: commit) }
        })
    }

    func drawCurveFooter(_ c: CanvasContext, _ r: CanvasRect, _ panel: InspectorPanel, _ g: ColorGrading) {
        let line = CanvasRect(x: r.x, y: r.maxY - 13.5, width: r.width - 19, height: 13.5)
        if let i = grade.selectedPoint, curveEditing.canRemove(i, in: currentCurvePoints(g)) {
            let w = c.measureText("Delete", font: PanelTheme.font(9)).width
            let del = CanvasRect(x: line.x, y: line.y - 2, width: w, height: 15.5)
            PanelDraw.text(c, "Delete", in: CanvasRect(x: del.x, y: line.y - 2, width: w, height: 13.5), font: PanelTheme.font(9),
                           color: panel.hovered == .custom("grade:curvefoot", 1) ? PanelTheme.text1 : PanelTheme.text4)
            panel.addHit(Self.curveTarget(del, in: r), .custom("grade:curvefoot", 1))
        } else {
            PanelDraw.text(c, "Click the graph or press Enter to add a point", in: line, font: PanelTheme.font(9), color: PanelTheme.text5)
        }
        let reset = CanvasRect(x: r.maxX - 11, y: r.maxY - 13, width: 11, height: 11)
        PanelIcon.reset.draw(c, in: reset, color: panel.hovered == .custom("grade:curvefoot", 0) ? PanelTheme.text1 : PanelTheme.text4)
        panel.addHit(Self.curveTarget(reset, in: r), .custom("grade:curvefoot", 0))
    }

    func deleteSelectedCurvePoint(_ g: ColorGrading, commit: (ColorGrading) -> Void) {
        guard let i = grade.selectedPoint, let pts = curveEditing.removing(i, from: currentCurvePoints(g)) else { return }
        grade.selectedPoint = nil
        commit(writeCurve(g, pts))
    }

    /// Enter: a point in the middle of the widest gap, on the curve, selected.
    func addCurvePoint(_ g: ColorGrading, commit: (ColorGrading) -> Void) {
        let edit = curveEditing, pts = currentCurvePoints(g)
        guard let added = edit.inserting(edit.insertionPoint(pts), into: pts) else { return }
        grade.selectedPoint = added.index
        commit(writeCurve(g, added.points))
    }

    /// Keys with no text field focused: Delete/Backspace removes the selected curve point; Enter adds a point.
    func gradeKey(_ k: EditorKey) -> Bool {
        guard openGroupId == "grade", let editor, let s = selected() else { return false }
        let g = editor.colorGrading(clipId: s.id) ?? ColorGrading()
        let commit: (ColorGrading) -> Void = { [weak self] n in self?.edited(editor.setColorGrading(clipId: s.id, n)) }
        switch k.code {
        case .delete, .backspace:
            guard grade.selectedPoint != nil else { return false }
            deleteSelectedCurvePoint(g, commit: commit); return true
        case .enter:
            addCurvePoint(g, commit: commit); return true
        default: return false
        }
    }
}
