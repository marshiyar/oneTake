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

/// A non-destructive mask in layer-local coordinates. Geometry is normalized to the layer box.
/// String-backed `kind` and `mode` deliberately preserve values written by a newer editor.
public struct NativeClipMask: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var kind: String
    public var mode: String?
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var angle: Double?
    public var feather: Double?
    public var expansion: Double?
    public var opacity: Double?
    public var invert: Bool?
    public var spread = NativeSpreadKeys()
    static let known = ["v", "id", "kind", "mode", "x", "y", "width", "height", "angle", "feather", "expansion", "opacity", "invert"]

    public init(v: Int = 1, id: String, kind: String, mode: String? = nil, x: Double? = nil, y: Double? = nil,
                width: Double? = nil, height: Double? = nil, angle: Double? = nil, feather: Double? = nil,
                expansion: Double? = nil, opacity: Double? = nil, invert: Bool? = nil) {
        self.v = v; self.id = id; self.kind = kind; self.mode = mode; self.x = x; self.y = y
        self.width = width; self.height = height; self.angle = angle; self.feather = feather
        self.expansion = expansion; self.opacity = opacity; self.invert = invert
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        v = try c.req(Int.self, "v"); id = try c.req(String.self, "id"); kind = try c.req(String.self, "kind")
        mode = try c.opt(String.self, "mode"); x = try c.opt(Double.self, "x"); y = try c.opt(Double.self, "y")
        width = try c.opt(Double.self, "width"); height = try c.opt(Double.self, "height"); angle = try c.opt(Double.self, "angle")
        feather = try c.opt(Double.self, "feather"); expansion = try c.opt(Double.self, "expansion")
        opacity = try c.opt(Double.self, "opacity"); invert = try c.opt(Bool.self, "invert")
        spread = try decodeSpread(decoder, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { key, c in
            switch key {
            case "v": try c.put(v, key); case "id": try c.put(id, key); case "kind": try c.put(kind, key)
            case "mode": try c.put(mode, key); case "x": try c.put(x, key); case "y": try c.put(y, key)
            case "width": try c.put(width, key); case "height": try c.put(height, key); case "angle": try c.put(angle, key)
            case "feather": try c.put(feather, key); case "expansion": try c.put(expansion, key)
            case "opacity": try c.put(opacity, key); default: try c.put(invert, key)
            }
        }
    }

    public var isSupported: Bool { v == 1 && ["rectangle", "ellipse", "linear", "band"].contains(kind) }
    public var resolvedMode: String { mode ?? "add" }
}

func validateNativeClipMasks(_ value: NativeJSONValue?, _ path: String,
                             _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let value else { return }
    guard let masks = value.arrayValue else {
        pushIssue(&issues, .invalidMask, path, "Masks must be an array"); return
    }
    var ids = Set<String>()
    for (index, mask) in masks.enumerated() {
        let p = "\(path)[\(index)]"
        guard mask.isRecord else { pushIssue(&issues, .invalidMask, p, "Mask must be an object"); continue }
        requireId(mask["id"], "\(p).id", &issues)
        collectDuplicateId(&ids, mask["id"], "\(p).id", &issues)
        // Unknown versions and kinds are forward-compatible opaque objects.
        guard mask["v"] == .number(1), let kind = mask["kind"]?.stringValue,
              ["rectangle", "ellipse", "linear", "band"].contains(kind) else { continue }
        if let mode = mask["mode"], !["add", "subtract", "intersect"].contains(mode.stringValue ?? "") {
            pushIssue(&issues, .invalidMask, "\(p).mode", "Mask mode must be add, subtract, or intersect")
        }
        for field in ["x", "y", "width", "height", "angle", "feather", "expansion", "opacity"] where mask[field] != nil {
            guard let n = mask[field]?.numberValue, n.isFinite else {
                pushIssue(&issues, .invalidMask, "\(p).\(field)", "Mask \(field) must be a finite number"); continue
            }
            if ["width", "height", "feather"].contains(field), n < 0 {
                pushIssue(&issues, .invalidMask, "\(p).\(field)", "Mask \(field) must not be negative")
            }
            if field == "opacity", !(0...1).contains(n) {
                pushIssue(&issues, .invalidMask, "\(p).opacity", "Mask opacity must be between zero and one")
            }
        }
        if mask["invert"] != nil, mask["invert"]?.boolValue == nil {
            pushIssue(&issues, .invalidMask, "\(p).invert", "Mask invert must be a boolean")
        }
    }
}
