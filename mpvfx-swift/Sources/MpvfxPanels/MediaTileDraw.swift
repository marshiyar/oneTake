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

/// A tile name broken into lines: words stay whole where they fit, a word wider than the line breaks by
/// character, and the last line ends with "…" when text is left over.
public enum MediaTileText {
    public static func lines(_ c: CanvasContext, _ s: String, font: CanvasFont, width: Double, maxLines: Int) -> (lines: [String], truncated: Bool) {
        guard width > 0, maxLines > 0 else { return ([], !s.isEmpty) }
        var out: [String] = [], rest = Substring(s)
        while !rest.isEmpty, out.count < maxLines - 1 {
            let n = fitCount(c, rest, font: font, width: width)
            out.append(String(rest.prefix(n)).trimmingCharacters(in: .whitespaces))
            rest = rest.dropFirst(n).drop { $0 == " " }
        }
        guard !rest.isEmpty else { return (out, false) }
        let last = PanelDraw.truncate(c, String(rest), font: font, width: width)
        return (out + [last], last != String(rest))
    }

    /// How many leading characters of `s` go on one line: the most that fit, cut back to just after the last
    /// space, hyphen or underscore among them when there is one.
    static func fitCount(_ c: CanvasContext, _ s: Substring, font: CanvasFont, width: Double) -> Int {
        let chars = Array(s)
        var lo = 1, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if c.measureText(String(chars[0..<mid]), font: font).width <= width { lo = mid } else { hi = mid - 1 }
        }
        guard lo < chars.count, let brk = chars[0..<lo].lastIndex(where: { " -_".contains($0) }), brk > 0 else { return lo }
        return brk + 1
    }
}

/// Drawing pieces of a Media tile: the fill rectangle, the badges and the audio level bars.
public enum MediaTileDraw {
    /// The rectangle that covers `tile` with a picture of `image` size, centred (the overflow is clipped).
    public static func fill(_ image: CanvasSize, in tile: CanvasRect) -> CanvasRect {
        let ia = image.width / max(1, image.height), ta = tile.width / max(1, tile.height)
        let w = ia > ta ? tile.height * ia : tile.width, h = ia > ta ? tile.height : tile.width / ia
        return CanvasRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h)
    }

    static func glyph(kind: String) -> PanelIcon {
        switch kind {
        case "video": return .film
        case "image", "images": return .image
        case "audio": return .music
        case "font", "fonts": return .font
        default: return .film
        }
    }

    static var badgeFont: CanvasFont { PanelTheme.font(10, .medium) }

    /// A text badge on the frame (dark wash, `color` text) with its top-left corner at (left, top).
    static func badge(_ c: CanvasContext, _ s: String, left: Double, top: Double, color: CanvasColor = PanelTheme.text1) {
        let w = c.measureText(s, font: badgeFont).width + 10
        let b = CanvasRect(x: left, y: top, width: w, height: MediaPanelMetrics.badgeHeight)
        c.fillRoundedRect(b, radius: PanelTheme.radius, PanelTheme.neutral950.withAlpha(0.8))
        // One point of slack: a rect exactly as wide as the measured text would end-truncate it on rounding.
        PanelDraw.text(c, s, in: CanvasRect(x: b.x + 5, y: b.y, width: w - 9, height: b.height), font: badgeFont, color: color)
    }

    /// The same badge anchored at its bottom-right corner.
    static func badge(_ c: CanvasContext, _ s: String, right: Double, bottom: Double) {
        let w = c.measureText(s, font: badgeFont).width + 10
        badge(c, s, left: right - w, top: bottom - MediaPanelMetrics.badgeHeight)
    }

    /// "In the timeline": a check on the dark wash, the quietest mark that still tells used from unused at a glance.
    static func checkBadge(_ c: CanvasContext, at p: CanvasPoint) {
        let h = MediaPanelMetrics.badgeHeight, b = CanvasRect(x: p.x, y: p.y, width: h, height: h)
        c.fillRoundedRect(b, radius: PanelTheme.radius, PanelTheme.neutral950.withAlpha(0.8))
        PanelIcon.check.draw(c, in: b.insetBy(3), color: PanelTheme.text1)
    }

    /// Level bars (0…1), at least 10% tall, 2 pt apart, in the accent's line colour.
    static func levels(_ c: CanvasContext, _ levels: [Double], in strip: CanvasRect) {
        guard strip.width > 8, !levels.isEmpty else { return }
        let gap = 2.0, bw = max(0.5, (strip.width - gap * Double(levels.count - 1)) / Double(levels.count))
        for (i, v) in levels.enumerated() {
            let lv = max(0, min(1, v)), bh = strip.height * max(0.1, lv)
            c.fillRoundedRect(CanvasRect(x: strip.x + Double(i) * (bw + gap), y: strip.maxY - bh, width: bw, height: bh), radius: 1,
                              PanelTheme.mint.withAlpha(0.5 + lv * 0.5))
        }
    }
}
