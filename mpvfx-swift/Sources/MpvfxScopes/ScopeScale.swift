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

/// How waveform and histogram levels are labelled. Both scales place a signal value at the same height; only the
/// numbers differ. `code10` is the BT.709 10-bit coding of the value (Rec. ITU-R BT.709-6 item 3.4,
/// `D = INT[(219 E + 16) 4]` = `INT[876 E + 64]`; item 4.6: black 64, nominal peak 940).
public enum ScopeScale: String, CaseIterable, Sendable, Codable {
    /// 0...100, the signal as a percentage of nominal peak (IRE-style units).
    case percent
    /// 64...940, BT.709 10-bit code values.
    case code10

    /// One graticule line at signal `value` (0 = black, 1 = nominal peak).
    public struct Line: Sendable, Equatable {
        public let value: Double
        public let label: String?
        /// 0 and 100 % (black and nominal peak) are drawn stronger.
        public let major: Bool
    }

    public var label: String { self == .percent ? "%" : "10-bit" }

    /// The lines of the scale, bottom to top.
    public var lines: [Line] {
        switch self {
        case .percent:
            return (0...10).map { (i: Int) -> Line in
                let label: String? = i % 2 == 0 ? String(i * 10) : nil
                return Line(value: Double(i) / 10, label: label, major: i == 0 || i == 10)
            }
        case .code10:
            let codes = [64, 128, 256, 384, 512, 640, 768, 896, 940]
            let labelled: Set<Int> = [64, 256, 512, 768, 940]
            return codes.map { (c: Int) -> Line in
                let label: String? = labelled.contains(c) ? String(c) : nil
                return Line(value: Double(c - 64) / 876, label: label, major: c == 64 || c == 940)
            }
        }
    }

    /// BT.709 10-bit code of signal `value` (rounded half up, as INT does).
    public static func code10(_ value: Double) -> Int {
        Int((876 * min(1, max(0, value)) + 64).rounded(.toNearestOrAwayFromZero))
    }

    /// The number shown for signal `value` on this scale.
    public func text(for value: Double) -> String {
        self == .percent ? String(format: "%.1f", min(1, max(0, value)) * 100) : "\(Self.code10(value))"
    }
}
