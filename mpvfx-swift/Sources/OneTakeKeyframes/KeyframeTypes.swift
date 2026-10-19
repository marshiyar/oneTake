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
// Value types of the keyframe engine adapter. Plain Swift values: the app converts its project model to these at the
// boundary, and KeyframeRuntime converts them to the C structs of cvkf.h.

extension KeyframeRuntime {
    /// Interface version of cvkf.h this adapter is written against (CVKF_API_VERSION).
    public static let expectedAPIVersion = 1
    /// Most frames one call may produce (`sample`, `sampleTangentAngle`): 24 hours at 120 fps.
    public static let maxMaterializedFrames: Double = 24 * 60 * 60 * 120

    /// Shape of every value in a track.
    public enum ValueType: String, Sendable, CaseIterable {
        case number, vec2, rgba

        /// Doubles per value.
        public var componentCount: Int {
            switch self {
            case .number: return 1
            case .vec2: return 2
            case .rgba: return 4
            }
        }
    }

    public struct Point: Equatable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public enum Value: Equatable, Hashable, Sendable {
        case number(Double)
        case vec2(x: Double, y: Double)
        case rgba(red: Double, green: Double, blue: Double, alpha: Double)
    }

    /// Timing of the segment that leaves a key.
    public enum Interpolation: Equatable, Hashable, Sendable {
        case hold
        case linear
        /// Timing curve through (0, 0), (x1, y1), (x2, y2), (1, 1).
        case cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double)
    }

    /// Spatial path of the segment that leaves a vec2 key; a key with no path moves in a straight line.
    public enum Path: Equatable, Hashable, Sendable {
        /// Smooth path through the neighbouring keys, handles scaled by `curviness`.
        case curve(curviness: Double)
        /// Explicit cubic handles.
        case bezier(cp1: Point, cp2: Point)
    }

    public struct Key: Equatable, Hashable, Sendable {
        /// Whole frame number.
        public var frame: Double
        public var value: Value
        public var outgoing: Interpolation
        public var outgoingPath: Path?
        public init(frame: Double, value: Value, outgoing: Interpolation, outgoingPath: Path? = nil) {
            self.frame = frame
            self.value = value
            self.outgoing = outgoing
            self.outgoingPath = outgoingPath
        }
    }

    public struct Track: Equatable, Hashable, Sendable {
        public var valueType: ValueType
        public var keyframes: [Key]
        public init(valueType: ValueType, keyframes: [Key]) {
            self.valueType = valueType
            self.keyframes = keyframes
        }
    }

    /// A key of a sliced track, rebased so the slice starts at frame 0.
    public struct SlicedKey: Equatable, Hashable, Sendable {
        public var frame: Double
        public var value: Value
        public var outgoing: Interpolation
        public var outgoingPath: Path?
        /// Frame of this key in the original track.
        public var sourceFrame: Double
        /// True when the engine added the key (a cut point or a baked segment), false for an original key.
        public var generated: Bool

        public init(frame: Double, value: Value, outgoing: Interpolation, outgoingPath: Path? = nil,
                    sourceFrame: Double, generated: Bool) {
            self.frame = frame
            self.value = value
            self.outgoing = outgoing
            self.outgoingPath = outgoingPath
            self.sourceFrame = sourceFrame
            self.generated = generated
        }

        /// The key as an input key, to build a track from a slice.
        public var key: Key { Key(frame: frame, value: value, outgoing: outgoing, outgoingPath: outgoingPath) }
    }

    /// A refusal or failure reported by the engine. `code` is the engine's stable status id (cvkf_status_code).
    public struct EngineError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let emptyTrack = "empty-track"
        public static let invalidKeyframeFrame = "invalid-keyframe-frame"
        public static let duplicateKeyframeFrame = "duplicate-keyframe-frame"
        public static let invalidValue = "invalid-value"
        public static let invalidInterpolation = "invalid-interpolation"
        public static let invalidPath = "invalid-path"
        public static let limitExceeded = "limit-exceeded"
        public static let invalidArgument = "invalid-argument"
        public static let engineInternal = "engine-internal"

        /// Codes that mean the track itself is invalid (as opposed to a limit, an argument or an internal failure).
        public static let trackCodes: Set<String> = [emptyTrack, invalidKeyframeFrame, duplicateKeyframeFrame,
                                                     invalidValue, invalidInterpolation, invalidPath]

        public let code: String
        public let message: String
        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }

        public var isTrackError: Bool { Self.trackCodes.contains(code) }
        public var isLimitError: Bool { code == Self.limitExceeded }
        public var description: String { message }
    }
}
