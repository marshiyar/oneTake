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
// The keyframe engine interface and its process-wide install slot.
// The implementation is KeyframeRuntime from the keyframe engine adapter OneTakeKeyframes (Engine/KeyframeRuntimeKeyframeEngine.swift).
import Foundation

public let VKF_ENGINE_API_VERSION = 1
public let VKF_MAX_MATERIALIZED_FRAMES: Double = 24 * 60 * 60 * 120

/// VkfTrack: what the engine needs from a track.
public struct VkfTrack: Equatable {
    public struct Key: Equatable {
        public var frame: Double; public var value: NativeParameterValue
        public var outgoing: NativeInterpolation; public var outgoingPath: NativeMotionPath?
        public init(frame: Double, value: NativeParameterValue, outgoing: NativeInterpolation, outgoingPath: NativeMotionPath? = nil) {
            self.frame = frame; self.value = value; self.outgoing = outgoing; self.outgoingPath = outgoingPath }
    }
    public var valueType: NativeValueType
    public var keyframes: [Key]
    public init(valueType: NativeValueType, keyframes: [Key]) { self.valueType = valueType; self.keyframes = keyframes }
    public init(_ track: NativeParameterTrack) {
        self.init(valueType: track.valueType, keyframes: track.keyframes.map {
            Key(frame: $0.frame, value: $0.value, outgoing: $0.outgoing, outgoingPath: $0.outgoingPath) })
    }
}

public struct VkfSlicedKey: Equatable {
    public var frame: Double; public var value: NativeParameterValue
    public var outgoing: NativeInterpolation; public var outgoingPath: NativeMotionPath?
    public var sourceFrame: Double; public var generated: Bool
    public init(frame: Double, value: NativeParameterValue, outgoing: NativeInterpolation, outgoingPath: NativeMotionPath? = nil, sourceFrame: Double, generated: Bool) {
        self.frame = frame; self.value = value; self.outgoing = outgoing; self.outgoingPath = outgoingPath; self.sourceFrame = sourceFrame; self.generated = generated
    }
}

/// Track rejection codes the engine raises.
public enum VkfTrackErrorCode: String, CaseIterable {
    case emptyTrack = "empty-track", invalidKeyframeFrame = "invalid-keyframe-frame"
    case duplicateKeyframeFrame = "duplicate-keyframe-frame", invalidValue = "invalid-value"
    case invalidInterpolation = "invalid-interpolation", invalidPath = "invalid-path"
}

/// Single error type for every engine failure, so a C layer returning (code, message)
/// maps onto it directly. `code` is one of VkfTrackErrorCode raw values (a track rejection)
/// or "limit-exceeded" (a size limit); any other code is an engine-internal failure.
public struct KeyframeEngineError: Error, Equatable, CustomStringConvertible {
    public static let limitExceeded = "limit-exceeded"
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var trackErrorCode: VkfTrackErrorCode? { VkfTrackErrorCode(rawValue: code) }
    public var isLimitError: Bool { code == Self.limitExceeded }
    public var description: String { message }
}

public struct VkfEngineNotLoadedError: Error, CustomStringConvertible {
    public var description: String { "The keyframe engine is not loaded in this process" }
}

/// The keyframe engine interface: validation, evaluation and slicing of parameter tracks.
public protocol KeyframeEngine: AnyObject {
    var version: String { get }
    /// Throws KeyframeEngineError (track code) when the engine rejects the track.
    func validate(_ track: VkfTrack) throws
    func evaluate(_ track: VkfTrack, frame: Double) throws -> NativeParameterValue
    /// Throws KeyframeEngineError("limit-exceeded") above VKF_MAX_MATERIALIZED_FRAMES.
    func sample(_ track: VkfTrack, firstFrame: Double, count: Int) throws -> [Double]
    func tangentAngle(_ track: VkfTrack, frame: Double) throws -> Double
    func slice(_ track: VkfTrack, fromFrame: Double, untilFrameExclusive: Double) throws -> [VkfSlicedKey]
}

/// One engine per process (installed at startup). Functions also accept an explicit engine.
private let engineLock = NSLock()
nonisolated(unsafe) private var installedEngine: KeyframeEngine?

public func installKeyframeEngine(_ engine: KeyframeEngine?) {
    engineLock.lock(); installedEngine = engine; engineLock.unlock()
}
public func keyframeEngine() throws -> KeyframeEngine {
    engineLock.lock(); defer { engineLock.unlock() }
    guard let e = installedEngine else { throw VkfEngineNotLoadedError() }
    return e
}
public func keyframeEngineInstalled() -> Bool {
    engineLock.lock(); defer { engineLock.unlock() }
    return installedEngine != nil
}
