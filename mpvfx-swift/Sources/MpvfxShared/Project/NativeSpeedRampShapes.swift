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

/// Starting points for a clip's speed curve.
public enum NativeSpeedRampShape: String, CaseIterable, Sendable {
    case slowMiddle, slowStart, slowEnd, speedUp, slowDown, twoHits

    public var title: String {
        switch self {
        case .slowMiddle: "Slow middle"
        case .slowStart: "Slow start"
        case .slowEnd: "Slow end"
        case .speedUp: "Speed up"
        case .slowDown: "Slow down"
        case .twoHits: "Two hits"
        }
    }

    public func points(durationFrames: Double) -> [NativeSpeedRamp.Point] {
        guard durationFrames.isFinite, durationFrames >= 0 else { return [] }
        let shape: [(Double, Double)]
        switch self {
        case .slowMiddle: shape = [(0, 1), (0.3, 0.25), (0.7, 0.25), (1, 1)]
        case .slowStart: shape = [(0, 0.25), (0.5, 1), (1, 1)]
        case .slowEnd: shape = [(0, 1), (0.5, 1), (1, 0.25)]
        case .speedUp: shape = [(0, 1), (1, 4)]
        case .slowDown: shape = [(0, 1), (1, 0.25)]
        case .twoHits: shape = [(0, 1), (0.2, 1), (0.25, 0.2), (0.35, 1), (0.6, 1), (0.65, 0.2), (0.75, 1), (1, 1)]
        }
        var result: [NativeSpeedRamp.Point] = []
        for (fraction, speed) in shape {
            let t = fraction == 1 ? durationFrames : (fraction * durationFrames).rounded()
            guard t <= durationFrames else { continue }
            if fraction == 1 {
                while let last = result.last, last.t >= t { result.removeLast() }
            }
            if let last = result.last, last.t >= t { continue }
            result.append(.init(t: t, speed: speed))
        }
        return result
    }
}
