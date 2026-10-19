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

/// A clip's 3D transform (the inspector's 3D Transform section: Depth, Tilt X, Tilt Y, Perspective; Roll is
/// `transform.rotation`), and the one projection preview and export both draw with.
///
/// Geometry follows the CSS transform order: `perspective(p) translateZ(z) rotate(roll)
/// rotateY(tiltY) rotateX(tiltX) scale(sx, sy)` about the box centre, y down and z toward the viewer. A positive
/// Tilt X turns the top edge away, a positive Tilt Y the right edge away. Without a lens (perspective 0) depth
/// changes nothing and tilts foreshorten orthographically.
public struct NativeTransform3D: Equatable, Sendable {
    public var rotationX: Double, rotationY: Double, z: Double, perspective: Double

    public static let rotationXId = "transform.rotationX", rotationYId = "transform.rotationY"
    public static let zId = "transform.position.z", perspectiveId = "transform.perspective"
    public static let parameterIds: [String] = [zId, rotationXId, rotationYId, perspectiveId]
    public static let identity = NativeTransform3D()

    public init(rotationX: Double = 0, rotationY: Double = 0, z: Double = 0, perspective: Double = 0) {
        self.rotationX = rotationX; self.rotationY = rotationY; self.z = z; self.perspective = max(0, perspective)
    }

    /// Nothing to draw differently from the flat transform.
    public var isIdentity: Bool { rotationX == 0 && rotationY == 0 && (perspective <= 0 || z == 0) }
    /// The projection is a linear map (no lens, or a lens on an untilted plane): one affine transform draws it.
    public var isAffine: Bool { perspective <= 0 || (rotationX == 0 && rotationY == 0) }

    /// The deepest a layer may come toward the lens (depth is clamped to 0.85 of the lens).
    public static func maxDepth(perspective: Double) -> Double { perspective > 0 ? perspective * 0.85 : .infinity }

    /// Homogeneous projection of a point `(u, v)` given relative to the box centre (canvas px): screen offset from
    /// the centre is `(x / w, y / w)`. `w` is positive in front of the lens; it may be ≤ 0 for points far outside a
    /// steeply tilted box (export's padded plane corners), which callers that draw only the box never reach.
    public func homogeneous(_ u: Double, _ v: Double, scaleX: Double = 1, scaleY: Double = 1,
                            rotation: Double = 0) -> (x: Double, y: Double, w: Double) {
        var x = scaleX * u, y = scaleY * v, zz = 0.0
        let ax = rotationX * .pi / 180, ay = rotationY * .pi / 180, az = rotation * .pi / 180
        // rotateX: y' = y cos − z sin, z' = y sin + z cos
        (y, zz) = (y * cos(ax) - zz * sin(ax), y * sin(ax) + zz * cos(ax))
        // rotateY: x' = x cos + z sin, z' = −x sin + z cos
        (x, zz) = (x * cos(ay) + zz * sin(ay), -x * sin(ay) + zz * cos(ay))
        // rotate (roll): x' = x cos − y sin, y' = x sin + y cos
        (x, y) = (x * cos(az) - y * sin(az), x * sin(az) + y * cos(az))
        zz += z
        guard perspective > 0 else { return (x, y, 1) }
        return (x, y, (perspective - zz) / perspective)
    }

    /// Screen offset from the box centre of `(u, v)` (canvas px), for points in front of the lens.
    public func project(_ u: Double, _ v: Double, scaleX: Double = 1, scaleY: Double = 1, rotation: Double = 0) -> (x: Double, y: Double) {
        let h = homogeneous(u, v, scaleX: scaleX, scaleY: scaleY, rotation: rotation)
        let w = max(h.w, 0.05)
        return (h.x / w, h.y / w)
    }
}
