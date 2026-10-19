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
// Keyframe commands on vec2 position tracks: routing x/y edits onto the position track.
import Foundation

private func sameInterpolation(_ l: NativeInterpolation, _ r: NativeInterpolation) -> Bool { l == r }

/// Merge scalar x/y position tracks into one vec2 track. Exact only when both share keyframe frames and easing.
private func vec2PositionFor(_ d: NativeProjectDocument, _ loc: LocatedClip, _ engine: KeyframeEngine?) throws
    -> Result<(tracks: [NativeParameterTrack], track: NativeParameterTrack), NativeProjectKeyframeFailure> {
    let tracks = loc.clip.parameterTracks
    if let existing = findVec2PositionTrack(tracks) { return .success((tracks, existing)) }
    let misaligned = NativeProjectKeyframeFailure(code: .positionComponentsMisaligned,
        message: "Arc motion needs X and Y position keyframes at the same frames with the same easing")
    guard let x = tracks.first(where: { $0.parameterId == POSITION_X_PARAMETER_ID }),
          let y = tracks.first(where: { $0.parameterId == POSITION_Y_PARAMETER_ID }),
          x.keyframes.count == y.keyframes.count else { return .failure(misaligned) }
    let trackId = nativeParameterTrackId(clipId: loc.clip.id, parameterId: POSITION_PARAMETER_ID)
    var keyframes: [NativeKeyframe] = []
    for (xk, yk) in zip(x.keyframes, y.keyframes) {
        guard xk.frame == yk.frame, sameInterpolation(xk.outgoing, yk.outgoing),
              case .number(let xv) = xk.value, case .number(let yv) = yk.value else { return .failure(misaligned) }
        keyframes.append(.init(id: nativeParameterKeyframeId(parameterTrackId: trackId, frame: xk.frame), frame: xk.frame,
                               value: .vec2(.init(x: xv, y: yv)), outgoing: xk.outgoing))
    }
    // Not inside a do/catch, so a validation error here propagates.
    let track = try createNativeParameterTrack(.init(id: trackId, parameterId: POSITION_PARAMETER_ID, valueType: .vec2,
                                                     frameRate: d.frameRate, keyframes: keyframes), engine: engine)
    return .success((tracks.filter { $0.parameterId != POSITION_X_PARAMETER_ID && $0.parameterId != POSITION_Y_PARAMETER_ID } + [track], track))
}

private func withPositionTrack(_ tracks: [NativeParameterTrack], _ track: NativeParameterTrack) -> [NativeParameterTrack] {
    tracks.map { $0.id == track.id ? track : $0 }
}

func applyPositionPathCommand(_ d: NativeProjectDocument, _ loc: LocatedClip, _ command: NativeProjectAtomicKeyframeCommand,
                              _ engine: KeyframeEngine?) throws -> NativeProjectKeyframeCommandResult {
    let resolved: (tracks: [NativeParameterTrack], track: NativeParameterTrack)
    switch try vec2PositionFor(d, loc, engine) { case .failure(let f): return keyframeReject(d, f.code, f.message); case .success(let r): resolved = r }
    let track = resolved.track
    var keyframes = track.keyframes
    var autoRotate = track.autoRotate == true
    switch command {
    case let .setMotionPath(_, frame, path):
        guard let index = keyframes.firstIndex(where: { $0.frame == frame }) else {
            return keyframeReject(d, .missingKeyframe, "Frame \(jsNumberString(frame)) has no position keyframe")
        }
        if index == keyframes.count - 1 && path != nil {
            return keyframeReject(d, .invalidValue, "The last position keyframe has no following segment")
        }
        keyframes[index].outgoingPath = path
    case let .setAutoRotate(_, r): autoRotate = r
    default: preconditionFailure("only path commands are routed here")
    }
    let next: NativeParameterTrack
    do {
        // `autoRotate` is passed as a boolean; createNativeParameterTrack only keeps `true`.
        next = try createNativeParameterTrack(.init(id: track.id, parameterId: track.parameterId, valueType: .vec2,
                                                    frameRate: track.frameRate, keyframes: keyframes, autoRotate: autoRotate), engine: engine)
    } catch { return keyframeReject(d, .invalidValue, errorMessage(error) ?? "Invalid motion path") }
    return try keyframeSucceed(d, try replaceParameterTracks(d, loc, withPositionTrack(resolved.tracks, next), engine), engine)
}

/// x/y edits on a vec2 position: value edits change one component; structural edits apply to the whole key.
func applyToVec2Position(_ d: NativeProjectDocument, _ loc: LocatedClip, _ track: NativeParameterTrack, _ component: PositionComponent,
                         _ command: NativeProjectAtomicKeyframeCommand, _ engine: KeyframeEngine?) throws -> NativeProjectKeyframeCommandResult {
    var address = command.address; address.parameterId = POSITION_PARAMETER_ID
    func keyAt(_ f: Double) -> NativeKeyframe? { track.keyframes.first { $0.frame == f } }
    func compose(_ base: NativeParameterValue, _ v: Double) -> NativeParameterValue {
        // A non-vec2 current value gives NaN for the other component.
        var p: Vec2Value = { if case .vec2(let p) = base { return p }; return .init(x: .nan, y: .nan) }()
        if component == .x { p.x = v } else { p.y = v }
        return .vec2(p)
    }
    switch command {
    case let .upsert(a, _, frame, value, _, outgoing):
        guard case .number(let v) = value else { return keyframeReject(d, .valueTypeMismatch, "\(a.parameterId) takes a number") }
        if let bad = invalidClipFrame(loc.clip, frame) { return keyframeReject(d, bad.code, bad.message) }
        let existing = keyAt(frame)
        let current = try existing?.value ?? (engine ?? keyframeEngine()).evaluate(VkfTrack(track), frame: frame)
        let key = NativeKeyframe(id: existing?.id ?? nativeParameterKeyframeId(parameterTrackId: track.id, frame: frame), frame: frame,
                                 value: compose(current, v), outgoing: outgoing ?? existing?.outgoing ?? .linear, outgoingPath: existing?.outgoingPath)
        let result = try applyNativeKeyframeCommand(track, .upsert(key), engine: engine)
        guard case .success(let next, _) = result else { return mapTrackFailure(d, result.failure!.code.rawValue, result.failure!.message) }
        return try keyframeSucceed(d, try replaceParameterTracks(d, loc, withPositionTrack(loc.clip.parameterTracks, next), engine), engine)
    case let .updateValue(a, frame, value):
        guard let existing = keyAt(frame) else { return keyframeReject(d, .missingKeyframe, "Frame \(jsNumberString(frame)) has no keyframe") }
        guard case .number(let v) = value else { return keyframeReject(d, .valueTypeMismatch, "\(a.parameterId) takes a number") }
        return try applyAtomicKeyframe(d, .updateValue(address: address, frame: frame, value: compose(existing.value, v)), engine)
    default:
        return try applyAtomicKeyframe(d, command.withAddress(address), engine)
    }
}
