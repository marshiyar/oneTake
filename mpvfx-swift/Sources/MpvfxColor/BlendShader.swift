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

/// Clip blend modes on straight-alpha RGBA8: the CPU reference of `blendChannel` / `blendComposite` in
/// `MpvfxColor.metal`, in the same operation order. The separable blend functions and the compositing equation are
/// those of the W3C Compositing and Blending Level 1 specification (https://www.w3.org/TR/compositing-1/, sections 9
/// and 10, read 2026-10-21); Add is the clamped sum. Preview and export both blend through `blend(_:over:mode:)`.
public enum BlendShader {
    /// One channel of the blend function B(cb, cs), backdrop `cb`, source `cs`, both 0...1.
    public static func channel(_ mode: NativeBlendMode, _ cb: Float, _ cs: Float) -> Float {
        switch mode {
        case .normal: return cs
        case .multiply: return cb * cs
        case .screen: return cb + cs - cb * cs
        case .overlay: return cb <= 0.5 ? cs * (2 * cb) : cs + (2 * cb - 1) - cs * (2 * cb - 1)
        case .add: return Swift.min(1, cb + cs)
        case .softLight:
            return cs <= 0.5 ? cb - (1 - 2 * cs) * cb * (1 - cb) : cb + (2 * cs - 1) * (softLightBackdrop(cb) - cb)
        case .darken: return Swift.min(cb, cs)
        case .lighten: return Swift.max(cb, cs)
        }
    }

    static func softLightBackdrop(_ x: Float) -> Float { x <= 0.25 ? ((16 * x - 12) * x + 4) * x : x.squareRoot() }

    /// `source` over `backdrop` (straight alpha, 0...1 per component) with `mode`.
    public static func composite(_ mode: NativeBlendMode, backdrop b: SIMD4<Float>, source s: SIMD4<Float>) -> SIMD4<Float> {
        let ar = s.w + b.w * (1 - s.w)
        guard ar > 0 else { return SIMD4<Float>(0, 0, 0, 0) }
        let mixed = SIMD3<Float>(channel(mode, b.x, s.x), channel(mode, b.y, s.y), channel(mode, b.z, s.z))
        let bc = SIMD3<Float>(b.x, b.y, b.z), sc = SIMD3<Float>(s.x, s.y, s.z)
        let c = ((1 - s.w) * b.w) * bc + ((1 - b.w) * s.w) * sc + (s.w * b.w) * mixed
        let out = clamp3(c / ar, 0, 1)
        return SIMD4<Float>(out.x, out.y, out.z, ar)
    }

    /// `source` over `backdrop`, two same-size straight-alpha RGBA8 pictures; the result is quantised to 8 bits as the
    /// GPU path's output is. A size mismatch returns nil.
    public static func blend(_ source: [UInt8], over backdrop: [UInt8], width: Int, height: Int,
                             mode: NativeBlendMode) -> [UInt8]? {
        let n = width * height * 4
        guard width > 0, height > 0, source.count == n, backdrop.count == n else { return nil }
        var out = [UInt8](repeating: 0, count: n)
        let row = width * 4
        concurrentRows(height, elementsPerRow: row, into: &out) { rows in
            var line = [UInt8](repeating: 0, count: row * rows.count)
            for (r, y) in rows.enumerated() {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let b = SIMD4<Float>(Float(backdrop[i]), Float(backdrop[i + 1]), Float(backdrop[i + 2]), Float(backdrop[i + 3])) / 255
                    let s = SIMD4<Float>(Float(source[i]), Float(source[i + 1]), Float(source[i + 2]), Float(source[i + 3])) / 255
                    let c = composite(mode, backdrop: b, source: s)
                    let o = r * row + x * 4
                    for k in 0..<4 { line[o + k] = UInt8(Swift.max(0, Swift.min(255, (c[k] * 255).rounded()))) }
                }
            }
            return line
        }
        return out
    }
}
