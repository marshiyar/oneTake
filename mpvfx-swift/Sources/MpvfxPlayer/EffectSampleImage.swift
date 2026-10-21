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
import MpvfxCanvas

/// The built-in demo picture the look and effect tiles grade when there is no clip picture to show: a sunset over two
/// hills, a portrait disc in skin tones, a fine checker and a strip of colour bars, so colour looks, blurs, screens,
/// glows and glitches all read at thumbnail size. Drawn from code (no asset, no third-party image) and resolution
/// independent: pixel (x, y) samples the scene at ((x + 0.5) / width, (y + 0.5) / height), opaque.
public enum EffectSampleImage {
    typealias RGB = SIMD3<Double>

    /// The scene at `width` x `height` pixels (an empty image for a size below 1).
    public static func make(width: Int, height: Int) -> CanvasImage {
        guard width > 0, height > 0 else { return CanvasImage(width: 0, height: 0, rgba: []) }
        var px = [UInt8](repeating: 255, count: width * height * 4)
        let aspect = Double(width) / Double(height)
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let c = color(u: (Double(x) + 0.5) / Double(width), v: v, aspect: aspect)
                let i = (y * width + x) * 4
                px[i] = byte(c.x); px[i + 1] = byte(c.y); px[i + 2] = byte(c.z)
            }
        }
        return CanvasImage(width: width, height: height, rgba: px)
    }

    /// The scene colour at (u, v), both 0…1 from the top left; `aspect` is width / height.
    static func color(u: Double, v: Double, aspect: Double) -> RGB {
        if v >= 0.9 { return bar(u) }
        if let p = portrait(u, v, aspect) { return p }
        if let c = checker(u, v) { return c }
        if let h = hills(u, v) { return h }
        return sky(u, v, aspect)
    }

    /// Deep blue overhead to warm orange at the horizon, with a sun and its glow.
    static func sky(_ u: Double, _ v: Double, _ aspect: Double) -> RGB {
        let t = min(1, v / 0.62)
        let base = mix(RGB(0.10, 0.22, 0.48), RGB(0.98, 0.62, 0.32), t * t)
        let d = ((u - 0.74) * aspect * (u - 0.74) * aspect + (v - 0.28) * (v - 0.28)).squareRoot()
        if d < 0.08 { return RGB(1, 0.95, 0.80) }
        return mix(base, RGB(1, 0.86, 0.55), 0.45 * exp(-(d - 0.08) * 9))
    }

    /// A far hazy ridge and a near green one, darker toward the bottom.
    static func hills(_ u: Double, _ v: Double) -> RGB? {
        let near = 0.68 + 0.04 * sin(u * 5 + 2.2), far = 0.58 + 0.05 * sin(u * 9 + 0.6)
        if v > near { return RGB(0.16, 0.44, 0.18) * (1 - 0.55 * (v - near) / 0.3) }
        if v > far { return mix(RGB(0.30, 0.48, 0.42), RGB(0.62, 0.58, 0.52), 0.35 * (near - v) / 0.1) }
        return nil
    }

    /// A black-and-white checker on the near hill (cells 1/48 of the width): detail for blurs, pixelation and screens.
    static func checker(_ u: Double, _ v: Double) -> RGB? {
        guard (0.80..<0.97).contains(u), (0.72..<0.87).contains(v) else { return nil }
        let odd = (Int(u * 48) + Int(v * 27)) % 2 == 1
        return odd ? RGB(0.94, 0.94, 0.92) : RGB(0.08, 0.08, 0.10)
    }

    /// A shaded skin-tone disc with a dark hair cap, left of centre.
    static func portrait(_ u: Double, _ v: Double, _ aspect: Double) -> RGB? {
        let dx = (u - 0.27) * aspect, dy = v - 0.58
        let r = (dx * dx + dy * dy).squareRoot()
        guard r < 0.22 else { return nil }
        if dy < -0.08 { return RGB(0.24, 0.15, 0.10) * (1 - 0.3 * r / 0.22) }
        let light = 1 - 0.4 * ((dx + 0.06) * (dx + 0.06) + (dy + 0.06) * (dy + 0.06)).squareRoot() / 0.25
        return RGB(0.90, 0.68, 0.54) * max(0.45, light)
    }

    /// SMPTE-order colour bars across the bottom tenth: white, yellow, cyan, green, magenta, red, blue.
    static func bar(_ u: Double) -> RGB {
        let bars: [RGB] = [RGB(0.92, 0.92, 0.92), RGB(0.92, 0.90, 0.10), RGB(0.10, 0.85, 0.90), RGB(0.12, 0.80, 0.15),
                           RGB(0.85, 0.15, 0.80), RGB(0.90, 0.12, 0.10), RGB(0.12, 0.18, 0.90)]
        return bars[min(bars.count - 1, max(0, Int(u * Double(bars.count))))]
    }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a + (b - a) * min(1, max(0, t)) }

    static func byte(_ x: Double) -> UInt8 { UInt8(min(255, max(0, (x * 255).rounded()))) }
}
