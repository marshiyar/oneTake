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

/// The value / speed graph: engine-evaluated samples of the property across its keyed range (zoomed and panned in
/// time), the keys as diamonds, the playhead, and in the speed graph the focused segment's two handles, which drag.
extension KeyframeEasingPanel {
    func drawGraph(_ c: CanvasContext, _ r: CanvasRect, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) {
        c.fillRoundedRect(r, radius: PanelTheme.radiusMd, PanelTheme.panelBgInset)
        c.strokeRoundedRect(r.insetBy(0.5), radius: PanelTheme.radiusMd, PanelTheme.panelBorder, width: 1)
        hits.add(r, .graph)
        guard let s = KeyframeEasingGraph.samples(editor, t) else { return }
        let plot = CanvasRect(x: r.x + 8, y: r.y + 20, width: r.width - 16, height: r.height - 36)
        let frames = visibleFrames(s)
        let handles = state.graph == .speed ? speedHandles(editor, t) : []
        let series = state.graph == .value ? (0..<(s.values.first?.count ?? 0)).map { d in s.values.map { $0[d] } } : [s.speeds]
        let values = valueRange(series.flatMap { $0 } + handles.map(\.velocity))
        let box = GraphBox(plot: plot, frames: frames, values: values)
        graphBox = box
        drawAxisText(c, r, t, values)
        c.withState {
            c.clip(.roundedRect(r, radius: PanelTheme.radiusMd))
            drawPlayhead(c, box, editor, t)
            for (i, line) in series.enumerated() { drawSeries(c, box, s, line, color: Self.seriesColor(i)) }
            drawKeys(c, box, s, t)
            for h in handles { drawSpeedHandle(c, box, h) }
        }
    }

    /// The shown frame range: the keyed range, narrowed by zoom and moved by pan.
    func visibleFrames(_ s: KeyframeEasingGraph.Samples) -> ClosedRange<Double> {
        let first = s.keyFrames.first ?? s.firstFrame, last = max(first + 1, s.keyFrames.last ?? first + 1)
        let span = (last - first) / state.zoom, start = first + state.pan * (last - first)
        return start...(start + span)
    }

    /// Values padded by 8 % (a flat line gets ±1 so it sits in the middle); speed graphs start at 0.
    func valueRange(_ v: [Double]) -> ClosedRange<Double> {
        let finite = v.filter(\.isFinite)
        var lo = finite.min() ?? 0, hi = finite.max() ?? 1
        if state.graph == .speed { lo = 0 }
        if hi - lo < 1e-9 { lo -= 1; hi += 1 }
        let pad = (hi - lo) * 0.08
        return (state.graph == .speed ? lo : lo - pad)...(hi + pad)
    }

    static func seriesColor(_ i: Int) -> CanvasColor {
        [PanelTheme.accent, PanelTheme.mint, PanelTheme.red400, PanelTheme.audioViolet][i % 4]
    }

    func point(_ b: GraphBox, frame: Double, value: Double) -> CanvasPoint {
        let fx = (frame - b.frames.lowerBound) / max(1e-9, b.frames.upperBound - b.frames.lowerBound)
        let fy = (value - b.values.lowerBound) / max(1e-9, b.values.upperBound - b.values.lowerBound)
        return CanvasPoint(b.plot.x + fx * b.plot.width, b.plot.maxY - fy * b.plot.height)
    }

    func drawAxisText(_ c: CanvasContext, _ r: CanvasRect, _ t: KeyframeEasingTarget, _ v: ClosedRange<Double>) {
        let u = Self.unit(t.parameterId), f = PanelTheme.mono(9)
        let top = state.graph == .speed ? "\(PanelFormat.number(v.upperBound * u.factor, decimals: 1)) \(u.unit)"
                                        : PanelFormat.number(v.upperBound * u.factor, decimals: 1)
        PanelDraw.text(c, top, in: CanvasRect(x: r.x + 8, y: r.y + 3, width: r.width / 2, height: 14), font: f, color: PanelTheme.text5)
        let title = state.graph == .speed ? "Speed" : "Value"
        PanelDraw.text(c, title, in: CanvasRect(x: r.midX, y: r.y + 3, width: r.width / 2 - 8, height: 14), font: PanelTheme.font(9),
                       color: PanelTheme.text4, align: .right)
    }

    func drawSeries(_ c: CanvasContext, _ b: GraphBox, _ s: KeyframeEasingGraph.Samples, _ line: [Double], color: CanvasColor) {
        var path = CanvasPath()
        for (i, v) in line.enumerated() {
            let p = point(b, frame: s.firstFrame + Double(i) * s.step, value: v)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        c.stroke(path, color, StrokeStyle(width: 1.5))
    }

    func drawKeys(_ c: CanvasContext, _ b: GraphBox, _ s: KeyframeEasingGraph.Samples, _ t: KeyframeEasingTarget) {
        let edited = Set(t.refs.map(\.frame))
        for f in s.keyFrames {
            let x = point(b, frame: f, value: b.values.lowerBound).x
            PanelDraw.vline(c, x: x, y0: b.plot.y, y1: b.plot.maxY, PanelTheme.panelHairline)
            var d = CanvasPath()
            let y = b.plot.maxY + 7
            d.move(to: CanvasPoint(x, y - 4)); d.line(to: CanvasPoint(x + 4, y)); d.line(to: CanvasPoint(x, y + 4)); d.line(to: CanvasPoint(x - 4, y)); d.close()
            if edited.contains(f) { c.fill(d, PanelTheme.accent) } else { c.stroke(d, PanelTheme.text3, StrokeStyle(width: 1)) }
        }
    }

    func drawPlayhead(_ c: CanvasContext, _ b: GraphBox, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) {
        guard let f = editor.localFrame(clipId: t.clipId, time: time), b.frames.contains(f) else { return }
        let x = point(b, frame: f, value: 0).x
        PanelDraw.vline(c, x: x, y0: b.plot.y - 12, y1: b.plot.maxY, PanelTheme.red400.withAlpha(0.7))
    }

    // MARK: Speed handles

    struct SpeedHandle: Equatable {
        var side: KeyframeEasing.Side
        /// The key the handle leaves (frame), where its arm ends (frame) and its speed (units per second).
        var keyFrame: Double, endFrame: Double, velocity: Double
    }

    /// The focused segment's out and in handles (a drag in flight shows its own numbers); none for a hold or last key.
    func speedHandles(_ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> [SpeedHandle] {
        guard let f = t.focused, let next = editor.nextKeyframe(f), let sides = KeyframeEasing.sides(editor, f) else { return [] }
        let len = next.frame - f.frame
        var out = (sides.outInfluence, sides.outVelocity), inn = (sides.inInfluence, sides.inVelocity)
        if case .speedHandle(let side, let inf, let vel)? = drag { if side == .out { out = (inf, vel) } else { inn = (inf, vel) } }
        return [SpeedHandle(side: .out, keyFrame: f.frame, endFrame: f.frame + out.0 * len, velocity: out.1),
                SpeedHandle(side: .in, keyFrame: next.frame, endFrame: next.frame - inn.0 * len, velocity: inn.1)]
    }

    func drawSpeedHandle(_ c: CanvasContext, _ b: GraphBox, _ h: SpeedHandle) {
        let a = point(b, frame: h.keyFrame, value: h.velocity), e = point(b, frame: h.endFrame, value: h.velocity)
        var arm = CanvasPath(); arm.move(to: a); arm.line(to: e)
        c.stroke(arm, PanelTheme.text3, StrokeStyle(width: 1))
        let on = hovered == .speedHandle(h.side) || drag.map { if case .speedHandle(h.side, _, _) = $0 { return true }; return false } == true
        let rad = on ? 4.5 : 3.5
        let dot = CanvasPath.roundedRect(CanvasRect(x: e.x - rad, y: e.y - rad, width: 2 * rad, height: 2 * rad), radius: rad)
        c.fill(dot, on ? PanelTheme.text0 : PanelTheme.accent)
        c.stroke(dot, PanelTheme.panelBg, StrokeStyle(width: 1))
        hits.add(CanvasRect(x: e.x - 7, y: e.y - 7, width: 14, height: 14), .speedHandle(h.side))
    }

    /// Influence and velocity under the pointer for a handle drag, from the last draw's mapping.
    func speedHandleValues(_ side: KeyframeEasing.Side, at p: CanvasPoint) -> (influence: Double, velocity: Double)? {
        guard let b = graphBox, let editor, let t = target, let f = t.focused, let next = editor.nextKeyframe(f) else { return nil }
        let frame = b.frames.lowerBound + (p.x - b.plot.x) / max(1, b.plot.width) * (b.frames.upperBound - b.frames.lowerBound)
        let len = max(1, next.frame - f.frame)
        let influence = side == .out ? (frame - f.frame) / len : (next.frame - frame) / len
        let velocity = b.values.lowerBound + (b.plot.maxY - p.y) / max(1, b.plot.height) * (b.values.upperBound - b.values.lowerBound)
        return (min(1, max(KeyframeEase.influenceRange.lowerBound, influence)), max(0, velocity))
    }

    /// ⌘-scroll zooms around the shown range's middle, plain scroll pans; both stay inside the keyed range.
    func scrollGraph(dy: Double, zoom: Bool) {
        if zoom {
            let mid = state.pan + 0.5 / state.zoom
            state.zoom *= dy < 0 ? 1.25 : 0.8
            state.pan = mid - 0.5 / state.zoom
        } else {
            state.pan += dy / 400 / state.zoom
        }
    }
}
