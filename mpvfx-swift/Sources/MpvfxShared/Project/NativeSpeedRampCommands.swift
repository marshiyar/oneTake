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

public enum NativeSpeedRampCommand: Equatable {
    case setShape(NativeSpeedRampShape)
    case addPoint(t: Double, speed: Double)
    case movePoint(index: Int, t: Double, speed: Double)
    case removePoint(index: Int)
    case setEase(index: Int, ease: NativeInterpolation)
    case clear
}

/// Edits a speed curve and optionally ripples its track to keep the source span.
public func applyNativeSpeedRampCommand(_ d: NativeProjectDocument, clipId: String, _ command: NativeSpeedRampCommand,
                                        keepLength: Bool, engine: KeyframeEngine? = nil) throws -> NativeProjectClipCommandResult {
    func refuse(_ message: String, code: NativeProjectClipFailureCode = .invalidTrim) -> NativeProjectClipCommandResult {
        .failure(document: d, failure: .init(code: code, message: message))
    }
    guard let track = d.sequence.tracks.first(where: { $0.clips.contains { $0.id == clipId } }) else {
        return refuse("Clip \(clipId) does not exist", code: .missingClip)
    }
    let loc: ClipLocation
    switch locate(d, .init(sequenceId: d.sequence.id, trackId: track.id, clipId: clipId)) {
    case .failure(let failure): return .failure(document: d, failure: failure)
    case .success(let found): loc = found
    }
    let clip = loc.clip
    if let ramp = clip.speedRamp, !ramp.isSupported { return refuse("This speed ramp version or kind is not supported") }
    var ramp = clip.speedRamp
    switch command {
    case .setShape(let shape): ramp = NativeSpeedRamp(points: shape.points(durationFrames: clip.durationFrames))
    case .clear: ramp = nil
    case .addPoint(let t, let speed):
        if ramp == nil { ramp = NativeSpeedRamp(points: []) }
        guard !ramp!.points.contains(where: { $0.t == t }) else { return refuse("A speed point already exists at this frame") }
        ramp!.points.append(.init(t: t, speed: speed))
        ramp!.points.sort { $0.t < $1.t }
    case .movePoint(let index, let t, let speed):
        guard let points = ramp?.points, points.indices.contains(index) else { return refuse("Speed point index does not exist") }
        guard (index == 0 || t > points[index - 1].t), (index == points.count - 1 || t < points[index + 1].t) else {
            return refuse("Speed points must stay in strictly increasing order")
        }
        ramp!.points[index].t = t; ramp!.points[index].speed = speed
    case .removePoint(let index):
        guard let points = ramp?.points, points.indices.contains(index) else { return refuse("Speed point index does not exist") }
        guard points.count > 1 else { return refuse("Use clear to remove the last speed point") }
        ramp!.points.remove(at: index)
    case .setEase(let index, let ease):
        guard let points = ramp?.points, points.indices.contains(index) else { return refuse("Speed point index does not exist") }
        ramp!.points[index].ease = ease
    }
    // Validate point values before evaluating the map or shortening its range.
    if let ramp {
        guard !ramp.points.isEmpty, ramp.points.count <= 64 else { return refuse("Speed ramp needs between 1 and 64 points") }
        var previous = -Double.infinity
        for point in ramp.points {
            guard point.t.isFinite, point.t >= 0, point.t <= clip.durationFrames, point.t > previous,
                  point.speed.isFinite, (0.1...10).contains(point.speed) else {
                return refuse("Speed points need increasing times within the clip and speeds between 0.1 and 10")
            }
            previous = point.t
        }
    }
    let rate = clip.playbackRate.map { $0.numerator / $0.denominator } ?? 1
    var duration = clip.durationFrames
    if !keepLength {
        let span = clip.speedRamp?.sourcePosition(atClipFrame: duration) ?? duration * rate
        if let curve = ramp {
            // The map continues at the last speed beyond its last authored point.
            let upper = max(duration, span / 0.1)
            duration = curve.clipFrame(atSourcePosition: span, durationFrames: upper)
        } else { duration = span / rate }
        let whole = duration.rounded()
        let consumed = ramp?.sourcePosition(atClipFrame: whole) ?? whole * rate
        guard isSafeInteger(whole), whole > 0, abs(consumed - span) <= 1e-6 else {
            return refuse("Keeping this source span requires a fractional timeline frame", code: .nonIntegralSourceBoundary)
        }
        duration = whole
        if duration < clip.durationFrames { ramp = ramp?.sliced(from: 0, until: duration) }
    }
    guard let asset = d.assets.first(where: { $0.id == clip.assetId }) else { return refuse("Clip source asset does not exist") }
    if nativeClipConsumesSourceFrames(clip, asset.kind) {
        let fits: Bool
        do {
            let source = NativeSourcePosition(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction)
            if let ramp { fits = sourceFrameValue(source) + ramp.sourcePosition(atClipFrame: duration) <= asset.durationFrames }
            else { fits = try sourceRangeFits(source, playbackRate: clip.playbackRate, durationFrames: duration, sourceDurationFrames: asset.durationFrames) }
        } catch { return refuse(errorMessage(error) ?? "Invalid source boundary") }
        guard fits else { return refuse("The ramped source cannot cover this clip length within the source media") }
    }
    var next = d
    var edited = clip
    edited.speedRamp = ramp; edited.durationFrames = duration
    if duration != clip.durationFrames {
        edited.moves = clip.movesFitted(toDuration: duration)
        edited.clampFades(movedEdge: .end)
        if duration < clip.durationFrames {
            edited.parameterTracks = try clip.parameterTracks.map { track in
                let keys = try (engine ?? keyframeEngine()).slice(KeyframeTrack(track), fromFrame: 0, untilFrameExclusive: duration).map { key in
                    NativeKeyframe(id: (!key.generated ? track.keyframes.first { $0.frame == key.sourceFrame }?.id : nil)
                                       ?? "native-split-baseline:\(track.id)|frame:\(jsNumberString(key.sourceFrame))",
                                   frame: key.frame, value: key.value, outgoing: key.outgoing, outgoingPath: key.outgoingPath)
                }
                return try createNativeParameterTrack(.init(id: track.id, parameterId: track.parameterId, valueType: track.valueType,
                                                             frameRate: track.frameRate, keyframes: keys, autoRotate: track.autoRotate), engine: engine)
            }
            edited.cropPivotSegments = rebaseNativeCropPivotSegments(clip, rebasedTracks: edited.parameterTracks,
                                                                    fromFrame: 0, untilFrameExclusive: duration)
        }
        let end = clip.startFrame + clip.durationFrames, delta = duration - clip.durationFrames
        for i in next.sequence.tracks[loc.trackIndex].clips.indices {
            let follower = next.sequence.tracks[loc.trackIndex].clips[i]
            if follower.id != clipId && follower.startFrame >= end { next.sequence.tracks[loc.trackIndex].clips[i].startFrame += delta }
        }
    }
    next.sequence.tracks[loc.trackIndex].clips[loc.clipIndex] = edited
    do {
        let parsed = try parseNativeProjectDocument(reconcileNativeCutTransitions(next), engine: engine)
        return .success(document: parsed, inverse: .restoreDocument(try cloneNativeDocument(d, engine)))
    } catch let error as NativeProjectDocumentValidationError { return refuse(error.message) }
}
