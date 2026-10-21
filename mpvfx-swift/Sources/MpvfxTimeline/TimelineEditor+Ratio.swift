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

public extension TimelineEditor {
    func scaleRatioLocked(clipId: String) -> Bool { clip(clipId)?.clip.scaleRatioLocked == true }

    /// The same per-clip lock is shown beside Size and Scale; unlocking removes the optional field.
    @discardableResult
    func setScaleRatioLocked(clipId: String, _ on: Bool) -> Bool {
        guard !isClipLocked(clipId), scaleRatioLocked(clipId: clipId) != on else { return false }
        var d = document
        for t in d.sequence.tracks.indices {
            guard let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            d.sequence.tracks[t].clips[i].scaleRatioLocked = on ? true : nil
            return commit(d, on ? "Lock size ratio" : "Unlock size ratio")
        }
        return false
    }

    /// A Size field edits its own axis, or both axes by the same factor when locked. The normal transform
    /// command batches the two writes into one undo step and keys animated properties at the playhead.
    @discardableResult
    func setInspectorSize(clipId: String, time: Double, width: Bool, value: Double) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        var next = ClipTransform(width: width ? value : nil, height: width ? nil : value)
        if scaleRatioLocked(clipId: clipId) {
            let current = transform(clipId: clipId, time: time)
            let w = current.width ?? document.canvas.width, h = current.height ?? document.canvas.height
            guard w > 0, h > 0 else { return false }
            if width { next.height = h * (value / w) } else { next.width = w * (value / h) }
            guard next.width?.isFinite == true, next.height?.isFinite == true else { return false }
        }
        return applyTransform(clipId: clipId, time: time, next)
    }

    func inspectorScale(clipId: String, time: Double) -> Vec2Value {
        switch parameterValue(clipId: clipId, parameterId: Self.scaleId, time: time) {
        case .vec2(let v)?: return v
        case .number(let v)?: return Vec2Value(x: v, y: v)
        default: return Vec2Value(x: 1, y: 1)
        }
    }

    /// Scale X/Y retain a non-uniform ratio while locked; unlocked edits leave the other axis alone.
    @discardableResult
    func setInspectorScale(clipId: String, time: Double, x: Bool, value: Double) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        var next = inspectorScale(clipId: clipId, time: time)
        if scaleRatioLocked(clipId: clipId) {
            let old = x ? next.x : next.y
            guard old != 0 else { return false }
            let factor = value / old
            next = Vec2Value(x: next.x * factor, y: next.y * factor)
        } else if x { next.x = value } else { next.y = value }
        guard next.x.isFinite, next.y.isFinite else { return false }
        guard let (_, c) = clip(clipId), let address = parameterAddress(clipId: clipId, Self.scaleId),
              let frame = localFrame(clipId: clipId, time: time) else { return false }
        let value = NativeParameterValue.vec2(next)
        if c.parameterTracks.contains(where: { $0.parameterId == Self.scaleId && !$0.keyframes.isEmpty }) {
            return applyProperty(.atomic(.keyframe(.upsert(address: address, valueType: .vec2, frame: frame, value: value,
                                                           baselineValue: c.staticParameters?[Self.scaleId] ?? value))))
        }
        guard c.staticParameters?[Self.scaleId] != value else { return false }
        return applyProperty(.atomic(.setStatic(address: address, value: value)))
    }
}
