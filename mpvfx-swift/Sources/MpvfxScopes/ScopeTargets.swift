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

/// A vectorscope target: where one colour bar lands.
public struct ScopeTarget: Sendable, Equatable {
    /// R, Mg, B, Cy, G, Yl (the letters engraved on vectorscope graticules).
    public let name: String
    public let red: Double, green: Double, blue: Double
    public let cb: Double, cr: Double
}

/// Graticule references computed from the published formulas, never typed in: colour-bar targets, the skin-tone
/// line and the BT.709 transfer function (sources and the derivation in `docs/SCOPES.md`).
public enum ScopeTargets {
    /// Rec. ITU-R BT.471-1: 100/0/75/0 bars carry their colours at 75 % of R'G'B', 100/0/100/0 bars at 100 %.
    public static let barAmplitudes: [Double] = [0.75, 1]

    /// The six coloured bars at `amplitude` (0.75 or 1), in vectorscope order counter-clockwise from red.
    public static func bars(_ matrix: ScopeMatrix, amplitude: Double) -> [ScopeTarget] {
        let a = min(1, max(0, amplitude.isFinite ? amplitude : 1))
        let colours: [(String, Double, Double, Double)] = [("R", 1, 0, 0), ("Mg", 1, 0, 1), ("B", 0, 0, 1),
                                                           ("Cy", 0, 1, 1), ("G", 0, 1, 0), ("Yl", 1, 1, 0)]
        return colours.map { name, r, g, b in
            let c = matrix.chroma(r * a, g * a, b * a)
            return ScopeTarget(name: name, red: r * a, green: g * a, blue: b * a, cb: c.cb, cr: c.cr)
        }
    }

    /// Angle (radians, counter-clockwise from +Cb) of the skin-tone line: the NTSC +I axis of Rec. ITU-R BT.470-6
    /// § 2.5, `E'Q = 0.41 (E'B - E'Y) + 0.48 (E'R - E'Y) = 0` with `E'I > 0`, plotted in this matrix's Cb/Cr plane.
    /// 134.8 degrees for BT.709; the familiar 123 degrees is the same axis in the composite U/V plane.
    public static func skinToneAngle(_ matrix: ScopeMatrix) -> Double {
        let bMinusY = -0.48 / 0.41, rMinusY = 1.0
        return atan2(rMinusY / matrix.crDivisor, bMinusY / matrix.cbDivisor)
    }

    /// Rec. ITU-R BT.709-6 item 1.2: signal V of scene luminance L in 0...1.
    public static func bt709OETF(_ l: Double) -> Double {
        let x = min(1, max(0, l))
        return x < 0.018 ? 4.5 * x : 1.099 * pow(x, 0.45) - 0.099
    }
}
