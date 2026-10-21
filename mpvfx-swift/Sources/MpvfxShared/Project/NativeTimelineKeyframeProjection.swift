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
// Projects a clip's keyframes onto the timeline (no engine calls).
import Foundation

public enum NativeTimelineProperty: String, CaseIterable, Sendable {
    case x, y, z, rotation, rotationX, rotationY, scale, scaleX, scaleY, scaleZ, transformPerspective, opacity, width, height
}
public enum NativeTimelinePropertyGroupId: String, CaseIterable, Sendable { case position, rotation, scale, opacity, size }

public struct NativeTimelineKeyframeDiamond: Equatable {
    public var id: String, keyframeId: String, animationId: String, parameterId: String
    public var frame: Double, percentage: Double, value: Double
    public var interpolation: NativeInterpolation
}
public struct NativeTimelineKeyframeLane: Equatable {
    public var laneId: String, animationId: String, parameterId: String
    public var property: NativeTimelineProperty
    public var label: String
    public var diamonds: [NativeTimelineKeyframeDiamond]
}
public struct NativeTimelineKeyframeGroup: Equatable {
    public var id: NativeTimelinePropertyGroupId; public var label: String; public var lanes: [NativeTimelineKeyframeLane]
}

public enum NativeTimelineKeyframeProjectionFailure: Equatable, Error {
    case selection(NativePropertyEditPlanFailure)
    case keyframeOutsideClip(message: String, parameterId: String, keyframeId: String)
    public var code: String {
        switch self { case .selection(let f): f.code.rawValue; case .keyframeOutsideClip: "keyframe-outside-clip" }
    }
}

public struct NativeTimelineKeyframeProjection: Equatable {
    public var sequenceId: String, trackId: String, clipId: String
    public var clipStartFrame: Double, clipDurationFrames: Double
    public var groups: [NativeTimelineKeyframeGroup]
}
public typealias NativeTimelineKeyframeProjectionResult = Result<NativeTimelineKeyframeProjection, NativeTimelineKeyframeProjectionFailure>

private let groupDefs: [(NativeTimelinePropertyGroupId, String)] = [(.position, "Position"), (.rotation, "Rotation"), (.scale, "Scale"), (.opacity, "Opacity"), (.size, "Size")]
private struct PropDef: Sendable { let parameterId: String; let property: NativeTimelineProperty; let label: String; let group: NativeTimelinePropertyGroupId; let order: Int }
private let propDefs: [String: PropDef] = {
    let list: [(String, NativeTimelineProperty, String, NativeTimelinePropertyGroupId)] = [
        ("transform.position.x", .x, "X", .position), ("transform.position.y", .y, "Y", .position), ("transform.position.z", .z, "Z", .position),
        ("transform.rotation", .rotation, "Rotation", .rotation), ("transform.rotationX", .rotationX, "Rotate X", .rotation),
        ("transform.rotationY", .rotationY, "Rotate Y", .rotation), ("transform.perspective", .transformPerspective, "Perspective", .rotation),
        ("transform.scale", .scale, "Scale", .scale), ("transform.scaleX", .scaleX, "Scale X", .scale), ("transform.scaleY", .scaleY, "Scale Y", .scale),
        ("transform.scaleZ", .scaleZ, "Scale Z", .scale), ("visual.opacity", .opacity, "Opacity", .opacity),
        ("layout.width", .width, "Width", .size), ("layout.height", .height, "Height", .size)]
    var m: [String: PropDef] = [:]
    for (i, p) in list.enumerated() { m[p.0] = PropDef(parameterId: p.0, property: p.1, label: p.2, group: p.3, order: i) }
    return m
}()

private struct ProjectedKey { let id: String; let frame: Double; let value: Double; let outgoing: NativeInterpolation }
private struct ProjectedLane { let laneId: String; let animationId: String; let parameterId: String; let keyframes: [ProjectedKey] }

/// Stable sort helper (JS Array.prototype.sort is stable).
func jsStableSorted<T>(_ items: [T], by less: (T, T) -> Int) -> [T] {
    items.enumerated().sorted { a, b in let c = less(a.element, b.element); return c != 0 ? c < 0 : a.offset < b.offset }.map(\.element)
}

public func projectNativeTimelineKeyframes(_ document: NativeProjectDocument, _ identity: NativeSelectedElementReference) -> NativeTimelineKeyframeProjectionResult {
    let located: NativeLocatedClip
    switch resolveNativeClipSelection(document, identity) {
    case .failure(let f): return .failure(.selection(f))
    case .success(let l): located = l
    }
    let clip = located.clip
    var projected: [(lane: ProjectedLane, def: PropDef)] = []
    for track in clip.parameterTracks {
        if isVec2PositionTrack(track) {
            for view in positionComponentViews(track, siblings: clip.parameterTracks) {
                guard let def = propDefs[view.parameterId] else { continue }
                projected.append((ProjectedLane(laneId: "\(track.id)|\(view.component.rawValue)", animationId: track.id, parameterId: view.parameterId,
                                                keyframes: view.keyframes.map { .init(id: $0.id, frame: $0.frame, value: $0.value, outgoing: $0.outgoing) }), def))
            }
            continue
        }
        guard let def = propDefs[track.parameterId], track.valueType == .number else { continue }
        projected.append((ProjectedLane(laneId: track.id, animationId: track.id, parameterId: track.parameterId, keyframes: track.keyframes.map {
            var v = Double.nan; if case .number(let n) = $0.value { v = n }
            return .init(id: $0.id, frame: $0.frame, value: v, outgoing: $0.outgoing)
        }), def))
    }
    projected = jsStableSorted(projected) { l, r in
        l.def.order != r.def.order ? (l.def.order < r.def.order ? -1 : 1) : jsLocaleCompare(l.lane.laneId, r.lane.laneId)
    }
    for (lane, _) in projected {
        if let outside = lane.keyframes.first(where: { $0.frame < 0 || $0.frame >= clip.durationFrames }) {
            return .failure(.keyframeOutsideClip(message: "Keyframe \(outside.id) is outside clip-local frame range", parameterId: lane.parameterId, keyframeId: outside.id))
        }
    }
    var lanesByGroup: [NativeTimelinePropertyGroupId: [NativeTimelineKeyframeLane]] = [:]
    for (lane, def) in projected {
        let diamonds = jsStableSorted(lane.keyframes.map { k in
            NativeTimelineKeyframeDiamond(id: k.id, keyframeId: k.id, animationId: lane.animationId, parameterId: lane.parameterId,
                                          frame: k.frame, percentage: k.frame / clip.durationFrames * 100, value: k.value, interpolation: k.outgoing)
        }) { l, r in l.frame != r.frame ? (l.frame < r.frame ? -1 : 1) : jsLocaleCompare(l.keyframeId, r.keyframeId) }
        lanesByGroup[def.group, default: []].append(.init(laneId: lane.laneId, animationId: lane.animationId, parameterId: lane.parameterId,
                                                         property: def.property, label: def.label, diamonds: diamonds))
    }
    let groups = groupDefs.compactMap { id, label -> NativeTimelineKeyframeGroup? in
        guard let lanes = lanesByGroup[id], !lanes.isEmpty else { return nil }
        return .init(id: id, label: label, lanes: lanes)
    }
    return .success(.init(sequenceId: document.sequence.id, trackId: located.trackId, clipId: clip.id,
                          clipStartFrame: clip.startFrame, clipDurationFrames: clip.durationFrames, groups: groups))
}
