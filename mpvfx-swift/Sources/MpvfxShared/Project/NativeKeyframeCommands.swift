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
// Keyframe commands on one parameter track (insert, upsert, update, move, ease, delete). Values are Swift value types, so
// edits work on plain copies. `throws` only for non-validation engine errors.
import Foundation

public enum NativeKeyframeCommandFailureCode: String, Codable {
    case missingKeyframe = "missing-keyframe", duplicateKeyframeId = "duplicate-keyframe-id", frameCollision = "frame-collision"
    case invalidFrame = "invalid-frame", invalidGroup = "invalid-group", invalidValue = "invalid-value"
    case invalidInterpolation = "invalid-interpolation", emptyTrack = "empty-track", trackMismatch = "track-mismatch"
}

public struct NativeKeyframeCommandFailure: Equatable {
    public var code: NativeKeyframeCommandFailureCode; public var message: String
    public init(code: NativeKeyframeCommandFailureCode, message: String) { self.code = code; self.message = message }
}

public indirect enum NativeKeyframeCommand: Equatable {
    case insert(NativeKeyframe)
    /// Replaces the key at this exact frame, preserving its ID, or inserts if vacant.
    case upsert(NativeKeyframe)
    case updateValue(keyframeId: String, value: NativeParameterValue)
    case move(keyframeId: String, toFrame: Double)
    case moveGroup(keyframeIds: [String], deltaFrames: Double)
    case delete(keyframeId: String)
    case deleteGroup(keyframeIds: [String])
    case setOutgoing(keyframeId: String, outgoing: NativeInterpolation)
    case restoreTrack(NativeParameterTrack)
}

public enum NativeKeyframeCommandResult: Equatable {
    case success(track: NativeParameterTrack, inverse: NativeKeyframeCommand)
    /// `track` is the unchanged input.
    case rejected(track: NativeParameterTrack, failure: NativeKeyframeCommandFailure)
    public var ok: Bool { if case .success = self { return true }; return false }
    public var track: NativeParameterTrack { switch self { case .success(let t, _), .rejected(let t, _): t } }
    public var failure: NativeKeyframeCommandFailure? { if case .rejected(_, let f) = self { return f }; return nil }
}

private func trackInput(_ t: NativeParameterTrack, _ keyframes: [NativeKeyframe]) -> NativeParameterTrackInput {
    NativeParameterTrackInput(id: t.id, parameterId: t.parameterId, valueType: t.valueType, frameRate: t.frameRate,
                              keyframes: keyframes, autoRotate: t.autoRotate)
}

private func reject(_ t: NativeParameterTrack, _ code: NativeKeyframeCommandFailureCode, _ m: String) -> NativeKeyframeCommandResult {
    .rejected(track: t, failure: .init(code: code, message: m))
}

private func succeed(_ original: NativeParameterTrack, _ track: NativeParameterTrack, _ engine: KeyframeEngine?) throws -> NativeKeyframeCommandResult {
    .success(track: track, inverse: .restoreTrack(try createNativeParameterTrack(trackInput(original, original.keyframes.map { $0.jsClone() }), engine: engine)))
}

private func mapValidationFailure(_ e: NativeKeyframeValidationError) -> NativeKeyframeCommandFailure {
    switch e.code {
    case .duplicateKeyframeId: .init(code: .duplicateKeyframeId, message: e.message)
    case .duplicateKeyframeFrame: .init(code: .frameCollision, message: e.message)
    case .invalidKeyframeFrame: .init(code: .invalidFrame, message: e.message)
    case .invalidInterpolation: .init(code: .invalidInterpolation, message: e.message)
    case .emptyTrack: .init(code: .emptyTrack, message: e.message)
    default: .init(code: .invalidValue, message: e.message)
    }
}

private func rebuild(_ original: NativeParameterTrack, _ keyframes: [NativeKeyframe], _ engine: KeyframeEngine?) throws -> NativeKeyframeCommandResult {
    let track: NativeParameterTrack
    do { track = try createNativeParameterTrack(trackInput(original, keyframes), engine: engine) }
    catch let e as NativeKeyframeValidationError { let f = mapValidationFailure(e); return reject(original, f.code, f.message) }
    return try succeed(original, track, engine)
}

private func validateFrame(_ t: NativeParameterTrack, _ frame: Double) -> NativeKeyframeCommandResult? {
    if !jsIsInteger(frame) || frame < 0 { return reject(t, .invalidFrame, "Keyframe time must be a non-negative integer project frame") }
    return nil
}

private func validateGroup(_ t: NativeParameterTrack, _ ids: [String]) -> NativeKeyframeCommandResult? {
    if ids.isEmpty { return reject(t, .invalidGroup, "A keyframe group must contain at least one ID") }
    if Set(ids).count != ids.count { return reject(t, .invalidGroup, "A keyframe group must not contain duplicate IDs") }
    let available = Set(t.keyframes.map(\.id))
    // `if (missingId)`: an empty-string ID is falsy, so a missing "" is not reported here (rebuild rejects it instead).
    if let missing = ids.first(where: { !available.contains($0) }), !missing.isEmpty {
        return reject(t, .missingKeyframe, "Keyframe \(missing) does not exist")
    }
    return nil
}

public func applyNativeKeyframeCommand(_ track: NativeParameterTrack, _ command: NativeKeyframeCommand,
                                       engine: KeyframeEngine? = nil) throws -> NativeKeyframeCommandResult {
    let keys = track.keyframes
    func missing(_ id: String) -> NativeKeyframeCommandResult { reject(track, .missingKeyframe, "Keyframe \(id) does not exist") }
    switch command {
    case .restoreTrack(let t):
        if t.id != track.id || t.parameterId != track.parameterId || t.valueType != track.valueType ||
            t.frameRate.numerator != track.frameRate.numerator || t.frameRate.denominator != track.frameRate.denominator {
            return reject(track, .trackMismatch, "An inverse can only restore the track it was created for")
        }
        // cloneTrack(command.track): every keyframe goes through cloneKeyframe.
        return try succeed(track, try createNativeParameterTrack(trackInput(t, t.keyframes.map { $0.jsClone() }), engine: engine), engine)

    case .insert(let k):
        if let bad = validateFrame(track, k.frame) { return bad }
        if keys.contains(where: { $0.id == k.id }) { return reject(track, .duplicateKeyframeId, "Keyframe ID \(k.id) already exists") }
        if keys.contains(where: { $0.frame == k.frame }) {
            return reject(track, .frameCollision, "Project frame \(jsNumberString(k.frame)) already contains a keyframe")
        }
        return try rebuild(track, keys + [k.jsClone()], engine)

    case .upsert(let k):
        if let bad = validateFrame(track, k.frame) { return bad }
        guard let occupied = keys.first(where: { $0.frame == k.frame }) else {
            if keys.contains(where: { $0.id == k.id }) { return reject(track, .duplicateKeyframeId, "Keyframe ID \(k.id) already exists") }
            return try rebuild(track, keys + [k.jsClone()], engine)
        }
        return try rebuild(track, keys.map { $0.id == occupied.id ? { var n = k.jsClone(); n.id = occupied.id; return n }() : $0 }, engine)

    case .updateValue(let id, let value):
        if !keys.contains(where: { $0.id == id }) { return missing(id) }
        return try rebuild(track, keys.map { var k = $0; if k.id == id { k.value = value }; return k }, engine)

    case .move(let id, let toFrame):
        if let bad = validateFrame(track, toFrame) { return bad }
        if !keys.contains(where: { $0.id == id }) { return missing(id) }
        if keys.contains(where: { $0.id != id && $0.frame == toFrame }) {
            return reject(track, .frameCollision, "Project frame \(jsNumberString(toFrame)) is occupied")
        }
        return try rebuild(track, keys.map { var k = $0; if k.id == id { k.frame = toFrame }; return k }, engine)

    case .moveGroup(let ids, let delta):
        if let bad = validateGroup(track, ids) { return bad }
        if !jsIsInteger(delta) { return reject(track, .invalidFrame, "Group movement must use an integer frame delta") }
        let moving = Set(ids)
        let stationary = Set(keys.filter { !moving.contains($0.id) }.map(\.frame))
        for k in keys where moving.contains(k.id) {
            let destination = k.frame + delta
            if let bad = validateFrame(track, destination) { return bad }
            if stationary.contains(destination) { return reject(track, .frameCollision, "Project frame \(jsNumberString(destination)) is occupied") }
        }
        return try rebuild(track, keys.map { var k = $0; if moving.contains(k.id) { k.frame += delta }; return k }, engine)

    case .delete(let id):
        return try deleteGroup(track, [id], engine)
    case .deleteGroup(let ids):
        return try deleteGroup(track, ids, engine)

    case .setOutgoing(let id, let outgoing):
        if !keys.contains(where: { $0.id == id }) { return missing(id) }
        return try rebuild(track, keys.map { var k = $0; if k.id == id { k.outgoing = outgoing }; return k }, engine)
    }
}

private func deleteGroup(_ track: NativeParameterTrack, _ ids: [String], _ engine: KeyframeEngine?) throws -> NativeKeyframeCommandResult {
    if let bad = validateGroup(track, ids) { return bad }
    let deleted = Set(ids)
    return try rebuild(track, track.keyframes.filter { !deleted.contains($0.id) }, engine)
}
