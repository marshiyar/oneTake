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

/// What fills the frame behind a clip that does not cover it: nothing, a colour, a gradient, an image or a blurred,
/// darkened copy of the clip itself. The project has one (`compositionFill` at the document root) and a clip may
/// have its own (`fill` on the clip, or `inherit` to take the project's).
///
/// The stored JSON object is kept as it is and read through typed accessors, so an object this version cannot
/// read (an unknown `v` or `kind`, or keys it does not know) is written back unchanged. Such a fill is not drawn
/// and `unsupportedFillsNotice` tells the user once.
public struct NativeFill: Codable, Equatable, Sendable {
    public static let version = 1
    public static let projectKinds = ["none", "color", "gradient", "image", "blur"]
    public static let clipKinds = ["inherit"] + projectKinds
    public static let maxGradientStops = 8
    public static let blurRange = 0.0...200.0
    public static let angleRange = -360.0...360.0
    public static let defaultBlur = 40.0
    public static let defaultDarken = 0.3
    public static let defaultAngle = 180.0

    /// The stored object.
    public private(set) var raw: NativeJSONValue

    public struct Stop: Equatable, Sendable {
        public var offset: Double
        public var color: String
        public init(offset: Double, color: String) { self.offset = offset; self.color = color }
    }

    public init(raw: NativeJSONValue) { self.raw = raw }
    public init(from decoder: Decoder) throws { raw = try NativeJSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    /// A version-1 fill. Values left nil are omitted (they hold their default).
    public init(kind: String, color: String? = nil, stops: [Stop]? = nil, angle: Double? = nil, assetId: String? = nil,
                blur: Double? = nil, darken: Double? = nil, gradientType: String? = nil, centerX: Double? = nil, centerY: Double? = nil) {
        var o: NativeJSONValue = .object(NativeJSONObject())
        o["v"] = .number(Double(Self.version)); o["kind"] = .string(kind)
        if let color { o["color"] = .string(color) }
        if let stops {
            var g: NativeJSONValue = .object(NativeJSONObject())
            if let angle { g["angle"] = .number(angle) }
            if let gradientType { g["type"] = .string(gradientType) }
            if let centerX { g["centerX"] = .number(centerX) }
            if let centerY { g["centerY"] = .number(centerY) }
            g["stops"] = .array(stops.map { s in
                var e: NativeJSONValue = .object(NativeJSONObject())
                e["offset"] = .number(s.offset); e["color"] = .string(s.color)
                return e
            })
            o["gradient"] = g
        }
        if let assetId { o["assetId"] = .string(assetId) }
        if let blur { o["blur"] = .number(blur) }
        if let darken { o["darken"] = .number(darken) }
        raw = o
    }

    public var v: Int? { raw["v"]?.numberValue.map { Int($0) } }
    public var kind: String? { raw["kind"]?.stringValue }
    public var color: String? { raw["color"]?.stringValue }
    public var assetId: String? { raw["assetId"]?.stringValue }
    public var blur: Double? { raw["blur"]?.numberValue }
    public var darken: Double? { raw["darken"]?.numberValue }
    public var resolvedBlur: Double { blur ?? Self.defaultBlur }
    public var resolvedDarken: Double { darken ?? Self.defaultDarken }
    public var gradientType: String { raw["gradient"]?["type"]?.stringValue ?? "linear" }
    public var centerX: Double { raw["gradient"]?["centerX"]?.numberValue ?? 0.5 }
    public var centerY: Double { raw["gradient"]?["centerY"]?.numberValue ?? 0.5 }
    public var isGenerator: Bool { isSupported && (kind == "color" || kind == "gradient") }
    public var angle: Double? { raw["gradient"]?["angle"]?.numberValue }
    public var resolvedAngle: Double { angle ?? Self.defaultAngle }
    public var stops: [Stop] {
        (raw["gradient"]?["stops"]?.arrayValue ?? []).compactMap { s in
            guard let o = s["offset"]?.numberValue, let c = s["color"]?.stringValue else { return nil }
            return Stop(offset: o, color: c)
        }
    }

    /// True for a version-1 fill of a kind this version draws (`inherit` only on a clip).
    public var isSupported: Bool { v == Self.version && kind.map(Self.clipKinds.contains) == true }
}

/// Validation of a fill object (`compositionFill`, or a clip's `fill` when `allowInherit`): every bad value is an
/// issue, nothing is clamped. An object with an unknown `v` or kind is kept and not validated further. `assets` are
/// the document's assets by id, to check an image fill's reference.
func validateNativeFill(_ value: NativeJSONValue?, _ path: String, allowInherit: Bool, assets: [String: NativeJSONValue],
                        _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let value else { return }
    guard value.isRecord else { return pushIssue(&issues, .invalidFill, path, "Fill must be an object") }
    guard let v = value["v"]?.numberValue else { return pushIssue(&issues, .invalidFill, "\(path).v", "Fill v must be a number") }
    guard v == 1, let kind = value["kind"]?.stringValue, NativeFill.clipKinds.contains(kind) else { return }
    if kind == "inherit", !allowInherit {
        return pushIssue(&issues, .invalidFill, "\(path).kind", "The project fill cannot inherit")
    }
    func hex(_ s: NativeJSONValue?, _ p: String) {
        if s?.stringValue.map(isNativeHexColor) != true {
            pushIssue(&issues, .invalidFill, p, "Fill colors must be #RGB, #RRGGBB or #RRGGBBAA")
        }
    }
    func number(_ key: String, _ range: ClosedRange<Double>, _ what: String) {
        guard let n = value[key] else { return }
        if n.numberValue.map({ $0.isFinite && range.contains($0) }) != true {
            pushIssue(&issues, .invalidFill, "\(path).\(key)", "\(what) must be a number from \(range.lowerBound) to \(range.upperBound)")
        }
    }
    if kind == "color" { hex(value["color"], "\(path).color") }
    if kind == "gradient" { validateNativeFillGradient(value["gradient"], "\(path).gradient", &issues) }
    if kind == "image" {
        let id = value["assetId"]?.stringValue
        if id == nil { pushIssue(&issues, .invalidFill, "\(path).assetId", "An image fill needs an assetId") }
        else if let id {
            if let asset = assets[id] {
                if asset["kind"]?.stringValue != "image" { pushIssue(&issues, .invalidFill, "\(path).assetId", "An image fill needs an image asset") }
            } else { pushIssue(&issues, .missingReference, "\(path).assetId", "Fill image asset does not exist") }
        }
    }
    number("blur", NativeFill.blurRange, "Fill blur")
    number("darken", 0...1, "Fill darken")
}

private func validateNativeFillGradient(_ g: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let g, g.isRecord else { return pushIssue(&issues, .invalidFill, path, "A gradient fill needs a gradient object") }
    if let type = g["type"], type.stringValue.map({ ["linear", "radial"].contains($0) }) != true {
        pushIssue(&issues, .invalidFill, "\(path).type", "Gradient type must be linear or radial")
    }
    for key in ["centerX", "centerY"] {
        if let n = g[key], n.numberValue.map({ $0.isFinite && (0...1).contains($0) }) != true {
            pushIssue(&issues, .invalidFill, "\(path).\(key)", "Gradient centre must be between 0 and 1")
        }
    }
    if let a = g["angle"], a.numberValue.map({ $0.isFinite && NativeFill.angleRange.contains($0) }) != true {
        pushIssue(&issues, .invalidFill, "\(path).angle", "Gradient angle must be a number from -360 to 360")
    }
    guard let stops = g["stops"]?.arrayValue, (2...NativeFill.maxGradientStops).contains(stops.count) else {
        return pushIssue(&issues, .invalidFill, "\(path).stops", "A gradient has 2 to \(NativeFill.maxGradientStops) stops")
    }
    var last = 0.0
    for (i, s) in stops.enumerated() {
        let p = "\(path).stops[\(i)]"
        guard s.isRecord else { pushIssue(&issues, .invalidFill, p, "A gradient stop must be an object"); continue }
        if let o = s["offset"]?.numberValue, o.isFinite, (0...1).contains(o), o >= last { last = o }
        else { pushIssue(&issues, .invalidFill, "\(p).offset", "Stop offsets are numbers from 0 to 1 that do not decrease") }
        if s["color"]?.stringValue.map(isNativeHexColor) != true {
            pushIssue(&issues, .invalidFill, "\(p).color", "Fill colors must be #RGB, #RRGGBB or #RRGGBBAA")
        }
    }
}

public extension NativeProjectDocument {
    /// One notice for fills from a newer version of the editor (or an unknown kind), kept but not drawn.
    var unsupportedFillsNotice: String? {
        let clips = sequence.tracks.flatMap(\.clips)
        let n = (compositionFill.map { $0.isSupported ? 0 : 1 } ?? 0) + clips.filter { $0.fill?.isSupported == false }.count + clips.filter { $0.generator != nil && $0.generator?.isGenerator != true }.count
        guard n > 0 else { return nil }
        return n == 1
            ? "1 canvas fill from a newer version of the editor is kept in the project but not drawn in preview or export."
            : "\(n) canvas fills from a newer version of the editor are kept in the project but not drawn in preview or export."
    }
}
