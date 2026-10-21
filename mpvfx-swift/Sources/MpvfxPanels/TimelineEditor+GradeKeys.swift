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

/// The grade's animatable values by parameter id (issue #179, `NativeGradeParameter`).
extension ColorGrading {
    public func value(_ parameterId: String) -> Double? {
        guard let path = NativeGradeParameter.path(parameterId) else { return nil }
        switch (path.first, path.count) {
        case ("intensity", 1): return intensity
        case ("adjust", 2): return adjustValue(path[1])
        case ("details", 2): return detail(path[1])
        case ("effects", 2): return effects[path[1]] ?? 0
        case ("wheels", 3): return Self.wheelField(wheel(path[1]), path[2])
        default: return nil
        }
    }

    public mutating func set(_ parameterId: String, _ v: Double) {
        guard let path = NativeGradeParameter.path(parameterId) else { return }
        switch (path.first, path.count) {
        case ("intensity", 1): intensity = v
        case ("adjust", 2): adjust[path[1]] = v
        case ("details", 2): details[path[1]] = v
        case ("effects", 2): effects[path[1]] = v
        case ("wheels", 3):
            var w = wheel(path[1])
            switch path[2] { case "hue": w.hue = v; case "amount": w.amount = v; default: w.level = v }
            wheels[path[1]] = w
        default: break
        }
    }

    static func wheelField(_ w: Wheel, _ field: String) -> Double {
        switch field { case "hue": w.hue; case "amount": w.amount; default: w.level }
    }
}

/// Grade edits with keyframes (issue #179). The effect's JSON holds each value while it is not animated; an animated
/// value lives in its `grade.*` parameter track, and the JSON keeps the value it returns to when animation stops.
public extension TimelineEditor {
    /// The clip's grade as it shows at `time`: the stored grade with every animated value at that frame written in.
    func gradeShown(clipId: String, time: Double) -> ColorGrading {
        var g = colorGrading(clipId: clipId) ?? ColorGrading()
        guard let c = clip(clipId)?.clip else { return g }
        for id in NativeGradeParameter.animatedIds(c) {
            if let v = numberValue(clipId: clipId, id, time: time) { g.set(id, v) }
        }
        return g
    }

    /// Commits an inspector edit of the shown grade: a changed animated value is keyed at the playhead, everything
    /// else is written to the stored grade as before. One undo step; false when nothing changed.
    @discardableResult
    func commitGrade(clipId: String, time: Double, shown: ColorGrading, next: ColorGrading) -> Bool {
        guard let c = clip(clipId)?.clip else { return false }
        let animated = NativeGradeParameter.animatedIds(c)
        guard !animated.isEmpty else { return setColorGrading(clipId: clipId, next) }
        let stored = colorGrading(clipId: clipId) ?? ColorGrading()
        var json = next
        for id in animated { if let v = stored.value(id) { json.set(id, v) } }
        let keyed = animated.filter { next.value($0) != shown.value($0) }
        return withHistory("Edit color grade", coalesceKey: "grade-\(UUID().uuidString)") {
            var ok = false
            for id in keyed { if let v = next.value(id) { ok = setParameter(clipId: clipId, id, .number(v), time: time) || ok } }
            if json != stored { ok = setColorGrading(clipId: clipId, json) || ok }
            return ok
        }
    }

    /// The grade rows' stopwatch off: drops the keys of `parameterIds` and writes the value each shows at `time`
    /// into the stored grade, so the picture at the playhead does not change. One undo step.
    @discardableResult
    func stopGradeAnimation(clipId: String, _ parameterIds: [String], time: Double) -> Bool {
        guard !isClipLocked(clipId) else { return false }
        let shown = gradeShown(clipId: clipId, time: time)
        let ids = parameterIds.filter { isAnimated(clipId: clipId, $0) }
        guard !ids.isEmpty else { return false }
        var g = colorGrading(clipId: clipId) ?? ColorGrading()
        for id in ids { if let v = shown.value(id) { g.set(id, v) } }
        return withHistory("Stop animating property", coalesceKey: "grade-stop-\(UUID().uuidString)") {
            let dropped = editClip(clipId) { c in
                c.parameterTracks.removeAll { ids.contains($0.parameterId) }
                return true
            }
            return setColorGrading(clipId: clipId, g) || dropped
        }
    }
}
