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
import MpvfxScopes
import MpvfxTheme

/// Draws one scope tile: black ground, caption, the trace bitmap, and the graticule as vectors over it (crisp at any
/// scale): level lines and labels in the chosen scale, clipping marks, vectorscope targets and skin-tone line.
struct ScopeTile {
    static let captionHeight = 14.0, gutter = 22.0

    let kind: ScopeKind
    let rect: CanvasRect
    let result: ScopeResult?
    let settings: ScopeSettings

    func draw(_ c: CanvasContext) {
        let r = rect
        c.fillRect(r, PanelTheme.stageScrim)
        c.withState {
            c.clip(r)
            switch kind {
            case .waveform, .overlay, .parade: drawWaveform(c)
            case .vectorscope: drawVectorscope(c)
            case .histogram: ScopeHistogram.draw(c, in: Self.plotRect(r), result: result, settings: settings)
            case .falseColor: drawFalseColor(c)
            }
            caption(c)
        }
        c.strokeRect(r.insetBy(0.5), PanelTheme.panelHairline, width: 1)
    }

    /// Where `kind`'s trace bitmap is drawn in tile `r`; nil for scopes drawn without one (histogram, false colour).
    static func tracePlot(_ kind: ScopeKind, _ r: CanvasRect) -> CanvasRect? {
        switch kind {
        case .waveform, .overlay, .parade: return plotRect(r)
        case .vectorscope: return vectorPlot(r)
        case .histogram, .falseColor: return nil
        }
    }

    /// The trace area of waveform-like tiles: a label gutter on the left, the caption above. On whole points, so the
    /// device-sized trace lands pixel for pixel at 1x and 2x.
    static func plotRect(_ r: CanvasRect) -> CanvasRect {
        let x = (r.x + gutter).rounded(), y = (r.y + captionHeight + 4).rounded()
        return CanvasRect(x: x, y: y, width: (r.maxX - 6 - x).rounded(.down), height: (r.maxY - 6 - y).rounded(.down))
    }

    func caption(_ c: CanvasContext) {
        let r = rect
        var text = kind.title
        if kind == .vectorscope { text += " · \(Int(settings.targetAmplitude * 100))%" + (settings.zoom > 1 ? " · \(Int(settings.zoom))x" : "") }
        PanelDraw.text(c, text, in: CanvasRect(x: r.x + 6, y: r.y + 2, width: r.width - 12, height: 12), font: PanelTheme.font(8),
                       color: PanelTheme.scopeInk.withAlpha(0.6))
    }

    // MARK: Waveform, RGB overlay, parade

    func drawWaveform(_ c: CanvasContext) {
        let plot = Self.plotRect(rect)
        if let image = result?.traces[kind] { c.drawImage(image, in: plot) }
        Self.levelLines(c, plot, scale: settings.scale)
        guard let a = result?.analysis else { return }
        if kind == .parade {
            let pixels = result?.traces[kind]?.width ?? Int(plot.width), total = Double(max(1, pixels))
            for (i, ch) in [ScopeChannel.red, .green, .blue].enumerated() {
                let lane = ScopeTraces.paradeLanes(width: pixels)[i]
                let lr = CanvasRect(x: plot.x + Double(lane.lowerBound) / total * plot.width, y: plot.y,
                                    width: Double(lane.count) / total * plot.width, height: plot.height)
                Self.clipMarks(c, a, [ch], in: lr)
                PanelDraw.text(c, ["R", "G", "B"][i], in: CanvasRect(x: lr.x + 2, y: lr.y + 1, width: 10, height: 11),
                               font: PanelTheme.font(8), color: PanelTheme.scopeInk.withAlpha(0.45))
            }
        } else {
            Self.clipMarks(c, a, kind == .waveform ? [.luma] : [.red, .green, .blue], in: plot)
        }
    }

    /// Horizontal lines at the scale's levels, major ones stronger, labels in the left gutter.
    static func levelLines(_ c: CanvasContext, _ plot: CanvasRect, scale: ScopeScale) {
        for line in scale.lines {
            let y = (plot.maxY - line.value * plot.height).rounded()
            c.fillRect(CanvasRect(x: plot.x, y: y - 0.5, width: plot.width, height: 1),
                       PanelTheme.scopeInk.withAlpha(line.major ? 0.32 : 0.12))
            if let label = line.label {
                PanelDraw.text(c, label, in: CanvasRect(x: plot.x - gutter, y: y - 6, width: gutter - 3, height: 12),
                               font: PanelTheme.font(8), color: PanelTheme.scopeInk.withAlpha(0.5), align: .right)
            }
        }
    }

    /// A short mark above the plot over every column holding level-255 samples, and below for level 0.
    static func clipMarks(_ c: CanvasContext, _ a: ScopeAnalysis, _ channels: [ScopeChannel], in plot: CanvasRect) {
        let w = plot.width / Double(max(1, a.columns))
        for col in 0..<a.columns {
            let clips = channels.map { a.columnClips($0, column: col) }
            let x = plot.x + Double(col) * w
            if clips.contains(where: \.high) { c.fillRect(CanvasRect(x: x, y: plot.y - 3, width: max(1, w), height: 2), PanelTheme.scopeClip) }
            if clips.contains(where: \.low) { c.fillRect(CanvasRect(x: x, y: plot.maxY + 1, width: max(1, w), height: 2), PanelTheme.scopeClip) }
        }
    }

    // MARK: Vectorscope

    /// The square plot, centred under the caption.
    static func vectorPlot(_ r: CanvasRect) -> CanvasRect {
        let side = max(1, min(r.width - 8, r.height - captionHeight - 6).rounded(.down))
        return CanvasRect(x: (r.midX - side / 2).rounded(), y: (r.y + captionHeight + 2).rounded(), width: side, height: side)
    }

    func drawVectorscope(_ c: CanvasContext) {
        let r = rect, plot = Self.vectorPlot(r), zoom = settings.zoom
        if let image = result?.traces[.vectorscope] { c.drawImage(image, in: plot) }
        let ink = PanelTheme.scopeInk
        c.fillRect(CanvasRect(x: plot.x, y: plot.midY - 0.5, width: plot.width, height: 1), ink.withAlpha(0.12))
        c.fillRect(CanvasRect(x: plot.midX - 0.5, y: plot.y, width: 1, height: plot.height), ink.withAlpha(0.12))
        c.stroke(Self.circle(center: CanvasPoint(plot.midX, plot.midY), radius: 0.5 * zoom * plot.width), ink.withAlpha(0.22), StrokeStyle(width: 1))
        Self.skinLine(c, plot, settings: settings)
        for t in ScopeTargets.bars(settings.matrix, amplitude: settings.targetAmplitude) { Self.target(c, t, plot, zoom: zoom) }
        if let a = result?.analysis, a.vectorOutside > 0 {
            let share = Double(a.vectorOutside) / Double(max(1, a.samples)) * 100
            PanelDraw.text(c, String(format: "%.0f%% off scale", share), in: CanvasRect(x: r.x + 6, y: r.maxY - 14, width: r.width - 12, height: 12),
                           font: PanelTheme.font(8), color: PanelTheme.scopeClip, align: .right)
        }
    }

    /// The +I axis from the centre to the 0.5 ring (or the plot's corner when zoomed past it).
    static func skinLine(_ c: CanvasContext, _ plot: CanvasRect, settings: ScopeSettings) {
        let angle = ScopeTargets.skinToneAngle(settings.matrix), len = min(0.5 * settings.zoom, 0.71) * plot.width
        var p = CanvasPath()
        p.move(to: CanvasPoint(plot.midX, plot.midY))
        p.line(to: CanvasPoint(plot.midX + cos(angle) * len, plot.midY - sin(angle) * len))
        c.stroke(p, PanelTheme.scopeSkin.withAlpha(0.7), StrokeStyle(width: 1))
    }

    /// A target box with its letter, where that bar lands (skipped when zoomed off the plot).
    static func target(_ c: CanvasContext, _ t: ScopeTarget, _ plot: CanvasRect, zoom: Double) {
        let p = ScopeGeometry.vectorPoint(cb: t.cb, cr: t.cr, zoom: zoom)
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
        let x = plot.x + p.x * plot.width, y = plot.y + p.y * plot.height, box = max(5, plot.width * 0.035)
        c.strokeRect(CanvasRect(x: x - box / 2, y: y - box / 2, width: box, height: box), PanelTheme.scopeInk.withAlpha(0.55), width: 1)
        let dx = p.x < 0.5 ? -box / 2 - 13 : box / 2 + 2
        PanelDraw.text(c, t.name, in: CanvasRect(x: x + dx, y: y - 6, width: 12, height: 12), font: PanelTheme.font(8),
                       color: PanelTheme.scopeInk.withAlpha(0.6), align: p.x < 0.5 ? .right : .left)
    }

    static func circle(center: CanvasPoint, radius: Double) -> CanvasPath {
        // Four cubic quarter-arcs; 0.5523 r is the control distance that keeps each within 0.03 % of the circle.
        let k = 0.5522847498 * radius
        var p = CanvasPath()
        let (x, y) = (center.x, center.y)
        p.move(to: CanvasPoint(x + radius, y))
        p.curve(to: CanvasPoint(x, y + radius), c1: CanvasPoint(x + radius, y + k), c2: CanvasPoint(x + k, y + radius))
        p.curve(to: CanvasPoint(x - radius, y), c1: CanvasPoint(x - k, y + radius), c2: CanvasPoint(x - radius, y + k))
        p.curve(to: CanvasPoint(x, y - radius), c1: CanvasPoint(x - radius, y - k), c2: CanvasPoint(x - k, y - radius))
        p.curve(to: CanvasPoint(x + radius, y), c1: CanvasPoint(x + k, y - radius), c2: CanvasPoint(x + radius, y - k))
        p.close()
        return p
    }

    // MARK: False colour

    /// The false-colour picture fitted under the caption, and the band legend as a level bar on the right.
    func drawFalseColor(_ c: CanvasContext) {
        let r = rect
        let legend = CanvasRect(x: r.maxX - 10, y: r.y + Self.captionHeight + 4, width: 5, height: r.height - Self.captionHeight - 10)
        let area = CanvasRect(x: r.x + 6, y: legend.y, width: legend.x - r.x - 12, height: legend.height)
        if let image = result?.traces[.falseColor] {
            c.drawImage(image, in: InspectorPanel.containRect(image.width, image.height, in: area))
        }
        for level in stride(from: 0, to: 256, by: 4) {
            let v = Double(level) / 255, band = FalseColor.band(forLuma: v)
            let colour = band.map { CanvasColor.rgba(Int($0.red), Int($0.green), Int($0.blue)) } ?? CanvasColor(r: v, g: v, b: v)
            let y = legend.maxY - (Double(level) + 4) / 256 * legend.height
            c.fillRect(CanvasRect(x: legend.x, y: y, width: legend.width, height: legend.height * 4 / 256 + 0.5), colour)
        }
    }
}
