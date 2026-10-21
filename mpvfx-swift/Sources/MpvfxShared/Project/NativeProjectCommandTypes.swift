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
// Command/result types shared by the keyframe and property commands (NativeProjectKeyframeCommands, NativeProjectPropertyCommands),
// plus the small exported helpers other files import from them (ids, routedPosition).
import Foundation

public struct NativeProjectParameterAddress: Codable, Equatable, Hashable, Sendable {
    public var sequenceId: String, trackId: String, clipId: String, parameterId: String
    public init(sequenceId: String, trackId: String, clipId: String, parameterId: String) {
        self.sequenceId = sequenceId; self.trackId = trackId; self.clipId = clipId; self.parameterId = parameterId
    }
}

/// NativeProjectAtomicKeyframeCommand. Upsert's `valueType` is kept explicitly; value/baseline
/// must match it (checked by the command appliers, valueMatchesType).
public enum NativeProjectAtomicKeyframeCommand: Equatable {
    case upsert(address: NativeProjectParameterAddress, valueType: NativeValueType, frame: Double,
                value: NativeParameterValue, baselineValue: NativeParameterValue, outgoing: NativeInterpolation? = nil)
    case updateValue(address: NativeProjectParameterAddress, frame: Double, value: NativeParameterValue)
    case delete(address: NativeProjectParameterAddress, frame: Double)
    case move(address: NativeProjectParameterAddress, fromFrame: Double, toFrame: Double)
    case moveMany(address: NativeProjectParameterAddress, frames: [Double], deltaFrames: Double)
    case deleteMany(address: NativeProjectParameterAddress, frames: [Double])
    case setOutgoing(address: NativeProjectParameterAddress, frame: Double, outgoing: NativeInterpolation)
    /// path nil = straight (no path).
    case setMotionPath(address: NativeProjectParameterAddress, frame: Double, path: NativeMotionPath?)
    case setAutoRotate(address: NativeProjectParameterAddress, autoRotate: Bool)

    public var type: String {
        switch self {
        case .upsert: "upsert"; case .updateValue: "update-value"; case .delete: "delete"; case .move: "move"
        case .moveMany: "move-many"; case .deleteMany: "delete-many"; case .setOutgoing: "set-outgoing"
        case .setMotionPath: "set-motion-path"; case .setAutoRotate: "set-auto-rotate"
        }
    }
    public var address: NativeProjectParameterAddress {
        switch self {
        case .upsert(let a, _, _, _, _, _), .updateValue(let a, _, _), .delete(let a, _), .move(let a, _, _),
             .moveMany(let a, _, _), .deleteMany(let a, _), .setOutgoing(let a, _, _), .setMotionPath(let a, _, _),
             .setAutoRotate(let a, _): a
        }
    }
}

public indirect enum NativeProjectKeyframeCommand: Equatable {
    case atomic(NativeProjectAtomicKeyframeCommand)
    case batch([NativeProjectAtomicKeyframeCommand])
    case restoreDocument(NativeProjectDocument)
}

public enum NativeProjectKeyframeFailureCode: String, Codable, Sendable {
    case missingSequence = "missing-sequence", missingTrack = "missing-track", missingClip = "missing-clip"
    case missingParameter = "missing-parameter", missingKeyframe = "missing-keyframe", invalidFrame = "invalid-frame"
    case invalidGroup = "invalid-group", frameCollision = "frame-collision", valueTypeMismatch = "value-type-mismatch"
    case frameRateMismatch = "frame-rate-mismatch", invalidValue = "invalid-value", invalidInterpolation = "invalid-interpolation"
    case positionComponentsMisaligned = "position-components-misaligned", documentMismatch = "document-mismatch"
}

public struct NativeProjectKeyframeFailure: Equatable, Error {
    public var code: NativeProjectKeyframeFailureCode
    public var message: String
    public init(code: NativeProjectKeyframeFailureCode, message: String) { self.code = code; self.message = message }
}

public enum NativeProjectKeyframeCommandResult: Equatable {
    case success(document: NativeProjectDocument, inverse: NativeProjectKeyframeCommand)
    /// `document` is the unchanged input.
    case failure(document: NativeProjectDocument, failure: NativeProjectKeyframeFailure)
}

/// NativeProjectAtomicPropertyCommand
public enum NativeProjectAtomicPropertyCommand: Equatable {
    case keyframe(NativeProjectAtomicKeyframeCommand)
    case setStatic(address: NativeProjectParameterAddress, value: NativeParameterValue)
    case offsetTrack(address: NativeProjectParameterAddress, delta: Double)
    case collapseTrack(address: NativeProjectParameterAddress, frame: Double)

    public var type: String {
        switch self {
        case .keyframe(let k): k.type; case .setStatic: "set-static"; case .offsetTrack: "offset-track"; case .collapseTrack: "collapse-track"
        }
    }
    public var address: NativeProjectParameterAddress {
        switch self {
        case .keyframe(let k): k.address
        case .setStatic(let a, _), .offsetTrack(let a, _), .collapseTrack(let a, _): a
        }
    }
}

public enum NativeProjectPropertyCommand: Equatable {
    case atomic(NativeProjectAtomicPropertyCommand)
    case batch([NativeProjectAtomicPropertyCommand])
}

public enum NativeProjectPropertyCommandResult: Equatable {
    case success(document: NativeProjectDocument)
    case failure(document: NativeProjectDocument, failure: NativeProjectKeyframeFailure)
}

private func stableIdPart(_ v: String) -> String { "\(v.utf16.count):\(v)" }

public func nativeParameterTrackId(clipId: String, parameterId: String) -> String {
    "native-parameter:\(stableIdPart(clipId))|\(stableIdPart(parameterId))"
}
public func nativeParameterKeyframeId(parameterTrackId: String, frame: Double) -> String {
    "native-keyframe:\(stableIdPart(parameterTrackId))|frame:\(jsNumberString(frame))"
}

/// x/y address routed onto a vec2 position track, when no scalar track of that id exists.
public func routedPosition(_ clip: NativeProjectClip, parameterId: String) -> (track: NativeParameterTrack, component: PositionComponent)? {
    guard let component = positionComponentOf(parameterId) else { return nil }
    if clip.parameterTracks.contains(where: { $0.parameterId == parameterId }) { return nil }
    guard let track = findVec2PositionTrack(clip.parameterTracks) else { return nil }
    return (track, component)
}
