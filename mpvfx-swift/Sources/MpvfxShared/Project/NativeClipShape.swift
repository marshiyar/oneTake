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

/// Versioned vector geometry in the clip's box. Unknown contracts are opaque, losslessly retained JSON.
/// Dimensions, radius, stroke and dashes use project canvas pixels; endpoints use normalized box coordinates.
public struct NativeClipShape: Codable, Equatable, Sendable {
    /// Lossless authored JSON, including unknown fields and future version contracts.
    public var raw: NativeJSONValue
    public init(
        kind: String, radius: Double = 0, fill: String = "#ffffff", stroke: String = "#000000",
        strokeWidth: Double = 0, dash: [Double] = [], endX: Double = 1, endY: Double = 1
    ) {
        raw = .object(["v": .number(1), "kind": .string(kind)])
        for (key, value, fallback) in [
            ("radius", radius, 0.0), ("strokeWidth", strokeWidth, 0), ("endX", endX, 1), ("endY", endY, 1),
        ] where value != fallback {
            raw[key] = .number(value)
        }
        if fill != "#ffffff" { raw["fill"] = .string(fill) }
        if stroke != "#000000" { raw["stroke"] = .string(stroke) }
        if !dash.isEmpty { raw["dash"] = .array(dash.map(NativeJSONValue.number)) }
    }
    public init(from decoder: Decoder) throws { raw = try NativeJSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
    public static let kinds = ["rectangle", "ellipse", "triangle", "diamond", "polygon", "star", "line", "arrow"]
    public var kind: String { raw["kind"]?.stringValue ?? "" }
    public var isSupported: Bool { raw["v"] == .number(1) && Self.kinds.contains(kind) }
    public func number(_ key: String, default fallback: Double = 0) -> Double { raw[key]?.numberValue ?? fallback }
    public var fill: String { raw["fill"]?.stringValue ?? "#ffffff" }
    public var stroke: String { raw["stroke"]?.stringValue ?? "#000000" }
    public var dash: [Double] { raw["dash"]?.arrayValue?.compactMap(\.numberValue) ?? [] }
}

internal func validateNativeClipShape(
    _ value: NativeJSONValue?, assetKind: String?, boxWidth: Double?, boxHeight: Double?, _ path: String,
    _ issues: inout [NativeProjectDocumentValidationIssue]
) {
    guard let value else {
        return
    }
    guard value.isRecord else {
        pushIssue(&issues, .invalidShape, path, "Shape must be an object")
        return
    }
    if assetKind != "element" { pushIssue(&issues, .invalidShape, path, "Only element clips can carry shapes") }
    if !isPositiveInteger(value["v"]) {
        pushIssue(&issues, .invalidShape, "\(path).v", "Shape version must be a positive integer")
    }
    guard let kind = value["kind"]?.stringValue else {
        pushIssue(&issues, .invalidShape, "\(path).kind", "Shape kind must be a string")
        return
    }
    guard value["v"] == .number(1), NativeClipShape.kinds.contains(kind) else { return }
    validateShapeNumbers(value, path: path, issues: &issues)
    validateShapeRadius(value, kind: kind, width: boxWidth, height: boxHeight, path: path, issues: &issues)
    validateShapeColors(value, path: path, issues: &issues)
    validateShapeDashes(value, path: path, issues: &issues)
}

private func shapeNumberIsValid(_ number: Double, key: String) -> Bool {
    switch key {
    case "startX", "startY", "endX", "endY", "innerRadius": return (0...1).contains(number)
    case "sides": return number >= 3 && number <= 128 && jsIsInteger(number)
    default: return number >= 0
    }
}

private func validateShapeNumbers(
    _ value: NativeJSONValue, path: String,
    issues: inout [NativeProjectDocumentValidationIssue]
) {
    let keys = [
        "radius", "strokeWidth", "startX", "startY", "endX", "endY",
        "sides", "innerRadius", "headLength",
    ]
    for key in keys where value[key] != nil {
        guard let number = value[key]?.numberValue, number.isFinite else {
            pushIssue(&issues, .invalidShape, "\(path).\(key)", "Shape value must be finite")
            continue
        }
        if !shapeNumberIsValid(number, key: key) {
            pushIssue(&issues, .invalidShape, "\(path).\(key)", "Shape value is outside its supported range")
        }
    }
}

private func validateShapeRadius(
    _ value: NativeJSONValue, kind: String, width: Double?, height: Double?,
    path: String, issues: inout [NativeProjectDocumentValidationIssue]
) {
    guard kind == "rectangle", let radius = value["radius"]?.numberValue,
        let width, let height, radius > min(width, height) / 2
    else { return }
    pushIssue(&issues, .invalidShape, "\(path).radius", "Corner radius must fit within half the shorter box side")
}

private func validateShapeColors(
    _ value: NativeJSONValue, path: String,
    issues: inout [NativeProjectDocumentValidationIssue]
) {
    for key in ["fill", "stroke"] where value[key] != nil {
        let color = value[key]?.stringValue ?? ""
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : ""
        if ![3, 6, 8].contains(hex.count) || UInt64(hex, radix: 16) == nil {
            pushIssue(&issues, .invalidShape, "\(path).\(key)", "Shape color must be CSS hex")
        }
    }
}

private func validateShapeDashes(
    _ value: NativeJSONValue, path: String,
    issues: inout [NativeProjectDocumentValidationIssue]
) {
    guard let dash = value["dash"] else { return }
    guard let array = dash.arrayValue else {
        pushIssue(&issues, .invalidShape, "\(path).dash", "Dashes must be an array")
        return
    }
    for (index, item) in array.enumerated() where item.numberValue.map({ $0.isFinite && $0 > 0 }) != true {
        pushIssue(&issues, .invalidShape, "\(path).dash[\(index)]", "Dash lengths must be finite and positive")
    }

}

/// Pure edit plan: no mutation or history is recorded until the entire resulting document validates.
/// Missing clips, locked tracks and no-op changes return nil; invalid values throw typed document issues.
public func nativeClipShapeEditPlan(
    _ document: NativeProjectDocument, clipId: String, shape: NativeClipShape?,
    engine: KeyframeEngine? = nil
) throws -> NativeProjectDocument? {
    var result = document
    for t in result.sequence.tracks.indices {
        guard let i = result.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) else { continue }
        guard result.sequence.tracks[t].locked != true, result.sequence.tracks[t].clips[i].shape != shape else {
            return nil
        }
        result.sequence.tracks[t].clips[i].shape = shape
        return try parseNativeProjectDocument(result, engine: engine)
    }
    return nil
}
