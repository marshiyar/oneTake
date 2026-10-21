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

/// The shared typography resolution used by the inspector, preview and export. A nil override explicitly restores
/// that field's default; content always stays on the clip. Unsupported records return nil and leave the layer undrawn.
public func resolvedText(_ clip: NativeProjectClip, _ styles: [NativeTextStyle]) -> NativeClipText? {
    guard let text = clip.text else { return nil }
    guard let link = clip.textStyle else { return text }
    guard link.isSupported, let style = styles.first(where: { $0.id == link.styleId }), style.isSupported,
        var result = style.text
    else { return nil }
    result.content = text.content
    for field in link.overrides { copyNativeTextStyleField(field, from: text, to: &result) }
    return result
}

/// Copies one typography field, including an explicit nil that restores its default.
public func copyNativeTextStyleField(_ field: String, from text: NativeClipText, to result: inout NativeClipText) {
    switch field {
    case "fontFamily": result.fontFamily = text.fontFamily
    case "fontSize": result.fontSize = text.fontSize
    case "fontWeight": result.fontWeight = text.fontWeight
    case "color": result.color = text.color
    case "align": result.align = text.align
    default: copyTextStyleSpacingField(field, from: text, to: &result)
    }
}

private func copyTextStyleSpacingField(_ field: String, from text: NativeClipText, to result: inout NativeClipText) {
    switch field {
    case "letterSpacing": result.letterSpacing = text.letterSpacing
    case "lineHeight": result.lineHeight = text.lineHeight
    case "textTransform": result.textTransform = text.textTransform
    case "fontStyle": result.fontStyle = text.fontStyle
    case "look": result.look = text.look
    default: break
    }
}

/// Fields changed by an inspector edit, so subsequent style updates retain just those local overrides.
public func changedNativeTextStyleFields(_ before: NativeClipText, _ after: NativeClipText) -> [String] {
    NativeTextStyle.fields.filter { field in
        var copy = before
        copyNativeTextStyleField(field, from: after, to: &copy)
        return copy != before
    }
}
