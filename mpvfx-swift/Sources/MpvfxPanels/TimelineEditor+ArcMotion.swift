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
import MpvfxShared
import MpvfxTimeline

/// A clip's position path as the Arc motion rows show it: keyframe frames, each segment's path (nil: straight) and
/// whether the clip turns along it.
public struct ArcMotionPath: Equatable {
    public var frames: [Double]
    public var segments: [NativeMotionPath?]
    public var autoRotate: Bool
}

// MARK: - Arc motion (NativeArcMotion / ArcPathControls): the position path's curved segments and auto-rotate
public extension TimelineEditor {
    /// The clip's position path when it has a vec2 position track with at least two keyframes (segmentCount >= 1).
    func arcMotionPath(clipId: String) -> ArcMotionPath? {
        guard let c = clip(clipId)?.clip,
              let track = c.parameterTracks.first(where: { $0.parameterId == Self.positionId && $0.valueType == .vec2 }),
              track.keyframes.count >= 2 else { return nil }
        return ArcMotionPath(frames: track.keyframes.map(\.frame), segments: track.keyframes.dropLast().map(\.outgoingPath),
                             autoRotate: track.autoRotate == true)
    }

    /// curvinessOf: a curve segment's curviness, otherwise 1.
    static func arcCurviness(_ path: NativeMotionPath?) -> Double {
        if case .curve(let c)? = path { return c }
        return 1
    }

    /// Arc motion on: every segment becomes a curve (keeping its curviness); off: every segment is straight.
    @discardableResult
    func setArcMotion(clipId: String, _ enabled: Bool) -> Bool {
        guard let path = arcMotionPath(clipId: clipId), let a = parameterAddress(clipId: clipId, Self.positionId) else { return false }
        let cmds: [NativeProjectAtomicPropertyCommand] = path.segments.enumerated().compactMap { i, seg in
            let next: NativeMotionPath? = enabled ? .curve(curviness: Self.arcCurviness(seg)) : nil
            return next == seg ? nil : .keyframe(.setMotionPath(address: a, frame: path.frames[i], path: next))
        }
        guard !cmds.isEmpty else { return false }
        return applyProperty(cmds.count == 1 ? .atomic(cmds[0]) : .batch(cmds))
    }

    /// One segment's curviness (0…3, the slider range).
    @discardableResult
    func setArcCurviness(clipId: String, segment: Int, _ curviness: Double) -> Bool {
        guard let path = arcMotionPath(clipId: clipId), path.segments.indices.contains(segment), curviness.isFinite,
              let a = parameterAddress(clipId: clipId, Self.positionId) else { return false }
        let next = NativeMotionPath.curve(curviness: max(0, min(3, (curviness * 10).rounded() / 10)))
        guard next != path.segments[segment] else { return false }
        return applyProperty(.atomic(.keyframe(.setMotionPath(address: a, frame: path.frames[segment], path: next))))
    }

    /// Auto-rotate: the clip turns to follow the path's tangent (preview and export add the tangent angle).
    @discardableResult
    func setArcAutoRotate(clipId: String, _ on: Bool) -> Bool {
        guard let path = arcMotionPath(clipId: clipId), path.autoRotate != on,
              let a = parameterAddress(clipId: clipId, Self.positionId) else { return false }
        return applyProperty(.atomic(.keyframe(.setAutoRotate(address: a, autoRotate: on))))
    }
}
