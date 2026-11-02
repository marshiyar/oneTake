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

/// A corner-pin distort of a clip's box: where each of the four corners sits, as an offset from its own natural
/// position, in fractions of the box (x of the box width, y of the box height, y down). All zeros is the plain box.
/// The offsets are stored on the clip (`clip.corners`) and can be keyframed per component
/// (`NativeClipCorners.parameterIds`); preview and export evaluate both the same way and draw through the one
/// `NativeCornerPin` mapping.
public struct NativeClipCorners: Codable, Equatable, Hashable, Sendable {
    public struct Offset: Codable, Equatable, Hashable, Sendable {
        public var x: Double, y: Double
        public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
        public static let zero = Offset()
    }
    public enum Corner: String, CaseIterable, Sendable { case topLeft = "tl", topRight = "tr", bottomRight = "br", bottomLeft = "bl" }

    public var tl: Offset, tr: Offset, br: Offset, bl: Offset

    /// Offsets are bounded so a typo cannot throw the clip millions of boxes away.
    public static let maxOffset = 4.0
    public static let identity = NativeClipCorners()

    public init(tl: Offset = .zero, tr: Offset = .zero, br: Offset = .zero, bl: Offset = .zero) {
        self.tl = tl; self.tr = tr; self.br = br; self.bl = bl
    }

    public subscript(corner: Corner) -> Offset {
        get {
            switch corner { case .topLeft: return tl; case .topRight: return tr; case .bottomRight: return br; case .bottomLeft: return bl }
        }
        set {
            switch corner { case .topLeft: tl = newValue; case .topRight: tr = newValue; case .bottomRight: br = newValue; case .bottomLeft: bl = newValue }
        }
    }

    public var isIdentity: Bool { Corner.allCases.allSatisfy { self[$0] == .zero } }

    /// Keyframable parameter ids, `corners.<tl|tr|br|bl>.<x|y>`.
    public static func parameterId(_ corner: Corner, _ axis: String) -> String { "corners.\(corner.rawValue).\(axis)" }
    public static let parameterIds: [String] = Corner.allCases.flatMap { c in ["x", "y"].map { parameterId(c, $0) } }
    public static func isCornerParameter(_ id: String) -> Bool { parameterIds.contains(id) }

    /// These offsets with every keyframed component replaced by `number(id)` (the evaluated track value).
    public func resolved(_ number: (String) -> Double?) -> NativeClipCorners {
        var out = self
        for c in Corner.allCases {
            if let v = number(Self.parameterId(c, "x")) { out[c].x = v }
            if let v = number(Self.parameterId(c, "y")) { out[c].y = v }
        }
        return out
    }

    /// Offsets with non-finite values dropped to zero and the rest bounded, as the painter reads them.
    public var sanitized: NativeClipCorners {
        var out = self
        func clean(_ v: Double) -> Double { v.isFinite ? max(-Self.maxOffset, min(Self.maxOffset, v)) : 0 }
        for c in Corner.allCases { out[c] = Offset(x: clean(out[c].x), y: clean(out[c].y)) }
        return out
    }

    /// The pin the painter draws with, nil when there is nothing to draw differently.
    public var pin: NativeCornerPin? { isIdentity ? nil : NativeCornerPin(corners: sanitized) }
}

/// The perspective (homography) mapping of a clip's unit box onto its four distorted corners, the one mapping
/// preview and export draw with. Points are unit box coordinates: (0,0) top left, (1,1) bottom right.
public struct NativeCornerPin: Equatable, Sendable {
    /// Destination of the corners in unit box coordinates, clockwise from the top left.
    public let quad: [Pt]
    public struct Pt: Equatable, Sendable { public var x: Double, y: Double }
    // X = (a u + b v + c) / (g u + h v + 1), Y = (d u + e v + f) / (g u + h v + 1).
    private let a, b, c, d, e, f, g, h: Double

    public init(corners: NativeClipCorners) {
        let p = [Pt(x: 0 + corners.tl.x, y: 0 + corners.tl.y), Pt(x: 1 + corners.tr.x, y: 0 + corners.tr.y),
                 Pt(x: 1 + corners.br.x, y: 1 + corners.br.y), Pt(x: 0 + corners.bl.x, y: 1 + corners.bl.y)]
        quad = p
        // Heckbert's square-to-quadrilateral map.
        let x0 = p[0].x, y0 = p[0].y, x1 = p[1].x, y1 = p[1].y, x2 = p[2].x, y2 = p[2].y, x3 = p[3].x, y3 = p[3].y
        let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
        let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
        let det = dx1 * dy2 - dx2 * dy1
        if (abs(sx) < 1e-12 && abs(sy) < 1e-12) || abs(det) < 1e-12 {
            g = 0; h = 0
            a = x1 - x0; b = x3 - x0; c = x0; d = y1 - y0; e = y3 - y0; f = y0
        } else {
            g = (sx * dy2 - dx2 * sy) / det
            h = (dx1 * sy - sx * dy1) / det
            a = x1 - x0 + g * x1; b = x3 - x0 + h * x3; c = x0
            d = y1 - y0 + g * y1; e = y3 - y0 + h * y3; f = y0
        }
    }

    /// Where the unit box point `(u, v)` lands.
    public func map(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
        let w = g * u + h * v + 1
        let k = abs(w) < 1e-9 ? 1e-9 : w
        return ((a * u + b * v + c) / k, (d * u + e * v + f) / k)
    }

    /// The unit box point that lands on `(x, y)`, nil for a collapsed quad.
    public func unmap(_ x: Double, _ y: Double) -> (u: Double, v: Double)? {
        // Adjugate of [[a b c],[d e f],[g h 1]], applied to (x, y, 1) and projected.
        let A = e - f * h, B = c * h - b, C = b * f - c * e
        let D = f * g - d, E = a - c * g, F = c * d - a * f
        let G = d * h - e * g, H = b * g - a * h, I = a * e - b * d
        guard abs(a * A + b * D + c * G) > 1e-12 else { return nil }
        let w = G * x + H * y + I
        guard abs(w) > 1e-12 else { return nil }
        return ((A * x + B * y + C) / w, (D * x + E * y + F) / w)
    }

    /// The quad is a parallelogram: one affine map draws it exactly.
    public var isAffine: Bool { abs(g) < 1e-12 && abs(h) < 1e-12 }

    /// A convex quad with positive area (no bow-tie, no collapsed corner).
    public var isConvex: Bool {
        var sign = 0.0
        for i in 0..<4 {
            let p = quad[i], q = quad[(i + 1) % 4], r = quad[(i + 2) % 4]
            let cross = (q.x - p.x) * (r.y - q.y) - (q.y - p.y) * (r.x - q.x)
            if abs(cross) < 1e-9 { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }
}

func validateNativeClipCorners(_ value: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let value else { return }
    guard value.isRecord else { pushIssue(&issues, .invalidClip, path, "Corners must be an object"); return }
    for corner in NativeClipCorners.Corner.allCases {
        let p = "\(path).\(corner.rawValue)"
        guard let offset = value[corner.rawValue], offset.isRecord else {
            pushIssue(&issues, .invalidClip, p, "Corners need an x and y offset for tl, tr, br and bl"); continue
        }
        for axis in ["x", "y"] {
            guard let n = offset[axis]?.numberValue, n.isFinite, abs(n) <= NativeClipCorners.maxOffset else {
                pushIssue(&issues, .invalidClip, "\(p).\(axis)",
                          "Corner offsets must be finite numbers within \(Int(NativeClipCorners.maxOffset)) boxes"); continue
            }
        }
    }
}
