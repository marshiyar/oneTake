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

/// The flat inspector's Style section on a native clip (Fill, Stroke,
/// Shadow). The document keeps them as values on the
/// clip itself (`clip.style`), drawn by the preview and rendered by export. Absent fields mean the defaults:
/// no fill (transparent), no stroke, no shadow.
public struct NativeClipStyle: Codable, Equatable, Hashable, Sendable {
    /// Solid fill behind the media inside the clip box, `#RRGGBB` or `#RRGGBBAA`.
    public var fill: String?
    /// Stroke (border) drawn inside the clip box edge, in canvas px (width 0…200).
    public var strokeWidth: Double?
    /// `none` or `solid` (the stroke styles the native renderers draw); absent with a width draws solid.
    public var strokeStyle: String?
    /// `#RRGGBB` / `#RRGGBBAA`; absent: the default rgba(255, 255, 255, 0.18).
    public var strokeColor: String?
    /// Box shadows, drawn under the clip, first one on top.
    public var shadows: [NativeClipShadow]?

    public init(fill: String? = nil, strokeWidth: Double? = nil, strokeStyle: String? = nil, strokeColor: String? = nil,
                shadows: [NativeClipShadow]? = nil) {
        self.fill = fill; self.strokeWidth = strokeWidth; self.strokeStyle = strokeStyle; self.strokeColor = strokeColor
        self.shadows = shadows
    }

    public static let defaultStrokeColor = "#ffffff2e"   // rgba(255, 255, 255, 0.18)
    public static let strokeStyles = ["none", "solid"]

    /// Nothing set: the clip draws exactly as without a style.
    public var isEmpty: Bool { fill == nil && strokeWidth == nil && strokeStyle == nil && strokeColor == nil && (shadows ?? []).isEmpty }
    /// Stroke width that actually draws (a width with style `none` draws nothing).
    public var visibleStrokeWidth: Double {
        guard let w = strokeWidth, w > 0, (strokeStyle ?? "solid") != "none" else { return 0 }
        return w
    }
    public var resolvedStrokeColor: String { strokeColor ?? Self.defaultStrokeColor }
}

/// One box shadow: offset, blur radius, spread, colour.
public struct NativeClipShadow: Codable, Equatable, Hashable, Sendable {
    public var x: Double, y: Double, blur: Double, spread: Double
    public var color: String
    public init(x: Double = 0, y: Double = 0, blur: Double = 0, spread: Double = 0, color: String) {
        self.x = x; self.y = y; self.blur = blur; self.spread = spread; self.color = color
    }
}

/// The shadow presets (BOX_SHADOW_PRESETS).
public enum NativeClipShadowPreset: String, CaseIterable, Sendable {
    case none, soft, lift, glow

    public var shadows: [NativeClipShadow] {
        switch self {
        case .none: []
        case .soft: [NativeClipShadow(y: 12, blur: 36, color: "#00000047")]                 // 0 12px 36px rgba(0,0,0,.28)
        case .lift: [NativeClipShadow(y: 18, blur: 54, color: "#00000061")]                 // 0 18px 54px rgba(0,0,0,.38)
        case .glow: [NativeClipShadow(spread: 1, color: "#3ce6ac57"),                        // 0 0 0 1px rgba(60,230,172,.34)
                     NativeClipShadow(y: 18, blur: 56, color: "#3ce6ac33")]                  // 0 18px 56px rgba(60,230,172,.2)
        }
    }

    /// The preset a list of shadows is, or nil ("custom").
    public static func infer(_ shadows: [NativeClipShadow]?) -> NativeClipShadowPreset? {
        let s = shadows ?? []
        return allCases.first { $0.shadows == s }
    }
}

/// `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
public func isNativeHexColor(_ s: String) -> Bool {
    guard s.hasPrefix("#") else { return false }
    let body = s.dropFirst()
    return [3, 6, 8].contains(body.count) && body.allSatisfy(\.isHexDigit)
}

/// Validation of `clip.style` (NativeProjectDocumentValidation).
func validateNativeClipStyle(_ style: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let style else { return }
    guard style.isRecord else { return pushIssue(&issues, .invalidClip, path, "Style must be an object") }
    func color(_ v: NativeJSONValue?, _ p: String) {
        guard let v else { return }
        if v.stringValue.map(isNativeHexColor) != true { pushIssue(&issues, .invalidClip, p, "Style colors must be #RGB, #RRGGBB or #RRGGBBAA") }
    }
    func number(_ v: NativeJSONValue?, _ p: String, nonNegative: Bool) {
        guard let v else { return }
        if v.numberValue.map({ $0.isFinite && (!nonNegative || $0 >= 0) }) != true {
            pushIssue(&issues, .invalidClip, p, nonNegative ? "Style sizes must be finite non-negative numbers" : "Style offsets must be finite numbers")
        }
    }
    color(style["fill"], "\(path).fill")
    color(style["strokeColor"], "\(path).strokeColor")
    number(style["strokeWidth"], "\(path).strokeWidth", nonNegative: true)
    if let s = style["strokeStyle"], s.stringValue.map(NativeClipStyle.strokeStyles.contains) != true {
        pushIssue(&issues, .invalidClip, "\(path).strokeStyle", "Stroke style must be none or solid")
    }
    if let raw = style["shadows"] {
        guard let list = raw.arrayValue else { return pushIssue(&issues, .invalidClip, "\(path).shadows", "Shadows must be an array") }
        for (i, sh) in list.enumerated() {
            let p = "\(path).shadows[\(i)]"
            guard sh.isRecord, sh["color"] != nil else { pushIssue(&issues, .invalidClip, p, "A shadow needs a color"); continue }
            color(sh["color"], "\(p).color")
            for k in ["x", "y"] { number(sh[k] ?? .number(0), "\(p).\(k)", nonNegative: false) }
            for k in ["blur", "spread"] { number(sh[k] ?? .number(0), "\(p).\(k)", nonNegative: k == "blur") }
        }
    }
}
