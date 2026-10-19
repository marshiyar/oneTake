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

/// A native text layer (the flat inspector's Text section): the words a
/// text clip draws inside its box and how. The document keeps the values on the clip (`clip.text`), drawn by the preview and rendered by
/// export from the same layout. Absent fields mean the defaults: 16px, weight 400, black, start
/// aligned, no letter spacing, normal line height, no case change, upright.
public struct NativeClipText: Codable, Equatable, Hashable, Sendable {
    /// The words; `\n` breaks a line. Lines also wrap at the box width.
    public var content: String
    /// Font family name (nil: the default sans-serif).
    public var fontFamily: String?
    /// Font size in canvas px.
    public var fontSize: Double?
    /// Font weight, 100…900.
    public var fontWeight: Int?
    /// `#RRGGBB` / `#RRGGBBAA`.
    public var color: String?
    /// left, center, right or justify.
    public var align: String?
    /// Extra px after every character (letter spacing).
    public var letterSpacing: Double?
    /// Line height as a multiple of the font size (unitless line height); nil is `normal`.
    public var lineHeight: Double?
    /// none, uppercase, lowercase or capitalize (text case).
    public var textTransform: String?
    /// normal or italic (font style).
    public var fontStyle: String?

    public init(content: String, fontFamily: String? = nil, fontSize: Double? = nil, fontWeight: Int? = nil, color: String? = nil,
                align: String? = nil, letterSpacing: Double? = nil, lineHeight: Double? = nil, textTransform: String? = nil,
                fontStyle: String? = nil) {
        self.content = content; self.fontFamily = fontFamily; self.fontSize = fontSize; self.fontWeight = fontWeight
        self.color = color; self.align = align; self.letterSpacing = letterSpacing; self.lineHeight = lineHeight
        self.textTransform = textTransform; self.fontStyle = fontStyle
    }

    public static let defaultFontFamily = "Sans"
    public static let defaultFontSize = 16.0
    public static let defaultFontWeight = 400
    public static let defaultColor = "#000000"
    /// The colour a new text layer starts with (the T shortcut / Add text): white.
    public static let newLayerColor = "#ffffff"
    /// The `normal` line height, as a multiple of the font size.
    public static let normalLineHeight = 1.2
    public static let aligns = ["left", "center", "right", "justify"]
    public static let transforms = ["none", "uppercase", "lowercase", "capitalize"]
    public static let fontStyles = ["normal", "italic"]
    /// Inspector labels for the font weights.
    public static let weightLabels: [Int: String] = [100: "Thin", 200: "Extra Light", 300: "Light", 400: "Regular", 500: "Medium",
                                                     600: "Semibold", 700: "Bold", 800: "Extra Bold", 900: "Black"]

    public var resolvedFontFamily: String { fontFamily.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultFontFamily }
    public var resolvedFontSize: Double { fontSize ?? Self.defaultFontSize }
    public var resolvedFontWeight: Int { fontWeight ?? Self.defaultFontWeight }
    public var resolvedColor: String { color ?? Self.defaultColor }
    public var resolvedAlign: String { align ?? "left" }
    public var resolvedLetterSpacing: Double { letterSpacing ?? 0 }
    public var resolvedLineHeight: Double { lineHeight ?? Self.normalLineHeight }
    public var resolvedTransform: String { textTransform ?? "none" }
    public var isItalic: Bool { fontStyle == "italic" }

    /// The content with the case transform applied.
    public var displayContent: String {
        switch resolvedTransform {
        case "uppercase": return content.uppercased()
        case "lowercase": return content.lowercased()
        case "capitalize":
            var out = "", startOfWord = true
            for ch in content {
                out += startOfWord ? ch.uppercased() : String(ch)
                startOfWord = ch.isWhitespace || ch.isPunctuation && ch != "'"
            }
            return out
        default: return content
        }
    }

    /// formatTextFieldPreview: the first line, collapsed, for summaries.
    public var preview: String {
        let flat = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = flat.trimmingCharacters(in: .whitespaces)
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }
}

/// Validation of `clip.text` (NativeProjectDocumentValidation).
func validateNativeClipText(_ text: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let text else { return }
    guard text.isRecord else { return pushIssue(&issues, .invalidClip, path, "Text must be an object") }
    if text["content"]?.stringValue == nil { pushIssue(&issues, .invalidClip, "\(path).content", "Text content must be a string") }
    if let v = text["fontFamily"], v.stringValue == nil { pushIssue(&issues, .invalidClip, "\(path).fontFamily", "Font family must be a string") }
    if let v = text["fontSize"], v.numberValue.map({ $0.isFinite && $0 > 0 }) != true {
        pushIssue(&issues, .invalidClip, "\(path).fontSize", "Font size must be a positive number")
    }
    if let v = text["fontWeight"], v.numberValue.map({ $0 >= 1 && $0 <= 1000 && $0 == $0.rounded() }) != true {
        pushIssue(&issues, .invalidClip, "\(path).fontWeight", "Font weight must be a whole number from 1 to 1000")
    }
    if let v = text["color"], v.stringValue.map(isNativeHexColor) != true {
        pushIssue(&issues, .invalidClip, "\(path).color", "Text color must be #RGB, #RRGGBB or #RRGGBBAA")
    }
    for (key, allowed) in [("align", NativeClipText.aligns), ("textTransform", NativeClipText.transforms), ("fontStyle", NativeClipText.fontStyles)] {
        if let v = text[key], v.stringValue.map(allowed.contains) != true {
            pushIssue(&issues, .invalidClip, "\(path).\(key)", "Text \(key) must be one of \(allowed.joined(separator: ", "))")
        }
    }
    if let v = text["letterSpacing"], v.numberValue.map(\.isFinite) != true {
        pushIssue(&issues, .invalidClip, "\(path).letterSpacing", "Letter spacing must be a finite number")
    }
    if let v = text["lineHeight"], v.numberValue.map({ $0.isFinite && $0 > 0 }) != true {
        pushIssue(&issues, .invalidClip, "\(path).lineHeight", "Line height must be a positive number")
    }
}
