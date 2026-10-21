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
// Projects native keyframes into the rows the keyframe navigator and inspector show.
import Foundation

public enum NativeKeyframeUiProperty: String, CaseIterable, Sendable {
    case x, y, z, rotation, scale, scaleX, scaleY, scaleZ, rotationX, rotationY, transformPerspective, opacity, width, height
}

public struct NativeKeyframeUiRow: Equatable {
    public var percentage: Double
    public var properties: [NativeKeyframeUiProperty: Double]
    public var animationId: String
    public var parameterId: String
    public var nativeKeyframeId: String
    public var nativeFrame: Double
    public var interpolation: NativeInterpolation
}

public struct NativePositionPathState: Equatable {
    public var frames: [Double]
    /// nil = straight (no path)
    public var segments: [NativeMotionPath?]
    public var autoRotate: Bool
    public var aligned: Bool
}

private func positionPathState(_ tracks: [NativeParameterTrack]) -> NativePositionPathState? {
    if let vec2 = findVec2PositionTrack(tracks), positionComponentViews(vec2, siblings: tracks).count == 2 {
        return .init(frames: vec2.keyframes.map(\.frame), segments: vec2.keyframes.dropLast().map(\.outgoingPath),
                     autoRotate: vec2.autoRotate == true, aligned: true)
    }
    let x = tracks.first { $0.parameterId == POSITION_X_PARAMETER_ID }
    let y = tracks.first { $0.parameterId == POSITION_Y_PARAMETER_ID }
    guard let base = x ?? y else { return nil }
    let frames = base.keyframes.map(\.frame)
    var aligned = false
    if let x, let y, x.keyframes.count == y.keyframes.count {
        // The interpolations are compared as enum values.
        aligned = zip(x.keyframes, y.keyframes).allSatisfy { $0.frame == $1.frame && $0.outgoing == $1.outgoing }
    }
    return .init(frames: frames, segments: frames.dropLast().map { _ in nil }, autoRotate: false, aligned: aligned)
}

public struct NativeKeyframeUiProjectionRequest {
    public var selectedElement: NativeSelectedElementReference
    public var playheadSeconds: Double
    public init(selectedElement: NativeSelectedElementReference, playheadSeconds: Double) { self.selectedElement = selectedElement; self.playheadSeconds = playheadSeconds }
}

public struct NativeKeyframeUiProjection: Equatable {
    public var sequenceId: String, trackId: String, clipId: String
    public var clipStartSeconds: Double, clipDurationSeconds: Double
    public var projectFrame: Double, clipLocalFrame: Double
    public var currentValues: [NativeKeyframeUiProperty: Double]
    public var keyframeRows: [NativeKeyframeUiRow]
    public var positionPath: NativePositionPathState?
}

public typealias NativeKeyframeUiProjectionResult = Result<NativeKeyframeUiProjection, NativePropertyEditPlanFailure>

private let parameterProjections: [(parameterId: String, property: NativeKeyframeUiProperty)] = [
    ("transform.position.x", .x), ("transform.position.y", .y), ("transform.position.z", .z),
    ("transform.rotation", .rotation), ("transform.rotationX", .rotationX), ("transform.rotationY", .rotationY),
    ("transform.scale", .scale), ("transform.scaleX", .scaleX), ("transform.scaleY", .scaleY), ("transform.scaleZ", .scaleZ),
    ("transform.perspective", .transformPerspective), ("visual.opacity", .opacity), ("layout.width", .width), ("layout.height", .height),
]
private let projectionOrder: [String: (property: NativeKeyframeUiProperty, order: Int)] = {
    var m: [String: (NativeKeyframeUiProperty, Int)] = [:]
    for (i, p) in parameterProjections.enumerated() { m[p.parameterId] = (p.property, i) }
    return m
}()

private func supportedTracks(_ tracks: [NativeParameterTrack]) -> [(track: NativeParameterTrack, property: NativeKeyframeUiProperty)] {
    tracks.enumerated().compactMap { i, t -> (Int, NativeParameterTrack, NativeKeyframeUiProperty, Int)? in
        guard let p = projectionOrder[t.parameterId], t.valueType == .number else { return nil }
        return (i, t, p.property, p.order)
    }.sorted { l, r in   // stable: JS Array.prototype.sort is stable
        if l.3 != r.3 { return l.3 < r.3 }
        let c = jsLocaleCompare(l.1.id, r.1.id)
        return c != 0 ? c < 0 : l.0 < r.0
    }.map { ($0.1, $0.2) }
}

/// Project native clip state into legacy-shaped navigation rows. Engine errors propagate.
public func projectNativeKeyframeUi(_ document: NativeProjectDocument, _ request: NativeKeyframeUiProjectionRequest,
                                    engine: KeyframeEngine? = nil) throws -> NativeKeyframeUiProjectionResult {
    let located: NativeLocatedClip
    switch resolveNativeClipSelection(document, request.selectedElement) {
    case .failure(let f): return .failure(f)
    case .success(let l): located = l
    }
    let clip = located.clip
    let projectFrame: Double
    do { projectFrame = try projectFrameFromSeconds(request.playheadSeconds, frameRate: document.frameRate) }
    catch { return .failure(.init(code: .invalidPlayhead, message: "\(error)", property: nil)) }
    let clipLocalFrame = max(0, min(clip.durationFrames - 1, projectFrame - clip.startFrame))

    var currentValues: [NativeKeyframeUiProperty: Double] = [:]
    var rows: [NativeKeyframeUiRow] = []
    if case .vec2(let p)? = clip.staticParameters?["transform.position"] { currentValues[.x] = p.x; currentValues[.y] = p.y }
    if case .vec2(let s)? = clip.staticParameters?["transform.scale"] {
        currentValues[.scaleX] = s.x; currentValues[.scaleY] = s.y
        if s.x == s.y { currentValues[.scale] = s.x }
    }
    for p in parameterProjections { if case .number(let v)? = clip.staticParameters?[p.parameterId] { currentValues[p.property] = v } }

    if let vec2 = findVec2PositionTrack(clip.parameterTracks) {
        let value = try evaluateNativeParameterTrack(vec2, projectFrame: clipLocalFrame, engine: engine)
        let views = positionComponentViews(vec2, siblings: clip.parameterTracks)
        if case .vec2(let v) = value { for view in views { currentValues[view.component == .x ? .x : .y] = view.component == .x ? v.x : v.y } }
        for view in views {
            let prop: NativeKeyframeUiProperty = view.component == .x ? .x : .y
            for k in view.keyframes {
                rows.append(.init(percentage: k.frame / clip.durationFrames * 100, properties: [prop: k.value], animationId: vec2.id,
                                  parameterId: view.parameterId, nativeKeyframeId: k.id, nativeFrame: k.frame, interpolation: k.outgoing))
            }
        }
    }
    for (track, property) in supportedTracks(clip.parameterTracks) {
        if case .number(let v) = try evaluateNativeParameterTrack(track, projectFrame: clipLocalFrame, engine: engine) { currentValues[property] = v }
        for k in track.keyframes {
            guard case .number(let kv) = k.value else { continue }
            rows.append(.init(percentage: k.frame / clip.durationFrames * 100, properties: [property: kv], animationId: track.id,
                              parameterId: track.parameterId, nativeKeyframeId: k.id, nativeFrame: k.frame, interpolation: k.outgoing))
        }
    }
    let spf = document.frameRate.denominator / document.frameRate.numerator
    return .success(.init(sequenceId: document.sequence.id, trackId: located.trackId, clipId: clip.id,
                          clipStartSeconds: clip.startFrame * spf, clipDurationSeconds: clip.durationFrames * spf,
                          projectFrame: projectFrame, clipLocalFrame: clipLocalFrame, currentValues: currentValues,
                          keyframeRows: rows, positionPath: positionPathState(clip.parameterTracks)))
}
