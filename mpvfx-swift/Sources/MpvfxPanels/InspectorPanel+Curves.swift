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
        ("lumaVsSaturation", "Luma/Sat", ThemeTokens.curveLumaSatPair, false, -1, 1),
        ("saturationVsSaturation", "Sat/Sat", ThemeTokens.curveSatSatPair, false, -1, 1),
    ]

    // MARK: Curves (the curve modes and the curve graph)

    /// The height of one line of curve tabs (a pointer target tall).
    static let curveTabHeight = 24.0
    /// The tabs in three lines: RGB, hue-keyed, then luma/saturation-keyed curves.
    static let curveTabLines: [[Int]] = [[0, 1, 2, 3], [4, 5, 6], [7, 8]]

    /// Curve tabs: three lines of equal-width tabs, 11px text-2 (text-0 medium when open, text-1 on hover) over a
    /// 2pt accent bar when open, with a dot in the tab's curve colour when its curve is edited. Every tab is a
    /// pointer target the full line tall, and the text stays 4.5:1 on the panel in both modes (text-2).
    func curveTabsRow(_ g: ColorGrading) -> InspectorCustomRow {
        let lines = Double(Self.curveTabLines.count)
        return InspectorCustomRow(id: "grade:curvetabs", height: lines * Self.curveTabHeight + 1, draw: { [weak self] c, r, panel in
            guard let self else { return }
            let edited = Set(self.editedCurveTabs(g))
            for (line, tabs) in Self.curveTabLines.enumerated() {
                let w = r.width / Double(tabs.count)
                for (k, i) in tabs.enumerated() {
                    let tr = CanvasRect(x: r.x + Double(k) * w, y: r.y + Double(line) * Self.curveTabHeight, width: w, height: Self.curveTabHeight)
                    self.drawCurveTab(c, tr, i, panel, edited: edited.contains(Self.curveTabs[i].key))
                }
            }
            c.fillRect(CanvasRect(x: r.x, y: r.maxY - 1, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0, Self.curveTabs.indices.contains(part) else { return }
            self.grade.curveTab = Self.curveTabs[part].key; self.grade.selectedPoint = nil
        })
    }

    func drawCurveTab(_ c: CanvasContext, _ tr: CanvasRect, _ i: Int, _ panel: InspectorPanel, edited: Bool) {
        panel.targetHover(c, tr, .custom("grade:curvetabs", i))
        let t = Self.curveTabs[i], on = openCurveTab.key == t.key
        let font = PanelTheme.font(11, on ? .medium : .regular)
        let tw = c.measureText(t.label, font: font).width, dot = edited ? 8.0 : 0
        let x = tr.midX - (tw + dot) / 2
        let color = on ? PanelTheme.text0 : (panel.hovered == .custom("grade:curvetabs", i) ? PanelTheme.text1 : PanelTheme.text2)
        PanelDraw.text(c, t.label, in: CanvasRect(x: x, y: tr.midY - 8.25, width: tw + 1, height: 16.5), font: font, color: color)
        if edited {   // the "edited" mark: a 5pt dot in the curve's colour
            c.fill(.roundedRect(CanvasRect(x: x + tw + 3, y: tr.midY - 2.5, width: 5, height: 5), radius: 2.5), CanvasColor(t.color.now))
        }
        if on { c.fillRect(CanvasRect(x: tr.x + 4, y: tr.maxY - 2, width: tr.width - 8, height: 2), PanelTheme.accent) }
        panel.addHit(tr, .custom("grade:curvetabs", i))
    }

    /// The tabs whose curve renders differently from the default (identity, or a flat hue curve).
    func editedCurveTabs(_ g: ColorGrading) -> [String] {
        Self.curveTabs.filter { Self.isCurveEdited(g, $0) }.map(\.key)
    }

    static func isCurveEdited(_ g: ColorGrading, _ t: CurveTab) -> Bool {
        let edit = CurveEditing(hue: t.hue, limit: t.min...t.max)
        if t.hue { return edit.displayed(g.hueCurve(t.key)).contains { abs($0[1]) > 1e-9 } }
        if t.min < 0 { return edit.displayed(g.curve(t.key)).contains { abs($0[1]) > 1e-9 } }
        return edit.displayed(g.curve(t.key)) != GradeCurve.identity
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
        InspectorCustomRow(id: "grade:curve", height: Self.curveGraphSize(bodyContentWidth), draw: { [weak self] c, r, panel in
            self?.drawCurveGraph(c, r, panel, g)
        }, pointer: { [weak self] _, p, phase in
            guard let self else { return }
            switch phase {
            case 0: self.curvePress(g, p, commit: commit)
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

    /// The graph's side for a body `width`: square, as wide as the body, at least 160 pt (issue #177).
    static func curveGraphSize(_ width: Double) -> Double { max(160, width) }

    /// CurveGraph: `rounded border border-panel-border-input bg-black/20`, square at the row's height (the body
    /// width), view box 160 with the plot area at 8…152, so strokes and points scale with it. The line is the curve
    /// the grade applies (ColorCurveMath = the renderer's GradeCurve): normalized, monotone and inside the range.
    /// Line, reference lines and points are clipped to the graph.
    func drawCurveGraph(_ c: CanvasContext, _ r: CanvasRect, _ panel: InspectorPanel, _ g: ColorGrading) {
        let tab = openCurveTab
        let size = r.height
        let frame = CanvasRect(x: r.x + (r.width - size) / 2, y: r.y, width: size, height: size)
        let u = (size - 2) / 160
        grade.curveBox = CanvasRect(x: frame.x + 1 + 8 * u, y: frame.y + 1 + 8 * u, width: 144 * u, height: 144 * u)
        c.fillRoundedRect(frame, radius: 4, PanelTheme.stageScrim.withAlpha(Theme.mode == .light ? 0.05 : 0.2))
        c.strokeRoundedRect(frame.insetBy(0.5), radius: 3.5, PanelTheme.panelBorderInput, width: 1)
        Self.drawCurveGrid(c, frame: frame, u: u)
        if tab.hue { Self.drawHueAxis(c, frame: frame, u: u) }
        else if tab.min < 0 { Self.drawDeltaAxis(c, frame: frame, u: u, saturation: tab.key == "saturationVsSaturation") }
        let pts = currentCurvePoints(g)
        let color = CanvasColor(tab.color.now)
        c.save()
        c.clip(.roundedRect(frame.insetBy(1), radius: 3))
        drawCurveReferences(c, g, tab, u: u)
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

    /// The default curve (the diagonal, or the zero line of a hue curve) as a faint guide; on Master, R, G and B also
    /// every other edited RGB curve, faint (40%) in its own colour, under the open one (issue #177 A5).
    func drawCurveReferences(_ c: CanvasContext, _ g: ColorGrading, _ tab: CurveTab, u: Double) {
        var guide = CanvasPath()
        guide.move(to: curveToView([0, 0])); guide.line(to: curveToView(tab.hue ? [360, 0] : [1, tab.min < 0 ? 0 : 1]))
        c.stroke(guide, PanelTheme.white.withAlpha(0.16), StrokeStyle(width: 0.5 * u))
        guard !tab.hue && tab.min == 0 else { return }
        for other in Self.curveTabs.prefix(4) where other.key != tab.key && Self.isCurveEdited(g, other) {
            var path = CanvasPath()
            for (k, s) in ColorCurveMath.samples(g.curve(other.key), hue: false, limit: 0...1, count: 144).enumerated() {
                let vp = curveToView([s.x, s.y])
                if k == 0 { path.move(to: vp) } else { path.line(to: vp) }
            }
            c.stroke(path, CanvasColor(other.color.now).withAlpha(0.4), StrokeStyle(width: u))
        }
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

    static func drawDeltaAxis(_ c: CanvasContext, frame: CanvasRect, u: Double, saturation: Bool) {
        for k in 0..<72 {
            let t = (Double(k) + 0.5) / 72
            let color = saturation ? CanvasColor(ThemeTokens.curveRedPair.now).over(PanelTheme.white, opacity: t)
                : PanelTheme.white.over(PanelTheme.black, opacity: t)
            c.fillRect(CanvasRect(x: frame.x + 1 + (8 + Double(k) * 2) * u, y: frame.y + 1 + 155.5 * u,
                                  width: 2 * u + 0.3, height: 3 * u), color)
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

    /// Two presses on one point at most this far apart (seconds, on the editor's clock) are a double-click.
    static let curveDoubleClickInterval = 0.4

    /// A press selects the point under it (a second press on it within `curveDoubleClickInterval` deletes it), or
    /// adds one there (where the curve has room for it).
    func curvePress(_ g: ColorGrading, _ p: CanvasPoint, commit: (ColorGrading) -> Void) {
        grade.curveDraft = nil
        let pts = currentCurvePoints(g), now = editor?.now() ?? 0
        let previous = grade.curveClick
        grade.curveClick = nil
        if let i = nearestCurvePoint(pts, to: p) {
            if let last = previous, last.tab == openCurveTab.key, last.index == i, now - last.time <= Self.curveDoubleClickInterval,
               let removed = curveEditing.removing(i, from: pts) {
                grade.selectedPoint = nil; grade.curveGrab = nil
                commit(writeCurve(g, removed)); return
            }
            let v = curveToView(pts[i])
            grade.selectedPoint = i; grade.curveDraft = pts
            grade.curveGrab = (v.x - p.x, v.y - p.y, p, false)
            grade.curveClick = (openCurveTab.key, i, now)
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

    /// Footer: three 11px text buttons, each a 24pt-tall target: Delete point (part 1), Reset curve (part 0, the open
    /// tab) and Reset all (part 2, every curve, one undo step). Always drawn; a button with nothing to do is dimmed
    /// and takes no press (issue #177 A3, A4).
    func curveFooter(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:curvefoot", height: 28, draw: { [weak self] c, r, panel in
            self?.drawCurveFooter(c, r, panel, g)
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0 else { return }
            switch part {
            case 0: self.grade.selectedPoint = nil; commit(self.writeCurve(g, self.openCurveTab.hue ? [] : (self.openCurveTab.min < 0 ? GradeCurve.flatDelta : GradeCurve.identity)))
            case 1: self.deleteSelectedCurvePoint(g, commit: commit)
            default: var n = g; n.curves = [:]; n.hueCurves = [:]; self.grade.selectedPoint = nil; commit(n)
            }
        })
    }

    /// The footer's buttons in order: label, hit part, whether it has something to do.
    func curveFooterButtons(_ g: ColorGrading) -> [(label: String, part: Int, enabled: Bool)] {
        let canDelete = grade.selectedPoint.map { curveEditing.canRemove($0, in: currentCurvePoints(g)) } ?? false
        return [("Delete point", 1, canDelete), ("Reset curve", 0, Self.isCurveEdited(g, openCurveTab)), ("Reset all", 2, !editedCurveTabs(g).isEmpty)]
    }

    func drawCurveFooter(_ c: CanvasContext, _ r: CanvasRect, _ panel: InspectorPanel, _ g: ColorGrading) {
        var x = r.x
        for b in curveFooterButtons(g) {
            let w = max(Self.curveMinTarget, c.measureText(b.label, font: PanelTheme.font(11)).width + (r.width < 300 ? 8 : 16))
            let br = CanvasRect(x: x, y: r.y + 2, width: w, height: Self.curveMinTarget)
            let hot = b.enabled && panel.hovered == .custom("grade:curvefoot", b.part)
            if b.enabled { panel.targetHover(c, br, .custom("grade:curvefoot", b.part)) }
            c.strokeRoundedRect(br.insetBy(0.5), radius: PanelTheme.radius, b.enabled ? (hot ? PanelTheme.inspectorText : PanelTheme.panelBorderInput)
                                : PanelTheme.inspectorControl, width: 1)
            PanelDraw.text(c, b.label, in: br, font: PanelTheme.font(11), color: b.enabled ? (hot ? PanelTheme.text0 : PanelTheme.text1) : PanelTheme.inspectorText,
                           align: .center)
            if b.enabled { panel.addHit(br, .custom("grade:curvefoot", b.part)) }
            x = br.maxX + 6
        }
    }

    /// The editing hint under the footer (10px text-2: 4.5:1 on the panel in both modes).
    func curveHintRow() -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:curvehint", height: 15, draw: { c, r, _ in
            PanelDraw.text(c, "Click adds a point · drag moves it · double-click deletes it", in: r, font: PanelTheme.font(11), color: PanelTheme.text2)
        })
    }

    /// Input and Output of the selected point: percent on Master/R/G/B; on hue curves degrees across and a degree
    /// (Hue/Hue) or percent delta. A typed or scrubbed value is one undo step, kept inside the neighbours by
    /// `CurveEditing.moving`. With no point selected both read "–" and are disabled; an RGB end point's Input too.
    func curvePointRows(_ g: ColorGrading, set: @escaping (ColorGrading) -> Bool) -> [InspectorRow] {
        let tab = openCurveTab, edit = curveEditing, pts = currentCurvePoints(g)
        let sel = grade.selectedPoint.flatMap { pts.indices.contains($0) ? $0 : nil }
        let rows: [InspectorRow] = [0, 1].map { axis in
            let unit = Self.curveFieldUnit(tab, axis: axis)
            var n = numberRow(key: axis == 0 ? "grade:curve:input" : "grade:curve:output", label: axis == 0 ? "Input" : "Output",
                              value: sel.map { pts[$0][axis] * unit.scale } ?? 0, suffix: unit.suffix, tier: .default, step: unit.step,
                              apply: { [weak self] v in self?.typedCurveValue(v / unit.scale, axis: axis, g, set: set) ?? false })
            if sel == nil { n.text = "–"; n.scrub = nil }
            n.disabled = sel == nil || (axis == 0 && sel.map { edit.isPinned($0, in: pts) } == true)
            return .init(.number(n))
        }
        return [rows[0], .init(.spacer(2)), rows[1]]
    }

    /// A field's display scale, suffix and scrub step per point of drag.
    static func curveFieldUnit(_ tab: CurveTab, axis: Int) -> (scale: Double, suffix: String, step: Double) {
        if axis == 0 { return tab.hue ? (1, "°", 1) : (100, "%", 0.5) }
        return tab.key == "hueVsHue" ? (1, "°", 1) : (100, "%", 0.5)
    }

    /// Sets the selected point's input (`axis` 0) or output (1) to `v` in curve units; false when nothing changed.
    func typedCurveValue(_ v: Double, axis: Int, _ g: ColorGrading, set: (ColorGrading) -> Bool) -> Bool {
        let pts = currentCurvePoints(g)
        guard let i = grade.selectedPoint, pts.indices.contains(i), v.isFinite else { return false }
        var p = pts[i]
        p[axis] = v
        let moved = curveEditing.moving(i, to: p, in: pts)
        return moved != pts && set(writeCurve(g, moved))
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
