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
// The property baseline: the values (position, scale, rotation, size) a clip shows before any keyframe, read from its styles and box.
import Foundation

/// Partial<Record<NativeEditableProperty, number>>, keyed by property name ("x", "scaleX", ...).
public typealias NativePropertyBaselines = [String: Double]

public struct NativePropertyBaselineSource {
    public var computedStyles: [String: String]?
    public var boundingBox: (width: Double, height: Double)
    public init(computedStyles: [String: String]? = nil, boundingBox: (width: Double, height: Double)) {
        self.computedStyles = computedStyles; self.boundingBox = boundingBox
    }
}

private func finite(_ v: Double) -> Double? { v.isFinite ? v : nil }
private func positiveCssNumber(_ v: String?) -> Double? { let p = jsParseFloat(v ?? ""); return p.isFinite && p > 0 ? p : nil }
private func finiteCssNumber(_ v: String?) -> Double? { let p = jsParseFloat(v ?? ""); return p.isFinite ? p : nil }
/// JS `s.trim().split(/\s+/)`; "" -> [""].
private func splitWS(_ s: String) -> [String] {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? [""] : t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

private func angleDegrees(_ value: String?) -> Double? {
    guard let value, !value.isEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "none" else { return nil }
    guard let token = splitWS(value).last?.lowercased(), !token.isEmpty else { return nil }
    let n = jsParseFloat(token)
    guard n.isFinite else { return nil }
    if token.hasSuffix("deg") { return n }
    if token.hasSuffix("rad") { return n * 180 / Double.pi }
    if token.hasSuffix("turn") { return n * 360 }
    if token.hasSuffix("grad") { return n * 0.9 }
    return n == 0 ? 0 : nil
}

private func nearlyEqual(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= 1e-9 * max(1, abs(x), abs(y)) }

private func individualTransformBaselines(_ styles: [String: String]) -> NativePropertyBaselines {
    var r: NativePropertyBaselines = [:]
    let translate = styles["translate"].map(splitWS) ?? []
    if !translate.isEmpty && translate[0].lowercased() != "none" {
        let x = finiteCssNumber(translate[0])
        let y = finiteCssNumber(translate.count > 1 ? translate[1] : nil) ?? 0
        if let x { r["x"] = x; r["y"] = y }
    }
    if let rot = angleDegrees(styles["rotate"]) { r["rotation"] = rot; r["rotationZ"] = rot }
    let scale = styles["scale"].map(splitWS) ?? []
    if !scale.isEmpty && scale[0].lowercased() != "none" {
        let x = finiteCssNumber(scale[0])
        let y = finiteCssNumber(scale.count > 1 ? scale[1] : nil) ?? x
        if let x { r["scaleX"] = x }
        if let y { r["scaleY"] = y }
        if let x, let y, nearlyEqual(x, y) { r["scale"] = (x + y) / 2 }
    }
    return r
}

private func matrixNumbers(_ transform: String?) -> [Double]? {
    guard let transform, !transform.isEmpty else { return nil }
    let t = transform.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.lowercased() == "none" { return nil }
    // /^matrix(3d)?\((.*)\)$/i
    let lower = t.lowercased()
    let is3d: Bool, inner: Substring
    if lower.hasPrefix("matrix3d("), t.hasSuffix(")") { is3d = true; inner = t.dropFirst(9).dropLast() }
    else if lower.hasPrefix("matrix("), t.hasSuffix(")") { is3d = false; inner = t.dropFirst(7).dropLast() }
    else { return nil }
    let values = inner.split(separator: ",", omittingEmptySubsequences: false).map { jsNumber(String($0)) }
    return values.count == (is3d ? 16 : 6) && values.allSatisfy(\.isFinite) ? values : nil
}

private func transformBaselines(_ transform: String?) -> NativePropertyBaselines {
    guard let v = matrixNumbers(transform) else { return [:] }
    let is3d = v.count == 16
    let a = v[0], b = v[1], c = v[is3d ? 4 : 2], d = v[is3d ? 5 : 3], x = v[is3d ? 12 : 4], y = v[is3d ? 13 : 5]
    let scaleX = is3d ? (a * a + b * b + v[2] * v[2]).squareRoot() : hypot(a, b)
    let rawScaleY = is3d ? (c * c + d * d + v[6] * v[6]).squareRoot() : hypot(c, d)
    let scaleY = a * d - b * c < 0 ? -rawScaleY : rawScaleY
    let rotation = atan2(b, a) * 180 / Double.pi
    var r: NativePropertyBaselines = ["x": x, "y": y, "rotation": rotation, "rotationZ": rotation, "scaleX": scaleX, "scaleY": scaleY]
    if abs(scaleX - scaleY) <= 1e-9 * max(1, scaleX, abs(scaleY)) { r["scale"] = (scaleX + scaleY) / 2 }
    return r
}

/// Snapshot pre-native visual values so the first keyframe cannot jump to identity.
public func readNativePropertyBaselines(_ source: NativePropertyBaselineSource) -> NativePropertyBaselines {
    let styles = source.computedStyles ?? [:]
    var r = transformBaselines(styles["transform"])
    let ind = individualTransformBaselines(styles)
    if let x = ind["x"] { r["x"] = (r["x"] ?? 0) + x }
    if let y = ind["y"] { r["y"] = (r["y"] ?? 0) + y }
    if let rot = ind["rotation"] { let v = (r["rotation"] ?? 0) + rot; r["rotation"] = v; r["rotationZ"] = v }
    if let sx = ind["scaleX"] { r["scaleX"] = (r["scaleX"] ?? 1) * sx }
    if let sy = ind["scaleY"] { r["scaleY"] = (r["scaleY"] ?? 1) * sy }
    if let sx = r["scaleX"], let sy = r["scaleY"] {
        r["scale"] = nearlyEqual(sx, sy) ? (sx + sy) / 2 : nil   // nil: same as absent
    }
    if let o = finite(jsParseFloat(styles["opacity"] ?? "")) { let c = max(0, min(1, o)); r["opacity"] = c; r["autoAlpha"] = c }
    let bw = source.boundingBox.width, bh = source.boundingBox.height
    if let w = positiveCssNumber(styles["width"]) ?? (bw.isFinite && bw > 0 ? bw : nil) { r["width"] = w }
    if let h = positiveCssNumber(styles["height"]) ?? (bh.isFinite && bh > 0 ? bh : nil) { r["height"] = h }
    return r
}
