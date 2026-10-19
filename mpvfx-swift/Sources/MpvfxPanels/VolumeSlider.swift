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

/// Volume control: mute button (h-7 w-7, 13px speaker icon) with a 48px range slider that slides
/// open to its left on hover/focus (w-0 → w-14, 150ms ease-out).
public final class VolumeSlider {
    public static let buttonSize = 28.0, expandedWidth = 56.0, trackWidth = 48.0

    public var volume: Double = 1      // 0...1
    public var muted = false
    public var disabled = false
    public var hovered = false
    public var buttonHovered = false
    /// 0 (collapsed) … 1 (open); advanced by `tick`.
    public private(set) var reveal = 0.0
    public var onChange: ((_ volume: Double, _ muted: Bool) -> Void)?
    private var dragging = false

    public init(volume: Double = 1, muted: Bool = false) { self.volume = volume; self.muted = muted }

    public var silent: Bool { muted || volume == 0 }
    public var percentage: Int { Int((volume * 100).rounded()) }
    public var muteLabel: String { silent ? "Unmute audio" : "Mute audio" }

    /// Whole control width at the current reveal, right-aligned to `right`.
    public func width() -> Double { Self.buttonSize + Self.expandedWidth * reveal }
    public func frame(right: Double, y: Double) -> CanvasRect { CanvasRect(x: right - width(), y: y, width: width(), height: Self.buttonSize) }
    public func buttonRect(_ f: CanvasRect) -> CanvasRect { CanvasRect(x: f.maxX - Self.buttonSize, y: f.y, width: Self.buttonSize, height: Self.buttonSize) }
    public func trackRect(_ f: CanvasRect) -> CanvasRect {
        // mx-1 inside the 56px slot.
        CanvasRect(x: f.x + 4, y: f.y + f.height / 2 - 1, width: Self.trackWidth, height: 2)
    }

    /// Animates the reveal; returns true while still animating.
    public func tick(_ dt: Double) -> Bool {
        let target = (hovered || dragging) ? 1.0 : 0.0
        let step = dt / 0.15
        reveal = target > reveal ? min(target, reveal + step) : max(target, reveal - step)
        return reveal != target
    }

    public func setVolume(_ v: Double) {
        volume = (min(1, max(0, v)) * 100).rounded() / 100
        if muted && volume > 0 { muted = false }
        onChange?(volume, muted)
    }

    public func toggleMute() {
        let wasSilent = silent
        if wasSilent && volume == 0 { volume = 1 }
        muted = !wasSilent
        onChange?(volume, muted)
    }

    @discardableResult
    public func pointerDown(_ p: CanvasPoint, frame f: CanvasRect) -> Bool {
        guard !disabled, f.contains(p) else { return false }
        if buttonRect(f).contains(p) { toggleMute(); return true }
        if reveal > 0.5 { dragging = true; scrub(p, frame: f); return true }
        return false
    }
    public func pointerDrag(_ p: CanvasPoint, frame f: CanvasRect) { if dragging { scrub(p, frame: f) } }
    public func pointerUp() { dragging = false }
    private func scrub(_ p: CanvasPoint, frame f: CanvasRect) {
        let t = trackRect(f); setVolume((p.x - t.x) / t.width)
    }

    public func draw(_ c: CanvasContext, frame f: CanvasRect) {
        if reveal > 0 {
            c.withState {
                c.clip(CanvasRect(x: f.x, y: f.y, width: Self.expandedWidth * reveal, height: f.height))
                let t = trackRect(f)
                let a = reveal
                c.fillRoundedRect(t, radius: 1, PanelStyle.neutral700.withAlpha(a))
                c.fillRoundedRect(CanvasRect(x: t.x, y: t.y, width: t.width * Double(percentage) / 100, height: t.height), radius: 1, PanelStyle.neutral300.withAlpha(a))
                // Native range thumb (hf-preview-volume-range): 10px light knob.
                let kx = t.x + t.width * Double(percentage) / 100
                c.fill(.roundedRect(CanvasRect(x: kx - 5, y: t.y + 1 - 5, width: 10, height: 10), radius: 5), PanelStyle.neutral200.withAlpha(a))
            }
        }
        let b = buttonRect(f)
        let color: CanvasColor = disabled ? PanelStyle.neutral500.withAlpha(0.3)
            : silent ? PanelStyle.accent : (buttonHovered ? PanelStyle.neutral200 : PanelStyle.neutral500)
        Self.drawIcon(c, center: CanvasPoint(b.x + b.width / 2, b.y + b.height / 2), silent: silent, volume: volume, color: color)
    }

    /// The 24-unit lucide speaker glyph scaled to 13px, stroke 2.
    public static func drawIcon(_ c: CanvasContext, center: CanvasPoint, silent: Bool, volume: Double, color: CanvasColor) {
        let s = 13.0 / 24.0
        func P(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(center.x + (x - 12) * s, center.y + (y - 12) * s) }
        let style = StrokeStyle(width: 2 * s)
        var body = CanvasPath()
        body.move(to: P(11, 5)); body.line(to: P(6, 9)); body.line(to: P(3, 9)); body.line(to: P(3, 15))
        body.line(to: P(6, 15)); body.line(to: P(11, 19)); body.close()
        c.stroke(body, color, style)
        if silent {
            var x = CanvasPath(); x.move(to: P(19, 9)); x.line(to: P(13, 15)); x.move(to: P(13, 9)); x.line(to: P(19, 15))
            c.stroke(x, color, style)
        } else {
            c.stroke(arc(center: P(12, 12), radius: 5 * s, from: -.pi / 4, to: .pi / 4), color, style)
            if volume >= 0.5 { c.stroke(arc(center: P(12, 12), radius: 9 * s, from: -.pi / 4, to: .pi / 4), color, style) }
        }
    }

    static func arc(center: CanvasPoint, radius: Double, from a0: Double, to a1: Double) -> CanvasPath {
        var p = CanvasPath(); let n = 12
        for i in 0...n {
            let a = a0 + (a1 - a0) * Double(i) / Double(n)
            let pt = CanvasPoint(center.x + radius * cos(a), center.y + radius * sin(a))
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        return p
    }
}
