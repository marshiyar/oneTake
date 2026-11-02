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

/// The speed ramp graph as a pure model: points, log-scale layout and drawing.
/// No editor dependency; the host turns actions into editor commands.
public final class SpeedGraph {
    /// Log-scale speed bounds; 1x sits at the geometric middle.
    public static let minSpeed = 0.1
    public static let maxSpeed = 10.0
    /// The graph height in points.
    public static let height = 120.0
    static let padX = 8.0
    static let padTop = 20.0
    static let padBottom = 16.0
    static let hitRadius = 7.0

    public var points: [NativeSpeedRamp.Point]
    public var durationFrames: Double
    public var playheadFrame: Double
    public var focused: Int?
    public var fps: Double
    /// Live drag position while a point is dragged; drawn instead of the point.
    var draggingPreview: NativeSpeedRamp.Point?
    var draggingIndex: Int?
    private(set) var plot = CanvasRect(x: 0, y: 0, width: 0, height: 0)

    public init(points: [NativeSpeedRamp.Point] = [], durationFrames: Double = 0,
                playheadFrame: Double = 0, focused: Int? = nil, fps: Double = 30) {
        self.points = points
        self.durationFrames = durationFrames
        self.playheadFrame = playheadFrame
        self.focused = focused
        self.fps = fps
    }

    /// Y for a speed on the log scale, clamped to the bounds.
    public func y(forSpeed speed: Double) -> Double {
        let v = min(Self.maxSpeed, max(Self.minSpeed, speed.isFinite ? speed : 1))
        let t = (log(v) - log(Self.minSpeed)) / (log(Self.maxSpeed) - log(Self.minSpeed))
        return plot.maxY - t * plot.height
    }

    /// Speed at a y on the log scale, clamped to the bounds.
    public func speed(forY y: Double) -> Double {
        let t = (plot.maxY - y) / max(1, plot.height)
        let v = exp(log(Self.minSpeed) + t * (log(Self.maxSpeed) - log(Self.minSpeed)))
        return min(Self.maxSpeed, max(Self.minSpeed, v))
    }

    /// X for a clip-local frame.
    public func x(forFrame frame: Double) -> Double {
        guard durationFrames > 0 else { return plot.x }
        return plot.x + min(1, max(0, frame / durationFrames)) * plot.width
    }

    /// Clip-local frame at an x.
    public func frame(forX x: Double) -> Double {
        guard plot.width > 0, durationFrames > 0 else { return 0 }
        return min(durationFrames, max(0, (x - plot.x) / plot.width * durationFrames))
    }

    /// Speed of the ramp at a frame, following each segment's ease.
    public func rampSpeed(atFrame frame: Double) -> Double {
        NativeSpeedRamp(points: points).speed(atClipFrame: frame)
    }

    /// Draws the background, grid with the 1x line, curve, points and playhead.
    public func draw(_ c: CanvasContext, in r: CanvasRect) {
        c.fillRoundedRect(r, radius: PanelTheme.radiusMd, PanelTheme.panelBgInset)
        c.strokeRoundedRect(r.insetBy(0.5), radius: PanelTheme.radiusMd, PanelTheme.panelBorder, width: 1)
        plot = CanvasRect(x: r.x + Self.padX, y: r.y + Self.padTop,
                          width: max(1, r.width - 2 * Self.padX),
                          height: max(1, r.height - Self.padTop - Self.padBottom))
        c.withState {
            c.clip(.roundedRect(r, radius: PanelTheme.radiusMd))
            drawGrid(c)
            drawCurve(c)
            drawPoints(c)
            drawPlayhead(c)
        }
        PanelDraw.text(c, "Speed", in: CanvasRect(x: r.x + Self.padX, y: r.y + 3, width: r.width / 2, height: 14),
                       font: PanelTheme.font(9), color: PanelTheme.text2, align: .left)
        PanelDraw.text(c, Self.formatTime(frame: playheadFrame, fps: fps),
                       in: CanvasRect(x: r.midX, y: r.y + 3, width: r.width / 2 - Self.padX, height: 14),
                       font: PanelTheme.mono(9), color: PanelTheme.text2, align: .right)
    }

    /// Gridlines at decade fractions; the 1x line uses text for contrast.
    func drawGrid(_ c: CanvasContext) {
        for s in [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 10.0] {
            let y = y(forSpeed: s)
            let strong = s == 1.0
            PanelDraw.hline(c, x0: plot.x, x1: plot.maxX, y: y, strong ? PanelTheme.text2 : PanelTheme.panelHairline)
            PanelDraw.text(c, Self.formatSpeed(s),
                           in: CanvasRect(x: plot.x, y: y - 13, width: 44, height: 12),
                           font: PanelTheme.mono(9), color: PanelTheme.text2)
        }
    }

    /// Points as drawn, including the live drag preview.
    var effectivePoints: [NativeSpeedRamp.Point] {
        guard let i = draggingIndex, points.indices.contains(i),
              let preview = draggingPreview else { return points }
        var pts = points
        pts[i] = preview
        return pts
    }

    /// The ramp curve, sampled through the same easing as the ramp itself.
    func drawCurve(_ c: CanvasContext) {
        guard durationFrames > 0, !effectivePoints.isEmpty else { return }
        let ramp = NativeSpeedRamp(points: effectivePoints)
        var path = CanvasPath()
        let n = 64
        for i in 0...n {
            let frame = durationFrames * Double(i) / Double(n)
            let p = CanvasPoint(x(forFrame: frame), y(forSpeed: ramp.speed(atClipFrame: frame)))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        c.stroke(path, PanelTheme.accent, StrokeStyle(width: 1.5))
    }

    /// The ramp points as dots; the focused one is filled, others outlined.
    func drawPoints(_ c: CanvasContext) {
        for (i, p) in points.enumerated() {
            let show = (draggingIndex == i ? draggingPreview : nil) ?? p
            let at = CanvasPoint(x(forFrame: show.t), y(forSpeed: show.speed))
            let rad = 3.5
            let dot = CanvasPath.roundedRect(CanvasRect(x: at.x - rad, y: at.y - rad, width: 2 * rad, height: 2 * rad), radius: rad)
            if focused == i {
                c.fill(dot, PanelTheme.accent)
            } else {
                c.stroke(dot, PanelTheme.text2, StrokeStyle(width: 1))
            }
        }
        let drawn = effectivePoints
        if let f = focused, drawn.indices.contains(f) {
            let at = CanvasPoint(x(forFrame: drawn[f].t), y(forSpeed: drawn[f].speed))
            PanelDraw.focusRing(c, CanvasRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10), radius: 5)
        }
    }

    /// The playhead line.
    func drawPlayhead(_ c: CanvasContext) {
        PanelDraw.vline(c, x: x(forFrame: playheadFrame), y0: plot.y, y1: plot.maxY, PanelTheme.red400.withAlpha(0.7))
    }

    /// Index of the point within hit distance of `p`; nil when none.
    public func hitPoint(at p: CanvasPoint) -> Int? {
        var best: Int?
        var bestDist = Self.hitRadius
        for (i, q) in points.enumerated() {
            let at = CanvasPoint(x(forFrame: q.t), y(forSpeed: q.speed))
            let d = hypot(p.x - at.x, p.y - at.y)
            if d <= bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// A speed like "0.25×" or "2×".
    public static func formatSpeed(_ v: Double) -> String {
        "\(PanelFormat.number(v, decimals: 2))×"
    }

    /// A frame count as MM:SS:FF timecode at `fps`.
    public static func formatTime(frame: Double, fps: Double) -> String {
        let base = max(1, Int(max(1, fps).rounded()))
        let total = max(0, Int(frame.rounded()))
        let sec = total / base
        return String(format: "%02d:%02d:%02d", sec / 60, sec % 60, total % base)
    }

    /// Updates the model the same way the host will after the editor accepts it.
    public func apply(_ action: SpeedGraphAction) {
        switch action {
        case .addPoint(let t, let speed):
            let snapped = clampedFrame(t)
            if let existing = points.firstIndex(where: { $0.t == snapped }) {
                focused = existing
                return
            }
            let p = NativeSpeedRamp.Point(t: snapped, speed: clampedSpeed(speed))
            points.append(p)
            points.sort { $0.t < $1.t }
            focused = points.firstIndex(of: p)
        case .movePoint(let index, let t, let speed):
            guard points.indices.contains(index) else { return }
            let lo = index > 0 ? points[index - 1].t + 1 : 0
            let hi = index < points.count - 1 ? points[index + 1].t - 1 : durationFrames
            guard lo <= hi else { return }
            points[index].t = min(hi, max(lo, clampedFrame(t)))
            points[index].speed = clampedSpeed(speed)
            focused = index
        case .removePoint(let index):
            guard points.indices.contains(index), points.count > 1 else { return }
            points.remove(at: index)
            if let f = focused {
                focused = min(f, points.count - 1)
                if index < f { focused = f - 1 }
            }
        case .focusPoint(let index):
            focused = index.flatMap { points.indices.contains($0) ? $0 : nil }
        case .setShape(let shape):
            points = shape.points(durationFrames: durationFrames)
            focused = nil
        case .setEase(let index, let ease):
            guard points.indices.contains(index) else { return }
            points[index].ease = ease
        }
    }

    /// A frame snapped to whole frames inside the clip.
    func clampedFrame(_ t: Double) -> Double {
        guard t.isFinite else { return 0 }
        return min(durationFrames, max(0, t.rounded()))
    }

    /// A speed inside the graph bounds.
    func clampedSpeed(_ s: Double) -> Double {
        guard s.isFinite else { return 1 }
        return min(Self.maxSpeed, max(Self.minSpeed, s))
    }
}
