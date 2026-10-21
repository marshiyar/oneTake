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

/// The histogram tile: R, G and B as filled areas, luma as a line, level on the horizontal axis in the chosen scale.
/// Heights are linear in the count, scaled to the tallest bin between the two extremes (a pile of clipped or crushed
/// pixels would otherwise flatten everything else); the clipped and crushed shares are written out instead.
enum ScopeHistogram {
    static func draw(_ c: CanvasContext, in plot: CanvasRect, result: ScopeResult?, settings: ScopeSettings) {
        levelLines(c, plot, scale: settings.scale)
        guard let a = result?.analysis, a.samples > 0 else { return }
        let axes = Axes(plot: plot, peak: peakCount(a), gain: settings.gain)
        let channels: [(ScopeChannel, ThemeColor)] = [(.red, ThemeTokens.scopeRed), (.green, ThemeTokens.scopeGreen),
                                                       (.blue, ThemeTokens.scopeBlue)]
        for (ch, colour) in channels {
            c.fill(axes.curve(a, ch, closed: true), CanvasColor(colour).withAlpha(0.22))
            c.stroke(axes.curve(a, ch, closed: false), CanvasColor(colour).withAlpha(0.8), StrokeStyle(width: 1))
        }
        c.stroke(axes.curve(a, .luma, closed: false), CanvasColor(ThemeTokens.scopeLuma), StrokeStyle(width: 1))
        clipShares(c, a, plot)
    }

    /// The tallest bin of levels 1...254 over every plane (at least 1).
    static func peakCount(_ a: ScopeAnalysis) -> Double {
        var peak: UInt32 = 1
        for ch in ScopeChannel.allCases { for level in 1..<255 { peak = max(peak, a.histogram(ch, level: level)) } }
        return Double(peak)
    }

    /// Level across, count up: `gain x count / peak` of the plot's height, clamped to the top.
    struct Axes {
        let plot: CanvasRect, peak: Double, gain: Double

        func curve(_ a: ScopeAnalysis, _ ch: ScopeChannel, closed: Bool) -> CanvasPath {
            var p = CanvasPath()
            if closed { p.move(to: CanvasPoint(plot.x, plot.maxY)) }
            for level in 0..<256 {
                let h = min(1, gain * Double(a.histogram(ch, level: level)) / peak) * plot.height
                let pt = CanvasPoint(plot.x + (Double(level) + 0.5) / 256 * plot.width, plot.maxY - h)
                if level == 0 && !closed { p.move(to: pt) } else { p.line(to: pt) }
            }
            if closed { p.line(to: CanvasPoint(plot.maxX, plot.maxY)); p.close() }
            return p
        }
    }

    /// Vertical lines at the scale's levels with their labels along the bottom.
    static func levelLines(_ c: CanvasContext, _ plot: CanvasRect, scale: ScopeScale) {
        for line in scale.lines {
            let x = (plot.x + line.value * plot.width).rounded()
            c.fillRect(CanvasRect(x: x - 0.5, y: plot.y, width: 1, height: plot.height), PanelTheme.scopeInk.withAlpha(line.major ? 0.28 : 0.1))
            if let label = line.label {
                PanelDraw.text(c, label, in: CanvasRect(x: x - 14, y: plot.maxY - 11, width: 28, height: 11), font: PanelTheme.font(8),
                               color: PanelTheme.scopeInk.withAlpha(0.45), align: .center)
            }
        }
    }

    /// "crush 1.2 %  clip 0.4 %": the luma shares at level 0 and 255, when there are any.
    static func clipShares(_ c: CanvasContext, _ a: ScopeAnalysis, _ plot: CanvasRect) {
        let clipped = a.clipped(.luma), n = Double(max(1, a.samples))
        var parts: [String] = []
        if clipped.low > 0 { parts.append(String(format: "crush %.1f%%", Double(clipped.low) / n * 100)) }
        if clipped.high > 0 { parts.append(String(format: "clip %.1f%%", Double(clipped.high) / n * 100)) }
        guard !parts.isEmpty else { return }
        PanelDraw.text(c, parts.joined(separator: "  "), in: CanvasRect(x: plot.x, y: plot.y - 16, width: plot.width, height: 12),
                       font: PanelTheme.font(8), color: PanelTheme.scopeClip, align: .right)
    }
}
