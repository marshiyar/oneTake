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
import MpvfxShared
import MpvfxTimeline

// MARK: - Clip style (fill, stroke, shadow), stored on the clip as `clip.style`
public extension TimelineEditor {
    func clipStyle(clipId: String) -> NativeClipStyle { clip(clipId)?.1.style ?? NativeClipStyle() }

    /// Edits the clip's style in place; an empty style is removed from the clip. One undo step per call.
    @discardableResult
    func editClipStyle(clipId: String, _ body: (inout NativeClipStyle) -> Void) -> Bool {
        editClip(clipId) { c in
            var s = c.style ?? NativeClipStyle()
            body(&s)
            let next: NativeClipStyle? = s.isEmpty ? nil : s
            guard next != c.style else { return false }
            c.style = next; return true
        }
    }

    /// Solid fill (nil: transparent).
    @discardableResult
    func setClipFill(clipId: String, _ hex: String?) -> Bool { editClipStyle(clipId: clipId) { $0.fill = hex.flatMap(normalizedHexColor) } }

    /// Stroke width in px (0…200). A nonzero width with no visible style turns the style to solid
    /// (buildStrokeWidthStyleUpdates); zero clears the width.
    @discardableResult
    func setClipStrokeWidth(clipId: String, _ width: Double) -> Bool {
        let w = max(0, min(200, width.isFinite ? width : 0)).rounded()
        return editClipStyle(clipId: clipId) { s in
            s.strokeWidth = w > 0 ? w : nil
            if w > 0, (s.strokeStyle ?? "none") == "none" { s.strokeStyle = "solid" }
        }
    }

    @discardableResult
    func setClipStrokeStyle(clipId: String, _ style: String?) -> Bool {
        guard style == nil || NativeClipStyle.strokeStyles.contains(style!) else { return false }
        return editClipStyle(clipId: clipId) { s in
            s.strokeStyle = style
            if style == "solid", (s.strokeWidth ?? 0) <= 0 { s.strokeWidth = 1 }
        }
    }

    @discardableResult
    func setClipStrokeColor(clipId: String, _ hex: String?) -> Bool {
        editClipStyle(clipId: clipId) { $0.strokeColor = hex.flatMap(normalizedHexColor) }
    }

    @discardableResult
    func setClipShadowPreset(clipId: String, _ preset: NativeClipShadowPreset) -> Bool {
        editClipStyle(clipId: clipId) { $0.shadows = preset == .none ? nil : preset.shadows }
    }
}

/// `#rgb`, `#rrggbb`, `#rrggbbaa` (with or without `#`, any case) as lowercase `#rrggbb` / `#rrggbbaa`;
/// `transparent` / `none` / empty is nil. Opaque alpha (`ff`) is dropped.
public func normalizedHexColor(_ text: String) -> String? {
    var s = text.trimmingCharacters(in: .whitespaces).lowercased()
    if s.isEmpty || s == "transparent" || s == "none" { return nil }
    if !s.hasPrefix("#") { s = "#" + s }
    guard isNativeHexColor(s) else { return nil }
    var body = String(s.dropFirst())
    if body.count == 3 { body = body.map { "\($0)\($0)" }.joined() }
    if body.count == 8, body.hasSuffix("ff") { body = String(body.prefix(6)) }
    return "#" + body
}
