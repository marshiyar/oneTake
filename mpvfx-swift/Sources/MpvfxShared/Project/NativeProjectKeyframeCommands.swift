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
// Keyframe commands on a native document. Command/result types live in NativeProjectCommandTypes.swift.
// The appliers `throw` only for a re-parse failure outside the upsert-create try or a non-validation
// engine error); every rejected edit is a `.failure` result carrying the unchanged input document.
import Foundation

extension NativeProjectKeyframeCommandResult {
    public var ok: Bool { if case .success = self { return true }; return false }
    public var document: NativeProjectDocument { switch self { case .success(let d, _), .failure(let d, _): d } }
    public var failure: NativeProjectKeyframeFailure? { if case .failure(_, let f) = self { return f }; return nil }
    public var inverse: NativeProjectKeyframeCommand? { if case .success(_, let i) = self { return i }; return nil }
}

/// valueMatchesType: Swift values are typed, so only the case is checked.
func valueMatchesType(_ t: NativeValueType, _ v: NativeParameterValue) -> Bool {
    switch (t, v) { case (.number, .number), (.vec2, .vec2), (.rgba, .rgba): true; default: false }
}

/// parseNativeProjectDocument(JSON.parse(serializeNativeProjectDocument(document))).
func cloneNativeDocument(_ d: NativeProjectDocument, _ engine: KeyframeEngine?) throws -> NativeProjectDocument {
    try parseNativeProjectDocument(d, engine: engine)
}

func keyframeReject(_ d: NativeProjectDocument, _ code: NativeProjectKeyframeFailureCode, _ m: String) -> NativeProjectKeyframeCommandResult {
    .failure(document: d, failure: .init(code: code, message: m))
}

func keyframeSucceed(_ original: NativeProjectDocument, _ d: NativeProjectDocument, _ engine: KeyframeEngine?) throws -> NativeProjectKeyframeCommandResult {
    .success(document: d, inverse: .restoreDocument(try cloneNativeDocument(original, engine)))
}

struct LocatedClip { let trackIndex: Int; let clipIndex: Int; let clip: NativeProjectClip }

func locateClip(_ d: NativeProjectDocument, _ a: NativeProjectParameterAddress) -> Result<LocatedClip, NativeProjectKeyframeFailure> {
    if d.sequence.id != a.sequenceId { return .failure(.init(code: .missingSequence, message: "Sequence \(a.sequenceId) does not exist")) }
    guard let t = d.sequence.tracks.firstIndex(where: { $0.id == a.trackId }) else {
        return .failure(.init(code: .missingTrack, message: "Track \(a.trackId) does not exist"))
    }
    guard let c = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == a.clipId }) else {
        return .failure(.init(code: .missingClip, message: "Clip \(a.clipId) does not exist"))
    }
    return .success(LocatedClip(trackIndex: t, clipIndex: c, clip: d.sequence.tracks[t].clips[c]))
}

func invalidClipFrame(_ clip: NativeProjectClip, _ frame: Double) -> NativeProjectKeyframeFailure? {
    if !jsIsInteger(frame) || frame < 0 || frame >= clip.durationFrames {
        return .init(code: .invalidFrame, message: "Frame must be an integer in clip-local range 0 <= frame < \(jsNumberString(clip.durationFrames))")
    }
    return nil
}

func replaceParameterTracks(_ d: NativeProjectDocument, _ loc: LocatedClip, _ tracks: [NativeParameterTrack],
                            _ engine: KeyframeEngine?) throws -> NativeProjectDocument {
    var next = d
    var clip = next.sequence.tracks[loc.trackIndex].clips[loc.clipIndex]
    let previous = clip.parameterTracks
    clip.parameterTracks = tracks
    clip.cropPivotSegments = currentNativeCropPivotReferences(validNativeCropPivotSegments(clip.cropPivotSegments, tracks: tracks),
                                                              before: previous, after: tracks)
    next.sequence.tracks[loc.trackIndex].clips[loc.clipIndex] = clip
    return try parseNativeProjectDocument(next, engine: engine)
}

func mapTrackFailure(_ d: NativeProjectDocument, _ code: String, _ message: String) -> NativeProjectKeyframeCommandResult {
    let mapped: NativeProjectKeyframeFailureCode = switch code {
    case "missing-keyframe": .missingKeyframe; case "invalid-frame": .invalidFrame; case "frame-collision": .frameCollision
    case "invalid-group": .invalidGroup; case "invalid-interpolation": .invalidInterpolation; default: .invalidValue
    }
    return keyframeReject(d, mapped, message)
}

/// Editors send position edits as an x/y pair. On a vec2 position the structural halves (move, delete, easing,
/// collapse) are one edit, so a batch applies each signature once. The signature is
/// the command with `address.parameterId` cleared (a NaN never merges with null,
/// as a JSON text signature would).
func positionPairSignature(_ d: NativeProjectDocument, _ command: NativeProjectAtomicPropertyCommand) -> NativeProjectAtomicPropertyCommand? {
    switch command {
    case .setStatic, .offsetTrack: return nil
    case .keyframe(let k): if case .upsert = k { return nil }; if case .updateValue = k { return nil }
    case .collapseTrack: break
    }
    guard case .success(let loc) = locateClip(d, command.address), routedPosition(loc.clip, parameterId: command.address.parameterId) != nil else { return nil }
    var a = command.address; a.parameterId = ""
    return command.withAddress(a)
}

extension NativeProjectAtomicKeyframeCommand {
    func withAddress(_ a: NativeProjectParameterAddress) -> Self {
        switch self {
        case let .upsert(_, t, f, v, b, o): .upsert(address: a, valueType: t, frame: f, value: v, baselineValue: b, outgoing: o)
        case let .updateValue(_, f, v): .updateValue(address: a, frame: f, value: v)
        case let .delete(_, f): .delete(address: a, frame: f)
        case let .move(_, f, t): .move(address: a, fromFrame: f, toFrame: t)
        case let .moveMany(_, fs, d): .moveMany(address: a, frames: fs, deltaFrames: d)
        case let .deleteMany(_, fs): .deleteMany(address: a, frames: fs)
        case let .setOutgoing(_, f, o): .setOutgoing(address: a, frame: f, outgoing: o)
        case let .setMotionPath(_, f, p): .setMotionPath(address: a, frame: f, path: p)
        case let .setAutoRotate(_, r): .setAutoRotate(address: a, autoRotate: r)
        }
    }
}
extension NativeProjectAtomicPropertyCommand {
    func withAddress(_ a: NativeProjectParameterAddress) -> Self {
        switch self {
        case .keyframe(let k): .keyframe(k.withAddress(a))
        case .setStatic(_, let v): .setStatic(address: a, value: v)
        case .offsetTrack(_, let d): .offsetTrack(address: a, delta: d)
        case .collapseTrack(_, let f): .collapseTrack(address: a, frame: f)
        }
    }
}

func applyAtomicKeyframe(_ d: NativeProjectDocument, _ command: NativeProjectAtomicKeyframeCommand,
                         _ engine: KeyframeEngine?) throws -> NativeProjectKeyframeCommandResult {
    let loc: LocatedClip
    switch locateClip(d, command.address) { case .failure(let f): return keyframeReject(d, f.code, f.message); case .success(let l): loc = l }
    switch command {
    case .setMotionPath, .setAutoRotate: return try applyPositionPathCommand(d, loc, command, engine)
    default: break
    }
    if let routed = routedPosition(loc.clip, parameterId: command.address.parameterId) {
        return try applyToVec2Position(d, loc, routed.track, routed.component, command, engine)
    }
    let address = command.address
    let frames: [Double]
    switch command {
    case let .move(_, from, to): frames = [from, to]
    case let .moveMany(_, fs, delta): frames = fs + fs.map { $0 + delta }
    case let .deleteMany(_, fs): frames = fs
    case let .upsert(_, _, f, _, _, _), let .updateValue(_, f, _), let .delete(_, f), let .setOutgoing(_, f, _): frames = [f]
    case .setMotionPath, .setAutoRotate: frames = []
    }
    switch command {
    case let .moveMany(_, fs, _), let .deleteMany(_, fs):
        if fs.isEmpty || Set(fs).count != fs.count { return keyframeReject(d, .invalidGroup, "A keyframe group must contain unique frame identities") }
    default: break
    }
    if case let .moveMany(_, _, delta) = command, !jsIsInteger(delta) {
        return keyframeReject(d, .invalidFrame, "Multi-keyframe movement requires an integer frame delta")
    }
    for f in frames { if let bad = invalidClipFrame(loc.clip, f) { return keyframeReject(d, bad.code, bad.message) } }

    let parameterIndex = loc.clip.parameterTracks.firstIndex { $0.parameterId == address.parameterId }
    let parameterTrack = parameterIndex.map { loc.clip.parameterTracks[$0] }

    if case let .upsert(_, valueType, frame, value, baseline, outgoing) = command {
        if !valueMatchesType(valueType, value) || !valueMatchesType(valueType, baseline) {
            return keyframeReject(d, .valueTypeMismatch, "Parameter \(address.parameterId) values do not match \(valueType.rawValue)")
        }
        if parameterTrack == nil {
            let trackId = nativeParameterTrackId(clipId: address.clipId, parameterId: address.parameterId)
            do {
                let created = try createNativeParameterTrack(.init(id: trackId, parameterId: address.parameterId, valueType: valueType,
                    frameRate: d.frameRate, keyframes: [.init(id: nativeParameterKeyframeId(parameterTrackId: trackId, frame: frame),
                                                              frame: frame, value: value, outgoing: outgoing ?? .linear)]), engine: engine)
                return try keyframeSucceed(d, try replaceParameterTracks(d, loc, loc.clip.parameterTracks + [created], engine), engine)
            } catch {
                // Everything is caught here, including a re-parse failure.
                let code: NativeProjectKeyframeFailureCode = (error as? NativeKeyframeValidationError)?.code == .invalidInterpolation ? .invalidInterpolation : .invalidValue
                return keyframeReject(d, code, errorMessage(error) ?? "Invalid parameter value")
            }
        }
    }
    guard let parameterTrack, let parameterIndex else {
        return keyframeReject(d, .missingParameter, "Parameter \(address.parameterId) does not exist on clip \(address.clipId)")
    }
    if parameterTrack.frameRate.numerator != d.frameRate.numerator || parameterTrack.frameRate.denominator != d.frameRate.denominator {
        return keyframeReject(d, .frameRateMismatch, "Parameter \(address.parameterId) frame rate does not match the project")
    }
    if case let .upsert(_, valueType, _, _, _, _) = command, parameterTrack.valueType != valueType {
        return keyframeReject(d, .valueTypeMismatch, "Parameter \(address.parameterId) uses \(parameterTrack.valueType.rawValue), not \(valueType.rawValue)")
    }
    if case let .updateValue(_, _, value) = command, !valueMatchesType(parameterTrack.valueType, value) {
        return keyframeReject(d, .valueTypeMismatch, "Parameter \(address.parameterId) value does not match \(parameterTrack.valueType.rawValue)")
    }
    func keyAt(_ f: Double) -> NativeKeyframe? { parameterTrack.keyframes.first { $0.frame == f } }
    func noKey(_ f: Double) -> NativeProjectKeyframeCommandResult { keyframeReject(d, .missingKeyframe, "Frame \(jsNumberString(f)) has no keyframe") }
    func dropTrack() throws -> NativeProjectKeyframeCommandResult {
        var tracks = loc.clip.parameterTracks; tracks.remove(at: parameterIndex)
        return try keyframeSucceed(d, try replaceParameterTracks(d, loc, tracks, engine), engine)
    }
    let trackCommand: NativeKeyframeCommand
    switch command {
    case let .upsert(_, _, frame, value, _, outgoing):
        let existing = keyAt(frame)
        trackCommand = .upsert(.init(id: existing?.id ?? nativeParameterKeyframeId(parameterTrackId: parameterTrack.id, frame: frame),
                                     frame: frame, value: value, outgoing: outgoing ?? existing?.outgoing ?? .linear))
    case let .updateValue(_, frame, value):
        guard let existing = keyAt(frame) else { return noKey(frame) }
        trackCommand = .updateValue(keyframeId: existing.id, value: value)
    case let .delete(_, frame):
        guard let existing = keyAt(frame) else { return noKey(frame) }
        if parameterTrack.keyframes.count == 1 { return try dropTrack() }
        trackCommand = .delete(keyframeId: existing.id)
    case let .move(_, from, to):
        guard let existing = keyAt(from) else { return noKey(from) }
        trackCommand = .move(keyframeId: existing.id, toFrame: to)
    case let .moveMany(_, fs, delta):
        let keys = fs.map(keyAt)
        if let i = keys.firstIndex(where: { $0 == nil }) { return noKey(fs[i]) }
        trackCommand = .moveGroup(keyframeIds: keys.map { $0!.id }, deltaFrames: delta)
    case let .deleteMany(_, fs):
        let keys = fs.map(keyAt)
        if let i = keys.firstIndex(where: { $0 == nil }) { return noKey(fs[i]) }
        if keys.count == parameterTrack.keyframes.count { return try dropTrack() }
        trackCommand = .deleteGroup(keyframeIds: keys.map { $0!.id })
    case let .setOutgoing(_, frame, outgoing):
        guard let existing = keyAt(frame) else { return noKey(frame) }
        trackCommand = .setOutgoing(keyframeId: existing.id, outgoing: outgoing)
    case .setMotionPath, .setAutoRotate: fatalError("handled above")
    }
    let result = try applyNativeKeyframeCommand(parameterTrack, trackCommand, engine: engine)
    guard case .success(let track, _) = result else { return mapTrackFailure(d, result.failure!.code.rawValue, result.failure!.message) }
    var tracks = loc.clip.parameterTracks; tracks[parameterIndex] = track
    return try keyframeSucceed(d, try replaceParameterTracks(d, loc, tracks, engine), engine)
}

/// `error instanceof Error ? error.message : fallback` for the error types this module produces.
func errorMessage(_ error: Error) -> String? {
    switch error {
    case let e as NativeKeyframeValidationError: e.message
    case let e as KeyframeEngineError: e.message
    case let e as NativeProjectDocumentValidationError: e.message
    case let e as NativeSourceTimeRangeError: e.message
    case let e as VkfEngineNotLoadedError: e.description
    case let e as NativePlayheadError: e.message
    default: nil
    }
}

public func applyNativeProjectKeyframeCommand(_ d: NativeProjectDocument, _ command: NativeProjectKeyframeCommand,
                                              engine: KeyframeEngine? = nil) throws -> NativeProjectKeyframeCommandResult {
    switch command {
    case .restoreDocument(let restored):
        if restored.id != d.id { return keyframeReject(d, .documentMismatch, "An inverse can only restore its source project") }
        return try keyframeSucceed(d, try cloneNativeDocument(restored, engine), engine)
    case .atomic(let c): return try applyAtomicKeyframe(d, c, engine)
    case .batch(let commands):
        var applied: [NativeProjectAtomicPropertyCommand] = []
        var next = d
        for child in commands {
            if let signature = positionPairSignature(d, .keyframe(child)) {
                if applied.contains(signature) { continue }
                applied.append(signature)
            }
            let r = try applyAtomicKeyframe(next, child, engine)
            guard case .success(let doc, _) = r else { return keyframeReject(d, r.failure!.code, r.failure!.message) }
            next = doc
        }
        return try keyframeSucceed(d, next, engine)
    }
}
