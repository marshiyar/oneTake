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

/// How the rack shows and reads an effect's numbers: the value in the knob's own unit (the unit is drawn beside it).
public enum AfxValueFormat {
    /// Keys whose value is a boost or cut: shown with its sign.
    static let signed: Set<String> = ["gain", "makeup", "output", "level_out", "semitones"]

    /// The step's decimals, or more for a value below 1 that the step would round away (an attack of 0.05 ms reads
    /// "0.05", not "0.1"; a release of 0.5 ms reads "0.50", not "1").
    public static func decimals(_ v: Double, step: Double) -> Int {
        let base = step >= 1 ? 0 : step >= 0.1 ? 1 : 2
        return v != 0 && abs(v) < 1 ? max(base, 2) : base
    }

    public static func text(_ v: Double, key: String, step: Double) -> String {
        let s = String(format: "%.\(decimals(v, step: step))f", v)
        return signed.contains(key) && v > 0 ? "+" + s : s
    }

    /// A typed value, with or without its unit: "1.2k" and "1.2 kHz" are 1200, "250 Hz", "-3 dB" (or "−3dB"), "12 ms",
    /// "4:1", "+5 st", "8 bit", "4x". Nil when no number is left.
    public static func parse(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "−", with: "-")
        var scale = 1.0
        for (suffix, k) in [("khz", 1000.0), ("hz", 1), ("ms", 1), ("db", 1), (":1", 1), ("st", 1), ("bit", 1), ("x", 1), ("k", 1000)]
        where t.hasSuffix(suffix) {
            t.removeLast(suffix.count); scale = k
            break
        }
        guard let v = Double(t.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        return v * scale
    }
}
