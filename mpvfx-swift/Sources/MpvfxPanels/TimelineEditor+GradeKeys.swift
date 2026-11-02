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
    /// The value the grade renders for an id: its own value, else its preset's (a compact grade such as
    /// `{"preset":"warm-daylight"}` stores only the preset name), else the contract default.
    public func value(_ parameterId: String) -> Double? {
        guard let path = NativeGradeParameter.path(parameterId) else { return nil }
        let p = preset.flatMap(Self.preset)
        switch (path.first, path.count) {
        case ("intensity", 1): return intensity
        case ("adjust", 2): return adjust[path[1]] ?? p?.adjust[path[1]] ?? 0
        case ("details", 2): return details[path[1]] ?? p?.details[path[1]] ?? detail(path[1])
        case ("effects", 2): return effects[path[1]] ?? p?.effects[path[1]] ?? 0
        case ("wheels", 3): return Self.wheelField(wheel(path[1]), path[2])
        default: return pointOrSecondaryValue(parameterId)
        }
    }

    /// A curve point's coordinate or a secondary's setting (issue #228, `grade.curves.<channel>.<point>.<x|y>`,
    /// `grade.secondaries.<n>.<field>`), nil when that point or secondary is not in the grade.
    func pointOrSecondaryValue(_ parameterId: String) -> Double? {
        guard let t = Self.pointTarget(parameterId) else { return nil }
        switch t {
        case .point(let hue, let channel, let i, let axis):
            guard let pts = (hue ? hueCurves : curves)[channel], pts.indices.contains(i), pts[i].indices.contains(axis) else { return nil }
            return pts[i][axis]
        case .secondary(let i, let field):
            guard secondaries.indices.contains(i) else { return nil }
            return Self.secondaryField(secondaries[i], field)
        }
    }

    /// What a curve or secondary id addresses.
    enum PointTarget { case point(hue: Bool, channel: String, index: Int, axis: Int), secondary(index: Int, field: String) }

    static func pointTarget(_ parameterId: String) -> PointTarget? {
        guard NativeGradeParameter.isGradeParameter(parameterId) else { return nil }
        let parts = parameterId.dropFirst(NativeGradeParameter.prefix.count).split(separator: ".").map(String.init)
        switch (parts.first, parts.count) {
        case ("curves", 4), ("hueCurves", 4):
            guard let i = Int(parts[2]) else { return nil }
            return .point(hue: parts[0] == "hueCurves", channel: parts[1], index: i, axis: parts[3] == "x" ? 0 : 1)
        case ("secondaries", 3):
            guard let i = Int(parts[1]) else { return nil }
            return .secondary(index: i, field: parts[2])
        default: return nil
        }
    }

    static func secondaryField(_ s: Secondary, _ field: String) -> Double? {
        switch field {
        case "hueCenter": s.hueCenter
        case "hueRange": s.hueRange
        case "hueSoftness": s.hueSoftness
        case "satMin": s.satMin
        case "satMax": s.satMax
        case "satSoftness": s.satSoftness
        case "lumaMin": s.lumaMin
        case "lumaMax": s.lumaMax
        case "lumaSoftness": s.lumaSoftness
        case "hueShift": s.hueShift
        case "saturation": s.saturation
        case "luma": s.luma
        case "temperature": s.temperature
        case "tint": s.tint
        default: nil
        }
    }

    static func setSecondaryField(_ s: inout Secondary, _ field: String, _ v: Double) {
        switch field {
        case "hueCenter": s.hueCenter = v
        case "hueRange": s.hueRange = v
        case "hueSoftness": s.hueSoftness = v
        case "satMin": s.satMin = v
        case "satMax": s.satMax = v
        case "satSoftness": s.satSoftness = v
        case "lumaMin": s.lumaMin = v
        case "lumaMax": s.lumaMax = v
        case "lumaSoftness": s.lumaSoftness = v
        case "hueShift": s.hueShift = v
        case "saturation": s.saturation = v
        case "luma": s.luma = v
        case "temperature": s.temperature = v
        case "tint": s.tint = v
        default: break
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
        default:
            switch Self.pointTarget(parameterId) {
            case .point(let hue, let channel, let i, let axis)?:
                var all = hue ? hueCurves : curves
                guard var pts = all[channel], pts.indices.contains(i), pts[i].indices.contains(axis) else { return }
                pts[i][axis] = v
                all[channel] = pts
                if hue { hueCurves = all } else { curves = all }
            case .secondary(let i, let field)?:
                guard secondaries.indices.contains(i) else { return }
                Self.setSecondaryField(&secondaries[i], field, v)
            case nil: break
            }
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
            // Wheel hues are keyed unwrapped (see `gradeKeyValue`); the rows show them in 0…360.
            if let v = numberValue(clipId: clipId, id, time: time) { g.set(id, Self.isWheelHue(id) ? Self.wrap360(v) : v) }
        }
        return g
    }

    static func isWheelHue(_ id: String) -> Bool { id.hasPrefix("grade.wheels.") && id.hasSuffix(".hue") }
    static func wrap360(_ v: Double) -> Double { let r = v.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }

    /// The value to key for `id` at `time`: a wheel hue is moved by whole turns to the turn nearest the previous key
    /// (else the next), so 350° to 10° interpolates the short way across 0° through the numeric keyframe engine.
    /// The grade wraps hue back into 0…360 when it renders.
    func gradeKeyValue(clipId: String, _ id: String, _ v: Double, time: Double) -> Double {
        guard Self.isWheelHue(id), let (_, c) = clip(clipId), let f = localFrame(clipId: clipId, time: time) else { return v }
        let keys = c.parameterTracks.first { $0.parameterId == id }?.keyframes ?? []
        let near = keys.last { $0.frame < f } ?? keys.first { $0.frame > f }
        guard let near, case .number(let ref) = near.value else { return v }
        return v + 360 * ((ref - v) / 360).rounded()
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
            for id in keyed {
                guard let v = next.value(id) else { continue }
                ok = setParameter(clipId: clipId, id, .number(gradeKeyValue(clipId: clipId, id, v, time: time)), time: time) || ok
            }
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
