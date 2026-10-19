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
import MpvfxPanels

/// Stage feedback drawn over the composition: the gesture trail, the z-order "crossed" flash, the asset drop
/// target and toasts.
extension PlayerView {
    /// Shows `message` over the stage for a few seconds.
    public func showToast(_ message: String, isError: Bool = false) {
        toast = (message, isError, now())
        requestAnimationFrame?()
    }

    /// Highlights the sibling a bring-forward / send-backward stepped over for 600 ms.
    public func flashZOrderCrossed(_ id: String) {
        zOrderFlash = (id, now())
        requestAnimationFrame?()
    }

    /// Tailwind `animate-pulse` opacity (1 → 0.5 → 1 over 2 s, cubic-bezier(0.4, 0, 0.6, 1)) at `t` seconds.
    static func pulse(_ t: Double) -> Double {
        let k = (t.truncatingRemainder(dividingBy: 2)) / 2
        let half = k < 0.5 ? k * 2 : (1 - k) * 2
        return 1 - 0.5 * ease(half)
    }
    /// cubic-bezier(0.4, 0, 0.6, 1) y for x in 0...1 (bisection on x).
    static func ease(_ x: Double) -> Double {
        func bez(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 { let m = (lo + hi) / 2; if bez(m, 0.4, 0.6) < x { lo = m } else { hi = m } }
        return bez((lo + hi) / 2, 0, 1)
    }

    func drawStageFeedback(_ c: CanvasContext, size: CanvasSize, frame: CanvasRect) {
        let t = now()
        // ZOrderCrossedFlash: border-2 border-studio-accent, square, animate-pulse, over the crossed sibling.
        if let f = zOrderFlash {
            let since = t - f.start
            if since < Self.zOrderFlashSeconds, let e = elements.first(where: { $0.id == f.id }) {
                let ve = chromeElement(e, in: size), a = Self.pulse(since)
                rotated(c, ve) { Self.strokeSquare(c, ve.visibleRect, theme.accent.withAlpha(a), width: 2) }
            } else if since >= Self.zOrderFlashSeconds { zOrderFlash = nil }
        }
        // GestureTrailOverlay (recording): accent polyline, 2px, 60 % opacity, round joins.
        if recordingTrail.count > 1 {
            var p = CanvasPath()
            p.move(to: recordingTrail[0])
            for q in recordingTrail.dropFirst() { p.line(to: q) }
            c.stroke(p, theme.accent.withAlpha(0.6), StrokeStyle(width: 2))
        }
        // Asset drop target: the composition frame outlined while a library/media asset hovers it.
        if assetDropActive {
            Self.fillSquare(c, frame, theme.accent.withAlpha(0.08))
            Self.strokeSquare(c, frame, theme.accent, width: 2)
        }
        drawToast(c, size: size, at: t)
    }

    /// Toast pill centred near the bottom of the viewport: neutral-900 with a neutral-700 border (red-400 text
    /// for errors), 12px text, fading out over its last 200 ms.
    func drawToast(_ c: CanvasContext, size: CanvasSize, at t: Double) {
        guard let m = toast else { return }
        let since = t - m.start
        guard since < Self.toastSeconds else { toast = nil; return }
        let a = since > Self.toastSeconds - Self.hudFadeSeconds ? max(0, (Self.toastSeconds - since) / Self.hudFadeSeconds) : 1
        let v = viewportRect(in: size), font = CanvasFont(size: 12)
        let tw = c.measureText(m.message, font: font).width
        let w = min(v.width - 24, tw + 24), h = 12.0 + 16
        let r = CanvasRect(x: v.x + (v.width - w) / 2, y: v.maxY - 16 - h, width: w, height: h)
        c.fillRoundedRect(r, radius: 8, PanelStyle.neutral900.withAlpha(0.95 * a))
        c.strokeRoundedRect(r.insetBy(0.5), radius: 7.5, (m.isError ? PanelTheme.red500 : PanelStyle.neutral700).withAlpha(a), width: 1)
        let color = m.isError ? PanelTheme.red400 : PanelStyle.neutral200
        c.withState {
            c.clip(r)
            c.drawText(m.message, at: .init(r.x + 12, r.y + 8), font: font, color: color.withAlpha(a))
        }
    }
}
