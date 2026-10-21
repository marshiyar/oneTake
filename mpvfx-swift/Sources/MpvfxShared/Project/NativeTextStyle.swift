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

/// A named, versioned typography record. Words belong to each clip; `text.content` is ignored.
/// Future versions/kinds retain their complete JSON and are not rendered.
public struct NativeTextStyle: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var kind: String = "text-style"
    public var id: String
    public var name: String?
    public var text: NativeClipText?
    public var spread = NativeSpreadKeys()
    public var isSupported: Bool { v == 1 && kind == "text-style" }
    public init(id: String, name: String, text: NativeClipText) {
        self.id = id; self.name = name; self.text = text
        self.text?.content = ""
    }
    private var known: [String] { isSupported ? ["v", "kind", "id", "name", "text"] : ["v", "kind", "id"] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        v = try c.req(Int.self, "v"); kind = try c.req(String.self, "kind"); id = try c.req(String.self, "id")
        if isSupported { name = try c.req(String.self, "name"); text = try c.req(NativeClipText.self, "text") }
        spread = try decodeSpread(decoder, known: known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: known) { k, c in
            switch k {
            case "v": try c.put(v, k)
            case "kind": try c.put(kind, k)
            case "id": try c.put(id, k)
            case "name": try c.put(name, k)
            default: try c.put(text, k)
            }
        }
    }
}

/// A link to a project style; overrides name the fields read from `clip.text`, including explicit nil/defaults.
public struct NativeTextStyleLink: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var kind: String = "text-style"
    public var styleId: String?
    public var overrides: [String]?
    public var spread = NativeSpreadKeys()
    public var isSupported: Bool { v == 1 && kind == "text-style" }
    public init(styleId: String, overrides: [String]? = nil) { self.styleId = styleId; self.overrides = overrides }
    private var known: [String] { isSupported ? ["v", "kind", "styleId", "overrides"] : ["v", "kind"] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        v = try c.req(Int.self, "v"); kind = try c.req(String.self, "kind")
        if isSupported { styleId = try c.req(String.self, "styleId"); overrides = try c.opt([String].self, "overrides") }
        spread = try decodeSpread(decoder, known: known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: known) { k, c in
            switch k {
            case "v": try c.put(v, k)
            case "kind": try c.put(kind, k)
            case "styleId": try c.put(styleId, k)
            default: try c.put(overrides, k)
            }
        }
    }
}

public let nativeTextStyleFields = ["fontFamily", "fontSize", "fontWeight", "color", "align", "letterSpacing",
                                    "lineHeight", "textTransform", "fontStyle", "look"]

/// The shared typography resolution used by the inspector, preview and export. A nil override explicitly restores
/// that field's default; content always stays on the clip. Unsupported records return nil and leave the layer undrawn.
public func resolvedText(_ clip: NativeProjectClip, _ styles: [NativeTextStyle]) -> NativeClipText? {
    guard let text = clip.text else { return nil }
    guard let link = clip.textStyle else { return text }
    guard link.isSupported, let style = styles.first(where: { $0.id == link.styleId }), style.isSupported,
          var result = style.text else { return nil }
    result.content = text.content
    for field in link.overrides ?? [] { copyNativeTextStyleField(field, from: text, to: &result) }
    return result
}

public func copyNativeTextStyleField(_ field: String, from text: NativeClipText, to result: inout NativeClipText) {
    switch field {
    case "fontFamily": result.fontFamily = text.fontFamily
    case "fontSize": result.fontSize = text.fontSize
    case "fontWeight": result.fontWeight = text.fontWeight
    case "color": result.color = text.color
    case "align": result.align = text.align
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
    nativeTextStyleFields.filter { field in
        var copy = before
        copyNativeTextStyleField(field, from: after, to: &copy)
        return copy != before
    }
}

func validateNativeTextStyles(_ raw: NativeJSONValue?, _ issues: inout [NativeProjectDocumentValidationIssue]) -> Set<String> {
    guard let raw else { return [] }
    guard let styles = raw.arrayValue else {
        pushIssue(&issues, .invalidRoot, "textStyles", "Text styles must be an array"); return []
    }
    var ids = Set<String>()
    for (index, style) in styles.enumerated() {
        let path = "textStyles[\(index)]"
        guard validateTextStyleContract(style, path, &issues) else { continue }
        requireId(style["id"], "\(path).id", &issues)
        collectDuplicateId(&ids, style["id"], "\(path).id", &issues)
        guard style["v"] == .number(1), style["kind"] == .string("text-style") else { continue }
        if !isNonEmptyString(style["name"]) { pushIssue(&issues, .invalidRoot, "\(path).name", "Style name must not be empty") }
        if style["text"] == nil { pushIssue(&issues, .invalidRoot, "\(path).text", "Style text is required") }
        validateNativeClipText(style["text"], "\(path).text", &issues)
    }
    return ids
}

func validateNativeTextStyleLink(_ clip: NativeJSONValue, _ ids: Set<String>, _ path: String,
                                 _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let link = clip["textStyle"] else { return }
    let path = "\(path).textStyle"
    guard validateTextStyleContract(link, path, &issues), link["v"] == .number(1), link["kind"] == .string("text-style") else { return }
    if clip["text"] == nil { pushIssue(&issues, .invalidClip, path, "Only text layers can link to a text style") }
    if let id = link["styleId"]?.stringValue, ids.contains(id) {} else {
        pushIssue(&issues, .invalidClip, "\(path).styleId", "Unknown text style id")
    }
    if let overrides = link["overrides"] {
        guard let fields = overrides.arrayValue else { return pushIssue(&issues, .invalidClip, "\(path).overrides", "Overrides must be an array") }
        var seen = Set<String>()
        for (index, field) in fields.enumerated() {
            guard let name = field.stringValue, nativeTextStyleFields.contains(name), seen.insert(name).inserted else {
                pushIssue(&issues, .invalidClip, "\(path).overrides[\(index)]", "Unknown or duplicate text style override"); continue
            }
        }
    }
}

private func validateTextStyleContract(_ raw: NativeJSONValue, _ path: String,
                                        _ issues: inout [NativeProjectDocumentValidationIssue]) -> Bool {
    guard raw.isRecord else { pushIssue(&issues, .invalidClip, path, "Text style record must be an object"); return false }
    var valid = true
    if !isPositiveInteger(raw["v"]) { pushIssue(&issues, .invalidClip, "\(path).v", "Style version must be a positive integer"); valid = false }
    if !isNonEmptyString(raw["kind"]) { pushIssue(&issues, .invalidClip, "\(path).kind", "Style kind must be a nonempty string"); valid = false }
    return valid
}

public extension NativeProjectDocument {
    func isUndrawnTextStyleClip(_ clip: NativeProjectClip) -> Bool {
        clip.textStyle != nil && resolvedText(clip, textStyles ?? []) == nil
    }
    var unsupportedTextStylesNotice: String? {
        let count = (textStyles ?? []).filter { !$0.isSupported }.count
            + sequence.tracks.flatMap(\.clips).filter(isUndrawnTextStyleClip).count
        return count > 0 ? "Text styles from a newer version are kept in the project but not drawn in preview or export." : nil
    }
}
