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
import MpvfxAudioGraph

/// A point on a response graph a drag moves: the chain node it edits, where it sits and which way it may go.
public struct AfxGraphHandle: Equatable {
    public var node: Int
    public var frequency: Double
    /// The node's gain for a bell or shelf; for a pass filter, the curve's level at its corner (it moves sideways only).
    public var gain: Double
    public var movesGain: Bool
    public var movesFrequency: Bool
    /// The Tone EQ band it stands for (nil on a module's own graph).
    public var band: String?
}

/// A response-graph handle drag in flight (committed on release, one undo step), its dB span fixed at the press.
public struct AfxGraphDrag: Equatable {
    public var graph: String, handle: Int
    public var frequency: Double, gain: Double
    public var range: Double
}

/// Where a graph plotted on the last draw, and the dB span it showed.
public struct AfxGraphBox: Equatable {
    public var box: CanvasRect
    public var range: Double
}

/// What one response graph draws: its row (the hit id), the chain nodes it sums, its handles, and its opacity
/// (a bypassed module draws at half and takes no pointer).
struct AfxGraphSpec {
    var row: String
    var nodes: [(i: Int, node: FxNode)]
    var handles: [AfxGraphHandle]
    var alpha: Double
}

/// A graph as laid out for one draw: the spec, the plot box and the dB span.
struct AfxGraphFrame {
    var spec: AfxGraphSpec
    var box: CanvasRect
    var range: Double
}

/// The response graph's axes: 20 Hz to 20 kHz on a log scale across, dB up with 0 dB in the middle.
public enum AfxGraphScale {
    public static let minHz = 20.0, maxHz = 20_000.0
    public static let gridHz: [Double] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
    public static func x(_ f: Double, in b: CanvasRect) -> Double {
        b.x + log(max(minHz, min(maxHz, f)) / minHz) / log(maxHz / minHz) * b.width
    }
    public static func frequency(_ x: Double, in b: CanvasRect) -> Double {
        minHz * pow(maxHz / minHz, max(0, min(1, (x - b.x) / max(1, b.width))))
    }
    public static func y(_ db: Double, range: Double, in b: CanvasRect) -> Double {
        b.midY - max(-range, min(range, db)) / range * b.height / 2
    }
    public static func gain(_ y: Double, range: Double, in b: CanvasRect) -> Double {
        (b.midY - y) / max(1, b.height / 2) * range
    }
    /// ±12 dB, widened in 6 dB steps to fit the largest gain, at most ±42.
    public static func range(_ gains: [Double]) -> Double {
        min(42, max(12, ((gains.map(abs).max() ?? 0) / 6).rounded(.up) * 6))
    }
    /// "100", "1k", "10k".
    public static func label(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }
}

extension InspectorPanel {
    static let afxGraphH = 96.0
    /// Height the graph adds to an open module: the rule, the plot and its padding.
    static var afxGraphBlockH: Double { 1 + 6 + afxGraphH + 6 }

    /// The handle a filter module's graph shows for `node` at chain index `i`.
    static func afxFilterHandle(_ node: FxNode, _ i: Int) -> AfxGraphHandle {
        let p = AudioFx.normalize(node.type, node.params, version: node.version ?? 1)
        let hasGain = p["gain"] != nil
        let f = p.num("frequency")
        let level = hasGain ? p.num("gain") : (AudioFxResponse.gainDb(node, at: f) ?? 0)
        return AfxGraphHandle(node: i, frequency: f, gain: level, movesGain: hasGain, movesFrequency: true, band: nil)
    }

    /// The drag in flight on graph `row`, if any.
    func afxDrag(_ row: String) -> AfxGraphDrag? { audioFxUI.graphDrag.flatMap { $0.graph == row ? $0 : nil } }

    /// The spec's nodes with the dragged handle's values in place, so the curve follows the pointer before the commit.
    func afxDraggedNodes(_ spec: AfxGraphSpec) -> [FxNode] {
        guard let d = afxDrag(spec.row), spec.handles.indices.contains(d.handle - 1) else { return spec.nodes.map(\.node) }
        let h = spec.handles[d.handle - 1]
        return spec.nodes.map { item in
            guard item.i == h.node else { return item.node }
            var n = item.node, p = AudioFx.normalize(n.type, n.params, version: n.version ?? 1)
            if h.movesFrequency { p["frequency"] = .number(d.frequency) }
            if h.movesGain { p["gain"] = .number(d.gain) }
            n.params = p
            return n
        }
    }

    /// Draws a response graph into `rect` and records its hits (`.custom(row, 0)` the plot, `.custom(row, k)` handle k).
    func afxDrawResponse(_ c: CanvasContext, _ rect: CanvasRect, _ spec: AfxGraphSpec) {
        let drawn = afxDraggedNodes(spec)
        let drag = afxDrag(spec.row)
        let box = CanvasRect(x: rect.x + 22, y: rect.y + 6, width: rect.width - 28, height: rect.height - 20)
        let g = AfxGraphFrame(spec: spec, box: box, range: drag?.range ?? AfxGraphScale.range(spec.handles.map(\.gain) + [0]))
        audioFxUI.graphBoxes[spec.row] = AfxGraphBox(box: box, range: g.range)
        Self.afxGraphGrid(c, rect, g)
        Self.afxGraphCurve(c, g, nodes: drawn)
        if spec.alpha >= 1 { addHit(box, .custom(spec.row, 0)) }   // a bypassed module's graph is a picture, not a control
        for (k, h) in spec.handles.enumerated() {
            afxDrawHandle(c, Self.afxShownHandle(h, drag?.handle == k + 1 ? drag : nil, drawn), g, part: k + 1)
        }
    }

    /// Where a handle is drawn: at its node's values, or where the drag in flight has put it.
    static func afxShownHandle(_ h: AfxGraphHandle, _ drag: AfxGraphDrag?, _ nodes: [FxNode]) -> AfxGraphHandle {
        guard let drag else { return h }
        var shown = h
        shown.frequency = drag.frequency
        shown.gain = h.movesGain ? drag.gain : AudioFxResponse.gainDb(nodes, at: drag.frequency)
        return shown
    }

    /// One handle's dot (larger and in the text colour while hovered or dragged) and, on a live module, its hit.
    func afxDrawHandle(_ c: CanvasContext, _ h: AfxGraphHandle, _ g: AfxGraphFrame, part: Int) {
        let row = g.spec.row, alpha = g.spec.alpha
        let lit = afxDrag(row)?.handle == part || hovered == .custom(row, part)
        let pt = CanvasPoint(AfxGraphScale.x(h.frequency, in: g.box), AfxGraphScale.y(h.gain, range: g.range, in: g.box))
        let rad = lit ? 4.5 : 3.5
        let dot = CanvasPath.roundedRect(CanvasRect(x: pt.x - rad, y: pt.y - rad, width: 2 * rad, height: 2 * rad), radius: rad)
        c.fill(dot, (lit ? PanelTheme.text0 : PanelTheme.accent).withAlpha(alpha))
        c.stroke(dot, PanelTheme.panelBg, StrokeStyle(width: 1))
        if alpha >= 1 { addHit(CanvasRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14), .custom(row, part)) }
    }

    /// The plot's frame, the octave grid with its frequency labels, the 0 dB line and the dB span at the left.
    static func afxGraphGrid(_ c: CanvasContext, _ rect: CanvasRect, _ g: AfxGraphFrame) {
        let alpha = g.spec.alpha, box = g.box
        afxGraphBackdrop(c, rect, alpha: alpha)
        let faint = PanelTheme.white.withAlpha((Theme.mode == .light ? 0.25 : 0.08) * alpha)
        for f in AfxGraphScale.gridHz {
            let x = AfxGraphScale.x(f, in: box)
            var l = CanvasPath(); l.move(to: CanvasPoint(x, box.y)); l.line(to: CanvasPoint(x, box.maxY))
            c.stroke(l, faint, StrokeStyle(width: 0.5))
            guard [100.0, 1000, 10000].contains(f) else { continue }
            PanelDraw.text(c, AfxGraphScale.label(f), in: CanvasRect(x: x - 12, y: box.maxY + 1, width: 24, height: 12),
                           font: PanelTheme.mono(8), color: PanelTheme.text2.withAlpha(alpha), align: .center)
        }
        for db in [-g.range / 2, 0, g.range / 2] {
            let y = AfxGraphScale.y(db, range: g.range, in: box)
            var l = CanvasPath(); l.move(to: CanvasPoint(box.x, y)); l.line(to: CanvasPoint(box.maxX, y))
            c.stroke(l, db == 0 ? faint.withAlpha(2.5 * faint.a) : faint, StrokeStyle(width: db == 0 ? 1 : 0.5))
        }
        let span = jsNumberToString(g.range)
        PanelDraw.text(c, "+" + span, in: CanvasRect(x: rect.x + 2, y: box.y - 2, width: 20, height: 12), font: PanelTheme.mono(8),
                       color: PanelTheme.text2.withAlpha(alpha))
        PanelDraw.text(c, "−" + span, in: CanvasRect(x: rect.x + 2, y: box.maxY - 10, width: 20, height: 12), font: PanelTheme.mono(8),
                       color: PanelTheme.text2.withAlpha(alpha))
    }

    /// The plot's rounded backdrop and border (the ease graph's, so the rack's pictures read as one family).
    static func afxGraphBackdrop(_ c: CanvasContext, _ rect: CanvasRect, alpha: Double) {
        c.fillRoundedRect(rect, radius: 4, PanelTheme.stageScrim.withAlpha((Theme.mode == .light ? 0.05 : 0.2) * alpha))
        c.strokeRoundedRect(rect.insetBy(0.5), radius: 3.5, PanelTheme.panelBorderInput.withAlpha(alpha), width: 1)
    }

    /// The summed response of `nodes`: a filled band from 0 dB to the curve, and the curve itself.
    static func afxGraphCurve(_ c: CanvasContext, _ g: AfxGraphFrame, nodes: [FxNode]) {
        let box = g.box, alpha = g.spec.alpha
        let steps = max(32, Int(box.width / 2))
        let pts: [CanvasPoint] = (0...steps).map { k in
            let x = box.x + Double(k) / Double(steps) * box.width
            return CanvasPoint(x, AfxGraphScale.y(AudioFxResponse.gainDb(nodes, at: AfxGraphScale.frequency(x, in: box)), range: g.range, in: box))
        }
        let zero = AfxGraphScale.y(0, range: g.range, in: box)
        var area = CanvasPath(); area.move(to: CanvasPoint(box.x, zero))
        var line = CanvasPath()
        for (k, p) in pts.enumerated() { area.line(to: p); if k == 0 { line.move(to: p) } else { line.line(to: p) } }
        area.line(to: CanvasPoint(box.maxX, zero)); area.close()
        c.withState {
            c.clip(box)
            c.fill(area, PanelTheme.accent.withAlpha(0.14 * alpha))
            c.stroke(line, PanelTheme.accent.withAlpha(alpha), StrokeStyle(width: 1.5))
        }
    }

    /// Drives a graph's handles: a press on handle k starts its drag, moves follow the pointer (log frequency across,
    /// dB up), the release commits once through `commit(handle, frequency, gain)`. A press on the plot does nothing.
    func afxGraphPointer(row: String, handles: [AfxGraphHandle],
                         commit: @escaping (AfxGraphHandle, Double, Double) -> Void) -> (Int, CanvasPoint, Int) -> Void {
        { [weak self] part, pt, phase in
            guard let self, let g = self.audioFxUI.graphBoxes[row], handles.indices.contains(part - 1) else { return }
            let h = handles[part - 1]
            if phase == 0 {
                self.audioFxUI.graphDrag = AfxGraphDrag(graph: row, handle: part, frequency: h.frequency, gain: h.gain, range: g.range)
                return
            }
            guard var d = self.afxDrag(row) else { return }
            if h.movesFrequency { d.frequency = AfxGraphScale.frequency(pt.x, in: g.box) }
            if h.movesGain { d.gain = max(-g.range, min(g.range, AfxGraphScale.gain(pt.y, range: g.range, in: g.box))) }
            self.audioFxUI.graphDrag = d
            if phase == 2 { self.audioFxUI.graphDrag = nil }
            commit(h, d.frequency, d.gain)
        }
    }

    /// A filter module's graph commit: frequency to the Hz and gain to 0.1 dB, inside the effect's ranges.
    static func afxFilterParams(_ node: FxNode, _ h: AfxGraphHandle, frequency: Double, gain: Double) -> FxParams {
        var p = AudioFx.normalize(node.type, node.params, version: node.version ?? 1)
        if h.movesFrequency { p["frequency"] = .number(frequency.rounded()) }
        if h.movesGain { p["gain"] = .number((gain * 10).rounded() / 10) }
        return AudioFx.normalize(node.type, p, version: node.version ?? 1)   // clamps into the registry's ranges
    }

    // MARK: Where the graphs sit

    /// Height an open module's picture adds: a response graph for a filter, a transfer curve for a dynamics node.
    static func afxGraphHeight(_ type: String) -> Double {
        AudioFxResponse.filterTypes.contains(type) || AudioFxResponse.dynamicsTypes.contains(type) ? afxGraphBlockH : 0
    }

    /// An open module's picture: its response with one draggable point, or its static curve.
    func afxDrawModuleGraph(_ c: CanvasContext, _ r: CanvasRect, _ item: (i: Int, node: FxNode), alpha: Double) {
        guard AudioFxResponse.filterTypes.contains(item.node.type) else { Self.afxDrawTransfer(c, r, item.node, alpha: alpha); return }
        afxDrawResponse(c, r, AfxGraphSpec(row: "afx:node:\(item.i)", nodes: [item], handles: [Self.afxFilterHandle(item.node, item.i)],
                                           alpha: alpha))
    }

    /// The module row's pointer: drags its graph's point (filters only), writing the params through `update`.
    func afxNodeGraphPointer(_ node: FxNode, _ i: Int, update: @escaping (FxParams) -> Void) -> (Int, CanvasPoint, Int) -> Void {
        guard AudioFxResponse.filterTypes.contains(node.type) else { return { _, _, _ in } }
        return afxGraphPointer(row: "afx:node:\(i)", handles: [Self.afxFilterHandle(node, i)]) { h, f, g in
            update(Self.afxFilterParams(node, h, frequency: f, gain: g))
        }
    }

    /// A Tone EQ's bands as graph nodes and one gain-only point per band (its frequency is the band's own).
    static func afxEqGraphParts(_ chain: FxChain, eqId: String) -> (nodes: [(i: Int, node: FxNode)], handles: [AfxGraphHandle]) {
        let nodes = chain.nodes.enumerated().filter { $0.element.fromEq == eqId }.map { (i: $0.offset, node: $0.element) }
        let handles = nodes.map { item -> AfxGraphHandle in
            let p = AudioFx.normalize(item.node.type, item.node.params, version: item.node.version ?? 1)
            return AfxGraphHandle(node: item.i, frequency: p.num("frequency"), gain: p.num("gain"), movesGain: true,
                                  movesFrequency: false, band: item.node.label)
        }
        return (nodes, handles)
    }

    // MARK: Dynamics

    /// A compressor, limiter or gate's static curve: input level across (−60…0 dB), output up, the unity diagonal for
    /// reference and the threshold marked, from the gain law the processor runs (`AudioFxResponse.outputDb`).
    static func afxDrawTransfer(_ c: CanvasContext, _ rect: CanvasRect, _ node: FxNode, alpha: Double) {
        let size = min(rect.width, rect.height + 64)
        let plot = CanvasRect(x: rect.x + (rect.width - size) / 2, y: rect.y, width: size, height: rect.height)
        let box = CanvasRect(x: plot.x + 22, y: plot.y + 6, width: plot.width - 28, height: plot.height - 20)
        afxGraphBackdrop(c, plot, alpha: alpha)
        let lo = -60.0
        func pt(_ i: Double, _ o: Double) -> CanvasPoint {
            CanvasPoint(box.x + (i - lo) / -lo * box.width, box.maxY - (max(lo, min(0, o)) - lo) / -lo * box.height)
        }
        var unity = CanvasPath(); unity.move(to: pt(lo, lo)); unity.line(to: pt(0, 0))
        c.stroke(unity, PanelTheme.white.withAlpha((Theme.mode == .light ? 0.25 : 0.1) * alpha), StrokeStyle(width: 0.5))
        let threshold = AudioFx.normalize(node.type, node.params, version: node.version ?? 1)[node.type == "limiter" ? "limit" : "threshold"]?.number ?? 0
        let tx = pt(threshold, 0).x
        var tick = CanvasPath(); tick.move(to: CanvasPoint(tx, box.y)); tick.line(to: CanvasPoint(tx, box.maxY))
        c.stroke(tick, PanelTheme.text2.withAlpha(0.6 * alpha), StrokeStyle(width: 0.5, dash: [2, 2]))
        var curve = CanvasPath()
        for k in 0...120 {
            let i = lo + Double(k) / 120 * -lo
            let q = pt(i, AudioFxResponse.outputDb(node, inputDb: i) ?? i)
            if k == 0 { curve.move(to: q) } else { curve.line(to: q) }
        }
        c.withState { c.clip(box); c.stroke(curve, PanelTheme.accent.withAlpha(alpha), StrokeStyle(width: 1.5)) }
        let label = PanelTheme.text2.withAlpha(alpha)
        PanelDraw.text(c, "in", in: CanvasRect(x: box.maxX - 20, y: box.maxY + 1, width: 20, height: 12), font: PanelTheme.mono(8),
                       color: label, align: .right)
        PanelDraw.text(c, "out", in: CanvasRect(x: plot.x + 2, y: box.y - 2, width: 20, height: 12), font: PanelTheme.mono(8), color: label)
        PanelDraw.text(c, String(format: "%.0f", threshold), in: CanvasRect(x: tx - 12, y: box.maxY + 1, width: 24, height: 12),
                       font: PanelTheme.mono(8), color: label, align: .center)
    }
}
