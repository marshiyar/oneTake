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
import MpvfxTimeline

/// Immediate-mode hit map: a view records each interactive rect while it draws, and pointer events resolve
/// against the regions of the last draw (topmost = last recorded wins).
public struct HitMap<Action> {
    public private(set) var regions: [(rect: CanvasRect, action: Action)] = []
    public init() {}
    public mutating func reset() { regions.removeAll(keepingCapacity: true) }
    public mutating func add(_ rect: CanvasRect, _ action: Action) { regions.append((rect, action)) }
    public func hit(_ p: CanvasPoint) -> Action? { regions.last(where: { $0.rect.contains(p) })?.action }
    public func rect(where match: (Action) -> Bool) -> CanvasRect? { regions.last(where: { match($0.action) })?.rect }
}

/// Horizontal text alignment inside a rect.
public enum PanelAlign: Sendable { case left, center, right }

public enum PanelDraw {
    /// Text placed the way the browser placed it in a line box of height `r.height`: the font's content area (ascent +
    /// descent) centered in the box (half-leading above and below), so the baseline lands where the browser puts
    /// it rather than where a bare em box would. Truncated with an ellipsis to fit the width.
    @discardableResult
    public static func text(_ c: CanvasContext, _ s: String, in r: CanvasRect, font: CanvasFont, color: CanvasColor,
                            align: PanelAlign = .left) -> CanvasSize {
        let t = truncate(c, s, font: font, width: r.width)
        let m = c.measureText(t, font: font)
        let x: Double
        switch align { case .left: x = r.x; case .center: x = r.x + (r.width - m.width) / 2; case .right: x = r.maxX - m.width }
        c.drawText(t, at: CanvasPoint(x, baselineTop(r, font: font, measuredHeight: m.height)), font: font, color: color)
        return m
    }

    /// The `drawText` origin y that puts the baseline where the browser did in line box `r`. Backends draw the
    /// baseline at origin.y + 0.8em.
    ///
    /// On Linux the fonts are the ones Chromium resolves (Liberation Sans / Mono) and the placement is Chromium's
    /// measured one: the baseline sits `A + floor((lineHeight - C) / 2)` below the line box top, with integer
    /// `A`/`C` per font size (rounded font metrics), and the glyph run lands on a whole layout pixel. `r` is the line
    /// box when it is at most ~2 lines tall; a taller rect (a row) holds a centered `1.5` line box, Tailwind's
    /// `text-[Npx]` line height. Elsewhere: the content area (ascent + descent ≈ 1.19em, ascent ≈ 80% of it)
    /// centered in the box. Pango reports that height; Core Text reports the em, hence the floor.
    public static func baselineTop(_ r: CanvasRect, font: CanvasFont, measuredHeight: Double) -> Double {
        #if os(Linux)
        if let (a, cc) = chromiumBaseline(font) {
            let lh = r.height <= font.size * 2.2 ? r.height : font.size * 1.5
            let top = r.y + (r.height - lh) / 2
            let baseline = (top + a + ((lh - cc) / 2).rounded(.down) + 1e-6).rounded()
            return baseline - font.size * 0.8
        }
        #endif
        let content = max(measuredHeight, font.size * 1.19)
        let baseline = r.y + (r.height - content) / 2 + content * 0.8
        return baseline - font.size * 0.8
    }

    /// (A, C) of Chromium's baseline placement for Liberation Sans and Liberation Mono at 8…16px, fitted with zero
    /// error to Chromium renders at line heights 1, 1.25, 1.333, 1.5, 1.75 and 2.
    static func chromiumBaseline(_ f: CanvasFont) -> (Double, Double)? {
        let size = Int(f.size.rounded())
        guard abs(f.size - Double(size)) < 0.01, (8...16).contains(size) else { return nil }
        let mono = f.family.contains("Mono") || f.family.contains("Monospace")
        let sans: [(Double, Double)] = [(2, 0), (3, 0), (3, 1), (3, 0), (4, 0), (5, 1), (5, 0), (5, 1), (5, 0.5)]
        let mon: [(Double, Double)] = [(2, 0), (2, 0), (3, 1), (4, 1), (4, 0), (4, 1), (4, 0), (5, 0), (6, 0.5)]
        return (mono ? mon : sans)[size - 8]
    }

    /// Text with `letter-spacing` (each glyph advanced by its width plus `tracking`), left aligned.
    public static func tracked(_ c: CanvasContext, _ s: String, in r: CanvasRect, font: CanvasFont, tracking: Double, color: CanvasColor) {
        let m = c.measureText(s, font: font)
        let y = baselineTop(r, font: font, measuredHeight: m.height)
        var x = r.x
        for ch in s {
            let g = String(ch)
            c.drawText(g, at: CanvasPoint(x, y), font: font, color: color)
            x += c.measureText(g, font: font).width + tracking
        }
    }

    public static func truncate(_ c: CanvasContext, _ s: String, font: CanvasFont, width: Double) -> String {
        guard width > 0 else { return "" }
        if c.measureText(s, font: font).width <= width { return s }
        let chars = Array(s)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if c.measureText(String(chars[0..<mid]) + "…", font: font).width <= width { lo = mid } else { hi = mid - 1 }
        }
        return lo == 0 ? "" : String(chars[0..<lo]) + "…"
    }

    /// 1px line from (x0,y) to (x1,y), crisp on the pixel grid.
    public static func hline(_ c: CanvasContext, x0: Double, x1: Double, y: Double, _ color: CanvasColor) {
        c.fillRect(CanvasRect(x: x0, y: y, width: x1 - x0, height: 1), color)
    }
    public static func vline(_ c: CanvasContext, x: Double, y0: Double, y1: Double, _ color: CanvasColor) {
        c.fillRect(CanvasRect(x: x, y: y0, width: 1, height: y1 - y0), color)
    }

    /// The studio's keyboard focus ring (`focus-visible:outline-2 outline-studio-accent`): 2px accent drawn just
    /// outside `r`, following its corner radius.
    public static func focusRing(_ c: CanvasContext, _ r: CanvasRect, radius: Double = PanelTheme.radius) {
        c.strokeRoundedRect(r.snapped.insetBy(-1), radius: radius + 1, PanelTheme.accent, width: 2)
    }

    /// Small text button (`px-2 py-0.5 text-[10px] rounded`).
    public static func smallButton(_ c: CanvasContext, _ r: CanvasRect, label: String, fill: CanvasColor?, color: CanvasColor) {
        if let fill { c.fillRoundedRect(r, radius: PanelTheme.radius, fill) }
        text(c, label, in: r, font: PanelTheme.font(10), color: color, align: .center)
    }
}

/// A one-line editable field (CommitField): focus, draft text, Enter commits, Escape reverts, blur commits.
public struct PanelTextField: Equatable {
    public var key: String
    public var draft: String
    public var original: String
    public init(key: String, value: String) { self.key = key; draft = value; original = value }

    public enum Outcome: Equatable { case none, editing, commit(String), cancel }

    /// Handles one key while focused.
    public mutating func key(_ k: EditorKey) -> Outcome {
        switch k.code {
        case .enter: return .commit(draft)
        case .escape: draft = original; return .cancel
        case .backspace, .delete: if !draft.isEmpty { draft.removeLast() }; return .editing
        case .space: draft.append(" "); return .editing
        case .char(let ch) where !k.command && !k.alt: draft.append(ch); return .editing
        case .left, .right, .up, .down, .home, .end: return .editing
        default: return .none
        }
    }
}

/// Deterministic text metrics with no backend (hit-testing before a real draw, and tests on any platform).
/// Width ≈ 0.56em per character (0.6em monospace), height = font size.
public final class PanelMeasureCanvas: CanvasContext {
    public private(set) var texts: [(String, CanvasPoint, CanvasFont, CanvasColor)] = []
    public private(set) var fills: [(CanvasPath, CanvasColor)] = []
    public init() {}
    public func save() {}
    public func restore() {}
    public func translate(_ dx: Double, _ dy: Double) {}
    public func scale(_ sx: Double, _ sy: Double) {}
    public func rotate(_ radians: Double) {}
    public func clip(_ path: CanvasPath) {}
    public func fill(_ path: CanvasPath, _ color: CanvasColor) { fills.append((path, color)) }
    public func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {}
    public func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) { texts.append((text, origin, font, color)) }
    public func measureText(_ text: String, font: CanvasFont) -> CanvasSize {
        CanvasSize(Double(text.count) * font.size * (font.family.contains("Mono") ? 0.6 : 0.56), font.size)
    }
    public func drawImage(_ image: CanvasImage, in rect: CanvasRect) {}
    public func reset() { texts.removeAll(); fills.removeAll() }
    /// All drawn strings (tests).
    public var drawnStrings: [String] { texts.map(\.0) }
}

/// Number formatting shared by the inspector rows (formatTransformValue / toFixed trimming).
public enum PanelFormat {
    public static func number(_ v: Double, decimals: Int = 2) -> String {
        guard v.isFinite else { return "0" }
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s == "-0" ? "0" : s
    }
    public static func seconds(_ v: Double) -> String { String(format: "%.2fs", v) }
    /// Parses user input like "12", "12.5", "50%", "1.5x", "2s"; nil when not a number.
    public static func parse(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in ["px", "%", "x", "s", "°", "db"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        return Double(t.trimmingCharacters(in: .whitespaces))
    }
}

/// The thin overlay scrollbar of the panels' scrolling bodies (a dark-scheme overlay bar):
/// a 6px rounded thumb 2px in from the right edge, neutral-600 at 60% (neutral-500 while hovered or
/// dragged), sized by the visible fraction (24px minimum). Only drawn while the content overflows.
public enum PanelScrollbar {
    public static let width = 6.0, inset = 2.0, minThumb = 24.0
    /// The thumb rect for `offset` within `content` points of which `track.height` are visible; nil when it all fits.
    public static func thumb(track: CanvasRect, offset: Double, content: Double) -> CanvasRect? {
        guard content > track.height + 0.5, track.height > 8 else { return nil }
        let h = max(minThumb, track.height * track.height / content)
        let maxOffset = content - track.height
        let t = maxOffset > 0 ? max(0, min(1, offset / maxOffset)) : 0
        return CanvasRect(x: track.maxX - inset - width, y: track.y + 2 + (track.height - 4 - h) * t, width: width, height: h)
    }
    /// The hit zone (the thumb's column over the whole track).
    public static func zone(track: CanvasRect) -> CanvasRect {
        CanvasRect(x: track.maxX - inset - width - 2, y: track.y, width: width + inset + 2, height: track.height)
    }
    /// The scroll offset that puts the thumb's top at `y` (drag), clamped.
    public static func offset(forThumbTop y: Double, track: CanvasRect, content: Double) -> Double {
        let h = max(minThumb, track.height * track.height / max(content, 1))
        let span = track.height - 4 - h, maxOffset = max(0, content - track.height)
        guard span > 0 else { return 0 }
        return max(0, min(maxOffset, (y - track.y - 2) / span * maxOffset))
    }
    /// `opacity` fades the bar in while scrolling and out at rest (PanelScroller.barOpacity); hovering shows it fully.
    public static func draw(_ c: CanvasContext, track: CanvasRect, offset: Double, content: Double, hovered: Bool, opacity: Double = 1) {
        guard let t = thumb(track: track, offset: offset, content: content) else { return }
        let o = hovered ? 1 : Swift.max(0, Swift.min(1, opacity))
        guard o > 0.001 else { return }
        c.fillRoundedRect(t, radius: width / 2, hovered ? PanelTheme.neutral500.withAlpha(0.8) : PanelTheme.neutral600.withAlpha(0.6 * o))
    }
}

/// Keyboard focus over a panel's hit regions (tab order and a `focus-visible` ring): Tab / ⇧Tab walk
/// the focusable regions in draw order, Enter / Space press the focused one, and the 2px accent ring shows only
/// after keyboard navigation (a pointer press hides it, as `:focus-visible` does).
public struct PanelFocus<H: Equatable> {
    public var current: H?
    public var visible = false
    public init() {}

    /// The focusable actions in draw order, each once.
    public static func order(_ hits: HitMap<H>, _ focusable: (H) -> Bool) -> [H] {
        var out: [H] = []
        for r in hits.regions where r.rect.width > 0 && r.rect.height > 0 && focusable(r.action) && !out.contains(r.action) { out.append(r.action) }
        return out
    }

    /// Moves to the next (or previous) focusable action; returns false at either end (focus leaves the panel).
    @discardableResult
    public mutating func move(_ hits: HitMap<H>, forward: Bool, _ focusable: (H) -> Bool) -> Bool {
        let list = Self.order(hits, focusable)
        guard !list.isEmpty else { current = nil; visible = false; return false }
        visible = true
        guard let cur = current, let i = list.firstIndex(of: cur) else { current = forward ? list.first : list.last; return true }
        let j = forward ? i + 1 : i - 1
        guard list.indices.contains(j) else { current = nil; visible = false; return false }
        current = list[j]
        return true
    }

    /// The focused region while the ring is showing.
    public func ringRect(_ hits: HitMap<H>) -> CanvasRect? {
        guard visible, let cur = current else { return nil }
        return hits.rect(where: { $0 == cur })
    }

    public mutating func pointerPressed() { visible = false }
}

/// One scrolling region of a side panel, with native overflow-scrolling feel.
///
/// Precise deltas (trackpads, including the OS momentum phase) move the content 1:1 in points, never multiplied.
/// Wheel notches arrive as the host's line step (~53pt, Chromium's) and glide to their target with a 140 ms ease-out
/// instead of jumping; notches landing mid-glide add to the target. Both clamp at the ends (a glide eases into the
/// end rather than snapping). Scrolling shows the overlay scrollbar, which fades out after a short rest.
public struct PanelScroller: Equatable {
    public private(set) var offset = 0.0
    /// Where a wheel glide is heading (equals `offset` when idle).
    public private(set) var target = 0.0
    var from = 0.0, elapsed = 0.0
    public private(set) var gliding = false
    /// Seconds since the last scroll (the scrollbar's fade clock).
    public private(set) var idle = Double.infinity
    public static let glideDuration = 0.14
    /// The scrollbar stays fully visible this long after a scroll, then fades out over `fadeDuration`.
    public static let holdDuration = 0.8, fadeDuration = 0.3
    public init() {}

    /// Applies a scroll of `dy` points (positive = toward the end) within 0…`max`. Returns whether anything moved
    /// or a glide started (the host then ticks until `tick` returns false).
    @discardableResult
    public mutating func scroll(by dy: Double, precise: Bool, max: Double) -> Bool {
        guard dy.isFinite, dy != 0 else { return false }
        idle = 0
        let hi = Swift.max(0, max)
        if precise {
            gliding = false
            let next = Swift.min(hi, Swift.max(0, offset + dy))
            let moved = next != offset
            offset = next; target = next
            return moved || true   // the scrollbar still wakes at an end
        }
        let base = gliding ? target : offset
        target = Swift.min(hi, Swift.max(0, base + dy))
        from = offset; elapsed = 0
        gliding = target != offset
        return true
    }

    /// Advances the glide and the scrollbar fade; true while either still needs frames.
    @discardableResult
    public mutating func tick(_ dt: Double) -> Bool {
        let d = Swift.max(0, dt)
        idle += d
        if gliding {
            elapsed += d
            let t = Swift.min(1, elapsed / Self.glideDuration)
            offset = from + (target - from) * InspectorPanel.easeOut(t)
            if t >= 1 { offset = target; gliding = false }
        }
        return gliding || idle < Self.holdDuration + Self.fadeDuration
    }

    /// Jumps (a drag on the thumb, reveal-into-view, a reset): cancels any glide.
    public mutating func set(_ v: Double, max: Double) {
        offset = Swift.min(Swift.max(0, max), Swift.max(0, v)); target = offset; gliding = false
    }

    /// Keeps the offset inside a range that shrank (content got shorter, the pane taller).
    public mutating func clamp(max: Double) {
        let hi = Swift.max(0, max)
        if offset > hi { offset = hi }
        if target > hi { target = hi }
        if !gliding { target = offset }
    }

    /// Wakes the scrollbar without scrolling (the pointer over its track).
    public mutating func wake() { idle = 0 }

    /// The overlay scrollbar's opacity: 1 while scrolling and shortly after, then fading to 0.
    public var barOpacity: Double {
        if idle <= Self.holdDuration { return 1 }
        return Swift.max(0, 1 - (idle - Self.holdDuration) / Self.fadeDuration)
    }
}
