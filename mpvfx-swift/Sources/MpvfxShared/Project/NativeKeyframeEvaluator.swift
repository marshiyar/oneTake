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
// Evaluates a native parameter track at a project frame through the keyframe engine.
import Foundation

public struct NativeKeyframeEvaluationError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public func evaluateNativeParameterTrack(_ track: NativeParameterTrack, projectFrame: Double, engine: KeyframeEngine? = nil) throws -> NativeParameterValue {
    if !jsIsInteger(projectFrame) {
        throw NativeKeyframeEvaluationError(message: "Native keyframes must be evaluated at an integer project frame")
    }
    if track.keyframes.isEmpty {
        throw NativeKeyframeEvaluationError(message: "Native parameter track \(track.id) has no keyframes")
    }
    return try (engine ?? keyframeEngine()).evaluate(VkfTrack(track), frame: projectFrame)
}
