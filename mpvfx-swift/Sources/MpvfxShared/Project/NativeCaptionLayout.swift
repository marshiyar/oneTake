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
// Where a caption's lines land in a frame (`NativeCaptionLook`): wrapped at the look's maximum width, at most two lines before
// the lane warns (a longer cue is still shown whole, never shrunk), and kept inside the safe area. Pure: the caller measures
// text, so the preview, the lane's warning and the tests all use one layout. All lengths are canvas px.
import Foundation

public struct NativeCaptionRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    /// True when `other` lies inside this rectangle (touching its edges counts).
    public func contains(_ other: NativeCaptionRect, tolerance: Double = 1e-6) -> Bool {
        other.x >= x - tolerance && other.y >= y - tolerance && other.maxX <= maxX + tolerance && other.maxY <= maxY + tolerance
    }
}

public struct NativeCaptionLayout: Equatable, Sendable {
    /// The wrapped lines, top to bottom.
    public var lines: [String]
    /// Font size in px (`size` times the frame's short edge).
    public var fontSize: Double
    public var lineHeight: Double
    /// The block the lines fill, centred text; the widest line wide.
    public var textRect: NativeCaptionRect
    /// The box behind the text, when the look has a plate.
    public var plateRect: NativeCaptionRect?
    /// What the layout stays inside: the frame less the safe-area margin.
    public var safeRect: NativeCaptionRect
    /// More lines than `NativeCaptionLook.maxLines`: the lane shows a warning; the text is still laid out whole.
    public var overflowsLines: Bool
    /// How far outlines and the shadow reach past the letters, px.
    public var reach: Double
    /// The outer box (plate, or text) with the reach of outlines and shadow added: what must fit in the safe area.
    public var paintedRect: NativeCaptionRect {
        let box = plateRect ?? textRect
        return NativeCaptionRect(x: box.x - reach, y: box.y - reach, width: box.width + 2 * reach, height: box.height + 2 * reach)
    }
}

/// Lays out `text` in a frame of `frameWidth` × `frameHeight`. `measure(text, fontSize)` returns the width in px of one line.
/// A cue's own `position` wins over the look's. With no look, the defaults of `NativeCaptionLook` apply.
public func nativeCaptionLayout(text: String, look: NativeCaptionLook?, position: NativeCaptionPosition?,
                                frameWidth: Double, frameHeight: Double,
                                measure: (String, Double) -> Double) -> NativeCaptionLayout {
    let look = look?.isSupported == false ? nil : look
    let resolved = look ?? NativeCaptionLook()
    let width = max(1, frameWidth), height = max(1, frameHeight)
    let short = min(width, height)
    let fontSize = max(1, resolved.resolvedSize * short)
    let lineHeight = fontSize * NativeClipText.normalLineHeight
    let pad = resolved.plate.map { $0.resolvedPadding * fontSize } ?? 0
    // Outline and shadow widths are px of a 1080 px short edge; they scale with the frame like everything else.
    let unit = short / 1080
    let outline = (resolved.outlines ?? []).reduce(0) { $0 + max(0, $1.width) } * unit
    let shadow = resolved.shadow.map { max(abs($0.resolvedX), abs($0.resolvedY)) + max(0, $0.resolvedBlur) } ?? 0
    let reach = max(outline, shadow * unit)

    let margin = resolved.resolvedSafeArea * short
    let safe = NativeCaptionRect(x: margin, y: margin, width: max(1, width - 2 * margin), height: max(1, height - 2 * margin))
    let usable = NativeCaptionRect(x: safe.x + reach, y: safe.y + reach,
                                   width: max(1, safe.width - 2 * reach), height: max(1, safe.height - 2 * reach))
    let lineLimit = max(fontSize, min(resolved.resolvedMaxWidth * width, usable.width) - 2 * pad)

    var lines: [String] = []
    for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
        lines.append(contentsOf: wrapCaptionParagraph(String(paragraph), limit: lineLimit, fontSize: fontSize, measure: measure))
    }
    if lines.isEmpty { lines = [""] }
    let textWidth = lines.map { measure($0, fontSize) }.max() ?? 0
    let textHeight = Double(lines.count) * lineHeight
    let outerWidth = textWidth + 2 * pad, outerHeight = textHeight + 2 * pad

    let place = (position ?? resolved.resolvedPosition)
    func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { hi < lo ? lo : min(max(v, lo), hi) }
    let centreX = place.place == "custom" ? (place.x ?? 0.5) * width : width / 2
    let x = clamp(centreX - outerWidth / 2, usable.x, usable.maxX - outerWidth)
    let wantedY: Double
    switch place.place {
    case "top": wantedY = usable.y
    case "custom": wantedY = (place.y ?? 0.5) * height - outerHeight / 2
    default: wantedY = usable.maxY - outerHeight
    }
    let y = clamp(wantedY, usable.y, usable.maxY - outerHeight)
    let outer = NativeCaptionRect(x: x, y: y, width: outerWidth, height: outerHeight)
    let textRect = NativeCaptionRect(x: x + pad, y: y + pad, width: textWidth, height: textHeight)
    return NativeCaptionLayout(lines: lines, fontSize: fontSize, lineHeight: lineHeight, textRect: textRect,
                               plateRect: resolved.plate == nil ? nil : outer, safeRect: safe,
                               overflowsLines: lines.count > NativeCaptionLook.maxLines, reach: reach)
}

/// One paragraph wrapped greedily at word boundaries; a word wider than `limit` is split between characters.
private func wrapCaptionParagraph(_ paragraph: String, limit: Double, fontSize: Double, measure: (String, Double) -> Double) -> [String] {
    var lines: [String] = []
    var current = ""
    func fits(_ s: String) -> Bool { measure(s, fontSize) <= limit + 1e-9 }
    for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
        var word = String(word)
        let joined = current.isEmpty ? word : current + " " + word
        if fits(joined) { current = joined; continue }
        if !current.isEmpty { lines.append(current); current = "" }
        while !fits(word) && word.count > 1 {
            var cut = word.count - 1
            while cut > 1 && !fits(String(word.prefix(cut))) { cut -= 1 }
            lines.append(String(word.prefix(cut)))
            word = String(word.dropFirst(cut))
        }
        current = word
    }
    lines.append(current)
    return lines
}
