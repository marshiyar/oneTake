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

/// False colour: each pixel painted by the exposure band its luma falls in. There is no standard for the bands;
/// this is the product's convention (`docs/SCOPES.md`): the two exposure references are derived from the BT.709
/// transfer function (Rec. ITU-R BT.709-6 item 1.2) at 18 % reflectance (middle grey) and one stop above it
/// (36 %, where lit skin usually sits), each +-1/3 stop wide; the rest are fixed signal levels.
public enum FalseColor {
    public struct Band: Sendable, Equatable {
        public let name: String
        /// Signal range `lower ..< upper` (the last band includes 1).
        public let lower: Double, upper: Double
        public let red: UInt8, green: UInt8, blue: UInt8
    }

    /// The bands, darkest first. Levels between bands show the pixel's luma as grey.
    public static let bands: [Band] = {
        let third = pow(2, 1.0 / 3)
        func stop(_ reflectance: Double) -> (Double, Double) {
            (ScopeTargets.bt709OETF(reflectance / third), ScopeTargets.bt709OETF(reflectance * third))
        }
        let grey = stop(0.18), skin = stop(0.36)
        return [
            Band(name: "Crushed", lower: 0, upper: 0.02, red: 128, green: 0, blue: 160),
            Band(name: "Near black", lower: 0.02, upper: 0.10, red: 0, green: 72, blue: 255),
            Band(name: "Middle grey", lower: grey.0, upper: grey.1, red: 0, green: 200, blue: 70),
            Band(name: "Skin", lower: skin.0, upper: skin.1, red: 255, green: 120, blue: 190),
            Band(name: "Near clip", lower: 0.90, upper: 0.98, red: 255, green: 225, blue: 0),
            Band(name: "Clipped", lower: 0.98, upper: 1, red: 255, green: 0, blue: 0),
        ]
    }()

    /// The band signal `luma` (0...1) falls in, nil between bands.
    public static func band(forLuma luma: Double) -> Band? {
        bands.first { luma >= $0.lower && (luma < $0.upper || $0.upper >= 1) }
    }

    /// The frame in false colour (RGBA8, the frame's alpha kept), luma through `matrix`.
    public static func map(_ frame: ScopeFrame, matrix: ScopeMatrix = .rec709) -> [UInt8] {
        let table = levelTable()
        let w = matrix.decimalWeights
        var out = [UInt8](repeating: 0, count: frame.rgba.count)
        frame.rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for o in stride(from: 0, to: src.count, by: 4) {
                    let y = ScopeMatrix.lumaLevel(w, Int(src[o]), Int(src[o + 1]), Int(src[o + 2]))
                    dst[o] = table[y * 3]; dst[o + 1] = table[y * 3 + 1]; dst[o + 2] = table[y * 3 + 2]
                    dst[o + 3] = src[o + 3]
                }
            }
        }
        return out
    }

    /// RGB for each of the 256 luma levels.
    static func levelTable() -> [UInt8] {
        (0..<256).flatMap { level -> [UInt8] in
            let v = UInt8(level)
            guard let b = band(forLuma: Double(level) / 255) else { return [v, v, v] }
            return [b.red, b.green, b.blue]
        }
    }
}
