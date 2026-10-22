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

/// A continuous soft knee whose width is expressed in dB.
internal func currentKneeGain(_ input: Double, _ threshold: Double, _ ratio: Double, _ width: Double) -> Double {
    let over: Double = input - threshold
    let half: Double = width / 2
    if width > 0, abs(over) < half {
        return (1 / ratio - 1) * pow(over + half, 2) / (2 * width)
    }
    return over > 0 ? over * (1 / ratio - 1) : 0
}
