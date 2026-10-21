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

/// The luma and colour-difference matrix a scope reads R'G'B' through. Coefficients are the published ones:
/// Rec. ITU-R BT.709-6 items 3.2/3.3, BT.601-7 § 2.5.1/2.5.2 and BT.2020-2 Table 4 (links and fetch dates in
/// `docs/SCOPES.md`). Kg and both divisors are derived (`1 - Kr - Kb`, `2(1 - Kb)`, `2(1 - Kr)`), which reproduces
/// the published 1.8556/1.5748, 1.772/1.402 and 1.8814/1.4746.
public enum ScopeMatrix: String, CaseIterable, Sendable, Codable {
    case rec709, rec601, rec2020

    public var kr: Double {
        switch self { case .rec709: 0.2126; case .rec601: 0.299; case .rec2020: 0.2627 }
    }

    public var kb: Double {
        switch self { case .rec709: 0.0722; case .rec601: 0.114; case .rec2020: 0.0593 }
    }

    public var kg: Double { 1 - kr - kb }
    /// E'CB = (E'B - E'Y) / cbDivisor spans -0.5...+0.5.
    public var cbDivisor: Double { 2 * (1 - kb) }
    /// E'CR = (E'R - E'Y) / crDivisor spans -0.5...+0.5.
    public var crDivisor: Double { 2 * (1 - kr) }

    /// The name the scope settings show.
    public var label: String {
        switch self { case .rec709: "Rec. 709"; case .rec601: "Rec. 601"; case .rec2020: "Rec. 2020" }
    }

    /// The matrix a project or export colour-space name means (`rec709`, `bt709`, `smpte170m`, ...); nil when the
    /// name is not one of them, so the caller decides the default visibly.
    public init?(colorSpace name: String) {
        switch name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "") {
        case "rec709", "bt709": self = .rec709
        case "rec601", "bt601", "smpte170m", "bt470bg": self = .rec601
        case "rec2020", "bt2020", "bt2020nc": self = .rec2020
        default: return nil
        }
    }

    /// Luma E'Y of non-linear R'G'B' in 0...1.
    public func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { kr * r + kg * g + kb * b }

    /// Colour difference (E'CB, E'CR) of non-linear R'G'B' in 0...1, each within -0.5...+0.5.
    public func chroma(_ r: Double, _ g: Double, _ b: Double) -> (cb: Double, cr: Double) {
        let y = luma(r, g, b)
        return ((b - y) / cbDivisor, (r - y) / crDivisor)
    }

    /// The published luma weights in units of 1/10000. Every matrix here is published to at most four decimals and
    /// its weights sum to exactly 10000, so integer luma is the standard's own arithmetic: no rounding error, and a
    /// neutral grey has luma equal to its code value.
    public var decimalWeights: (r: Int, g: Int, b: Int) {
        (Int((kr * 10000).rounded()), Int((kg * 10000).rounded()), Int((kb * 10000).rounded()))
    }

    /// Luma level (0...255) of 8-bit codes from `decimalWeights`, rounded half up.
    @inline(__always)
    public static func lumaLevel(_ w: (r: Int, g: Int, b: Int), _ r: Int, _ g: Int, _ b: Int) -> Int {
        (w.r * r + w.g * g + w.b * b + 5000) / 10000
    }
}
