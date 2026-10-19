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

// MARK: - Text layers: a clip of a "Text" element asset whose words live on the clip (`clip.text`)
public extension TimelineEditor {
    func clipText(clipId: String) -> NativeClipText? { clip(clipId)?.1.text }

    /// Puts a new text layer on the timeline at `time` (on the first free video row, else a new one), centred on
    /// the canvas: white, bold, centre aligned, a tenth of the canvas height tall. One undo step. Returns its id.
    @discardableResult
    func addTextClip(at time: Double, content: String = "Text", seconds: Double = 5) -> String? {
        let cw = document.canvas.width, ch = document.canvas.height
        let size = max(8, (ch / 10).rounded())
        let frames = max(1, (seconds * fps).rounded())
        return withHistory("Add text", coalesceKey: "add-text-\(UUID().uuidString)") { () -> String? in
            let h = (size * NativeClipText.normalLineHeight).rounded()
            guard let assetId = addAsset(kind: .element, name: "Text", source: nil, durationFrames: frames) else { return nil }
            return insertClip(assetId: assetId, at: time, durationFrames: frames) { c in
                c.text = NativeClipText(content: content, fontSize: size, fontWeight: 700, color: NativeClipText.newLayerColor, align: "center")
                var p = c.staticParameters ?? [:]
                p["layout.left"] = .number((cw * 0.1).rounded()); p["layout.top"] = .number(((ch - h) / 2).rounded())
                p["layout.width"] = .number((cw * 0.8).rounded()); p["layout.height"] = .number(h)
                c.staticParameters = p
            }
        }
    }

    /// Edits a text clip's values in place. One undo step per call; false when nothing changed.
    @discardableResult
    func editClipText(clipId: String, _ body: (inout NativeClipText) -> Void) -> Bool {
        editClip(clipId) { c in
            guard var t = c.text else { return false }
            body(&t)
            guard t != c.text else { return false }
            c.text = t; return true
        }
    }

    @discardableResult
    func setTextContent(clipId: String, _ content: String) -> Bool { editClipText(clipId: clipId) { $0.content = content } }

    /// Font family (nil or empty: the default sans-serif).
    @discardableResult
    func setTextFontFamily(clipId: String, _ family: String?) -> Bool {
        let f = family?.trimmingCharacters(in: .whitespaces)
        return editClipText(clipId: clipId) { $0.fontFamily = (f?.isEmpty ?? true) ? nil : f }
    }

    /// Font size in px (nil resets to 16px); at most 2000.
    @discardableResult
    func setTextFontSize(clipId: String, _ size: Double?) -> Bool {
        if let s = size, !(s.isFinite && s > 0) { return false }
        return editClipText(clipId: clipId) { $0.fontSize = size.map { min(2000, ($0 * 100).rounded() / 100) } }
    }

    /// Font weight 100…900 (nil resets to 400).
    @discardableResult
    func setTextFontWeight(clipId: String, _ weight: Int?) -> Bool {
        if let w = weight, !(1...1000).contains(w) { return false }
        return editClipText(clipId: clipId) { $0.fontWeight = weight }
    }

    @discardableResult
    func setTextColor(clipId: String, _ hex: String?) -> Bool {
        let c = hex.flatMap(normalizedHexColor)
        if hex != nil && c == nil { return false }
        return editClipText(clipId: clipId) { $0.color = c }
    }

    @discardableResult
    func setTextAlign(clipId: String, _ align: String?) -> Bool {
        if let a = align, !NativeClipText.aligns.contains(a) { return false }
        return editClipText(clipId: clipId) { $0.align = align }
    }

    /// Letter spacing in px (nil or 0 resets).
    @discardableResult
    func setTextLetterSpacing(clipId: String, _ px: Double?) -> Bool {
        if let v = px, !v.isFinite { return false }
        return editClipText(clipId: clipId) { $0.letterSpacing = px.flatMap { $0 == 0 ? nil : ($0 * 100).rounded() / 100 } }
    }

    /// Line height as a multiple of the font size (nil resets to normal).
    @discardableResult
    func setTextLineHeight(clipId: String, _ multiple: Double?) -> Bool {
        if let v = multiple, !(v.isFinite && v > 0) { return false }
        return editClipText(clipId: clipId) { $0.lineHeight = multiple.map { ($0 * 100).rounded() / 100 } }
    }

    @discardableResult
    func setTextTransform(clipId: String, _ transform: String?) -> Bool {
        if let v = transform, !NativeClipText.transforms.contains(v) { return false }
        return editClipText(clipId: clipId) { $0.textTransform = transform == "none" ? nil : transform }
    }

    @discardableResult
    func setTextFontStyle(clipId: String, _ style: String?) -> Bool {
        if let v = style, !NativeClipText.fontStyles.contains(v) { return false }
        return editClipText(clipId: clipId) { $0.fontStyle = style == "normal" ? nil : style }
    }
}

/// normalizeTextMetricValue for the inspector's typed values: "1.5" / "24px" / "150%" / "normal".
enum TextMetric {
    /// Letter spacing: px, or em (times the font size); "normal" is 0.
    static func letterSpacing(_ text: String, fontSize: Double) -> Double?? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "normal" { return .some(nil) }
        if t.hasSuffix("em"), let v = Double(t.dropLast(2)) { return .some(v * fontSize) }
        if let v = Double(t.hasSuffix("px") ? String(t.dropLast(2)) : t) { return .some(v) }
        return nil
    }
    /// Line height as a multiple: unitless, %, or px (divided by the font size); "normal" resets.
    static func lineHeight(_ text: String, fontSize: Double) -> Double?? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "normal" { return .some(nil) }
        if t.hasSuffix("%"), let v = Double(t.dropLast()) { return .some(v / 100) }
        if t.hasSuffix("px"), let v = Double(t.dropLast(2)), fontSize > 0 { return .some(v / fontSize) }
        if let v = Double(t) { return .some(v) }
        return nil
    }
    /// Font weight: a number, or a weight label ("Bold", "semibold").
    static func weight(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let v = Int(t), (1...1000).contains(v) { return v }
        let squashed = t.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        return NativeClipText.weightLabels.first { $0.value.lowercased().replacingOccurrences(of: " ", with: "") == squashed }?.key
    }
}
