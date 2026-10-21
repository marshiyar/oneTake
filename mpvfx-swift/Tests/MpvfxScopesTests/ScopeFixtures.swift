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
@testable import MpvfxScopes

/// Synthetic frames built in the test, so every expected position follows from the frame's own code values.
enum ScopeFixtures {
    typealias Pixel = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    static func frame(_ width: Int, _ height: Int, _ pixel: (_ x: Int, _ y: Int) -> Pixel) throws -> ScopeFrame {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(x, y), o = (y * width + x) * 4
                bytes[o] = p.r; bytes[o + 1] = p.g; bytes[o + 2] = p.b; bytes[o + 3] = p.a
            }
        }
        return try ScopeFrame(width: width, height: height, rgba: bytes)
    }

    static func solid(_ width: Int, _ height: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: UInt8 = 255) throws -> ScopeFrame {
        try frame(width, height) { _, _ in (r, g, b, alpha) }
    }

    /// 256 columns, column x grey at code x: the black-to-white ramp.
    static func greyRamp(height: Int = 4) throws -> ScopeFrame {
        try frame(256, height) { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
    }

    /// The eight bars of Rec. ITU-R BT.471-1 in descending luminance: white at 100 %, then yellow, cyan, green,
    /// magenta, red and blue at `amplitude` (0.75 for 100/0/75/0), then black.
    static func barColours(amplitude: Double) -> [(name: String, r: UInt8, g: UInt8, b: UInt8)] {
        let on = UInt8((amplitude * 255).rounded())
        return [("White", 255, 255, 255), ("Yl", on, on, 0), ("Cy", 0, on, on), ("G", 0, on, 0),
                ("Mg", on, 0, on), ("R", on, 0, 0), ("B", 0, 0, on), ("Black", 0, 0, 0)]
    }

    static func bars(amplitude: Double, barWidth: Int, height: Int) throws -> ScopeFrame {
        let colours = barColours(amplitude: amplitude)
        return try frame(barWidth * colours.count, height) { x, _ in
            let c = colours[x / barWidth]
            return (c.r, c.g, c.b, 255)
        }
    }

    /// A deterministic busy picture (every level of every channel occurs) for the speed and density tests.
    static func busy(_ width: Int, _ height: Int) throws -> ScopeFrame {
        try frame(width, height) { x, y in
            let i = y * width + x
            return (UInt8(i % 251), UInt8((i / 7 + y) % 253), UInt8((x * 3 + y * 5) % 255), 255)
        }
    }

    /// The luma level the spec defines: the published coefficients in Double, rounded to the nearest code.
    static func lumaLevel(_ m: ScopeMatrix, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        Int(m.luma(Double(r), Double(g), Double(b)).rounded())
    }

    /// The vectorscope bin the spec defines for these code values.
    static func vectorBin(_ m: ScopeMatrix, _ r: UInt8, _ g: UInt8, _ b: UInt8, radius: Int = 128, zoom: Double = 1) -> (row: Int, col: Int)? {
        let c = m.chroma(Double(r) / 255, Double(g) / 255, Double(b) / 255)
        return ScopeGeometry.vectorBin(cb: c.cb, cr: c.cr, radius: radius, zoom: zoom)
    }
}
