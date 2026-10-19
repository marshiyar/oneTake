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
// Property commands: static and animated property edits behind one rollback boundary.
// `throws` only for a re-parse outside a do/catch and engine errors outside a do/catch.
import Foundation

extension NativeProjectPropertyCommandResult {
    public var ok: Bool { if case .success = self { return true }; return false }
    public var document: NativeProjectDocument { switch self { case .success(let d), .failure(let d, _): d } }
    public var failure: NativeProjectKeyframeFailure? { if case .failure(_, let f) = self { return f }; return nil }
}

private func fail(_ d: NativeProjectDocument, _ code: NativeProjectKeyframeFailureCode, _ m: String) -> NativeProjectPropertyCommandResult {
    .failure(document: d, failure: .init(code: code, message: m))
}

private func replaceClip(_ d: NativeProjectDocument, _ loc: LocatedClip, _ clip: NativeProjectClip, _ engine: KeyframeEngine?) throws -> NativeProjectDocument {
    var next = d
    next.sequence.tracks[loc.trackIndex].clips[loc.clipIndex] = clip
    return try parseNativeProjectDocument(next, engine: engine)
}

private func located(_ d: NativeProjectDocument, _ a: NativeProjectParameterAddress) -> Result<LocatedClip, NativeProjectKeyframeFailure> { locateClip(d, a) }

private func applyStatic(_ d: NativeProjectDocument, _ a: NativeProjectParameterAddress, _ value: NativeParameterValue,
                         _ engine: KeyframeEngine?) -> NativeProjectPropertyCommandResult {
    guard case .success(let loc) = located(d, a) else { let f = located(d, a).failureValue!; return fail(d, f.code, f.message) }
    // A static x or y would silently override an animated 2D position.
    if routedPosition(loc.clip, parameterId: a.parameterId) != nil {
        return fail(d, .invalidValue, "Position is animated as a 2D path; edit its keyframes instead")
    }
    var clip = loc.clip
    var statics = clip.staticParameters ?? [:]; statics[a.parameterId] = value; clip.staticParameters = statics
    do { return .success(document: try replaceClip(d, loc, clip, engine)) }
    catch { return fail(d, .invalidValue, errorMessage(error) ?? "Static parameter value is invalid") }
}

private func applyOffset(_ d: NativeProjectDocument, _ a: NativeProjectParameterAddress, _ delta: Double,
                         _ engine: KeyframeEngine?) throws -> NativeProjectPropertyCommandResult {
    if !delta.isFinite { return fail(d, .invalidValue, "Track offset must be finite") }
    guard case .success(let loc) = located(d, a) else { let f = located(d, a).failureValue!; return fail(d, f.code, f.message) }
    if let routed = routedPosition(loc.clip, parameterId: a.parameterId) {
        // Shift one component of the whole 2D path; Bezier handles are absolute, so they move with it.
        func shift(_ p: Vec2Value) -> Vec2Value { var q = p; if routed.component == .x { q.x += delta } else { q.y += delta }; return q }
        var track = routed.track
        track.keyframes = track.keyframes.map { k in
            var n = k
            // `value[component] + delta` goes into the value; a non-vec2 value cannot occur on a vec2 track.
            if case .vec2(let p) = k.value { n.value = .vec2(shift(p)) }
            if case .bezier(let c1, let c2) = k.outgoingPath { n.outgoingPath = .bezier(cp1: shift(c1), cp2: shift(c2)) }
            return n
        }
        var clip = loc.clip
        clip.parameterTracks = clip.parameterTracks.map { $0.id == track.id ? track : $0 }
        return .success(document: try replaceClip(d, loc, clip, engine))   // outside any do/catch: errors propagate
    }
    guard let index = loc.clip.parameterTracks.firstIndex(where: { $0.parameterId == a.parameterId }) else {
        return fail(d, .missingParameter, "Parameter \(a.parameterId) does not exist on clip \(a.clipId)")
    }
    var track = loc.clip.parameterTracks[index]
    if track.valueType != .number { return fail(d, .valueTypeMismatch, "Parameter \(a.parameterId) is not a numeric track") }
    track.keyframes = track.keyframes.map { k in var n = k; if case .number(let v) = k.value { n.value = .number(v + delta) }; return n }
    var clip = loc.clip; clip.parameterTracks[index] = track
    do { return .success(document: try replaceClip(d, loc, clip, engine)) }
    catch { return fail(d, .invalidValue, errorMessage(error) ?? "Offset produced an invalid parameter value") }
}

private func applyCollapse(_ d: NativeProjectDocument, _ a: NativeProjectParameterAddress, _ frame: Double,
                           _ engine: KeyframeEngine?) throws -> NativeProjectPropertyCommandResult {
    guard case .success(let loc) = located(d, a) else { let f = located(d, a).failureValue!; return fail(d, f.code, f.message) }
    if !jsIsInteger(frame) || frame < 0 || frame >= loc.clip.durationFrames {
        return fail(d, .invalidFrame, "Frame must be an integer in clip-local range 0 <= frame < \(jsNumberString(loc.clip.durationFrames))")
    }
    if let routed = routedPosition(loc.clip, parameterId: a.parameterId) {
        // Deleting all position keys keeps the 2D value at the playhead as the static position; stale static x/y would override it.
        let value = try evaluateNativeParameterTrack(routed.track, projectFrame: frame, engine: engine)   // outside any do/catch
        var clip = loc.clip
        var statics = clip.staticParameters ?? [:]
        statics[POSITION_X_PARAMETER_ID] = nil; statics[POSITION_Y_PARAMETER_ID] = nil
        statics[POSITION_PARAMETER_ID] = value
        clip.staticParameters = statics
        clip.parameterTracks = clip.parameterTracks.filter { $0.id != routed.track.id }
        return .success(document: try replaceClip(d, loc, clip, engine))
    }
    guard let index = loc.clip.parameterTracks.firstIndex(where: { $0.parameterId == a.parameterId }) else {
        return fail(d, .missingParameter, "Parameter \(a.parameterId) does not exist on clip \(a.clipId)")
    }
    let track = loc.clip.parameterTracks[index]
    if track.frameRate.numerator != d.frameRate.numerator || track.frameRate.denominator != d.frameRate.denominator {
        return fail(d, .frameRateMismatch, "Parameter frame rate does not match project")
    }
    do {
        let value = try evaluateNativeParameterTrack(track, projectFrame: frame, engine: engine)
        var clip = loc.clip
        var statics = clip.staticParameters ?? [:]; statics[a.parameterId] = value; clip.staticParameters = statics
        clip.parameterTracks.remove(at: index)
        return .success(document: try replaceClip(d, loc, clip, engine))
    } catch { return fail(d, .invalidValue, errorMessage(error) ?? "Could not evaluate parameter track") }
}

private func applyAtomicProperty(_ d: NativeProjectDocument, _ c: NativeProjectAtomicPropertyCommand,
                                 _ engine: KeyframeEngine?) throws -> NativeProjectPropertyCommandResult {
    switch c {
    case let .setStatic(a, v): return applyStatic(d, a, v, engine)
    case let .offsetTrack(a, delta): return try applyOffset(d, a, delta, engine)
    case let .collapseTrack(a, f): return try applyCollapse(d, a, f, engine)
    case .keyframe(let k):
        let r = try applyNativeProjectKeyframeCommand(d, .atomic(k), engine: engine)
        if case .success(let next, _) = r { return .success(document: next) }
        return .failure(document: d, failure: r.failure!)
    }
}

/// Apply static and animated property mutations through one rollback boundary.
public func applyNativeProjectPropertyCommand(_ d: NativeProjectDocument, _ command: NativeProjectPropertyCommand,
                                              engine: KeyframeEngine? = nil) throws -> NativeProjectPropertyCommandResult {
    switch command {
    case .atomic(let c): return try applyAtomicProperty(d, c, engine)
    case .batch(let commands):
        var applied: [NativeProjectAtomicPropertyCommand] = []
        var next = d
        for child in commands {
            // x/y halves of one structural edit on a 2D position apply once.
            if let signature = positionPairSignature(d, child) {
                if applied.contains(signature) { continue }
                applied.append(signature)
            }
            let r = try applyAtomicProperty(next, child, engine)
            guard case .success(let doc) = r else { return .failure(document: d, failure: r.failure!) }
            next = doc
        }
        return .success(document: next)
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f }; return nil }
}
