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
// Test-only stand-in for the the keyframe engine engine. Plumbing only: it records calls, can be told to
// reject with a given (code, message), and NEVER computes interpolated values.
@testable import MpvfxShared

final class KeyframeEngineStandIn: KeyframeEngine {
    let version = "stand-in"
    var validateCalls: [VkfTrack] = []
    var rejectWith: KeyframeEngineError?
    struct NotAvailable: Error {}
    func validate(_ track: VkfTrack) throws { validateCalls.append(track); if let e = rejectWith { throw e } }
    /// Plumbing only: when set, evaluate returns this fixed opaque value for every call (shape-matched to the
    /// track's value type with NaN components), so callers' non-value logic can run. It never interpolates.
    var opaqueEvaluate = false
    var evaluateCalls: [(VkfTrack, Double)] = []
    func evaluate(_ track: VkfTrack, frame: Double) throws -> NativeParameterValue {
        evaluateCalls.append((track, frame))
        guard opaqueEvaluate else { throw NotAvailable() }
        switch track.valueType {
        case .number: return .number(.nan)
        case .vec2: return .vec2(.init(x: .nan, y: .nan))
        case .rgba: return .rgba(.init(red: .nan, green: .nan, blue: .nan, alpha: .nan))
        }
    }
    func sample(_ track: VkfTrack, firstFrame: Double, count: Int) throws -> [Double] { throw NotAvailable() }
    func tangentAngle(_ track: VkfTrack, frame: Double) throws -> Double { throw NotAvailable() }
    func slice(_ track: VkfTrack, fromFrame: Double, untilFrameExclusive: Double) throws -> [VkfSlicedKey] { throw NotAvailable() }
}

let cvkfSkipReason = "requires the keyframe engine engine (real interpolation/validation output); stand-in does not compute it"
