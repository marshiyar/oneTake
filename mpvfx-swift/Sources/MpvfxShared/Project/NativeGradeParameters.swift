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

/// The animatable parameters of a clip's grade (issue #179). The grade itself is one `color-grading` effect whose
/// parameters are a JSON object; a value that animates is a parameter track named `grade.<section>.<key>`, so the
/// keyframe engine, the timeline lanes, the easing editor and undo treat it like any other parameter. The effect's
/// JSON keeps the value the parameter returns to when its animation is stopped.
///
/// Sections and keys (the grade contract, `ColorGradeParams` in MpvfxColor; `NativeGradeParameterTests` checks the
/// lists match): `grade.intensity` (Amount, 0…1), `grade.adjust.<key>` (the ten Primary values), `grade.wheels.<wheel>.
/// <hue|amount|level>`, `grade.details.vignette`, `grade.details.grain`, and `grade.effects.<key>` (each stylize
/// effect's master amount).
///
/// Curves and secondaries (issue #228) animate through the same numeric tracks, one per coordinate or setting, because
/// the keyframe engine evaluates numbers only: `grade.curves.<channel>.<point>.<x|y>` (and `grade.hueCurves...`) for each
/// point of a curve, and `grade.secondaries.<n>.<field>` for each setting of a secondary. A track belongs to the point
/// or secondary at that position, so the editor keeps the number of points of an animated curve, and of secondaries,
/// fixed until the animation is stopped (`animatedCurveChannels`, `hasAnimatedSecondaries`); a track whose point or
/// secondary no longer exists is ignored when the grade is read.
public enum NativeGradeParameter {
    public static let prefix = "grade."
    public static let intensityId = "grade.intensity"
    public static let adjustKeys = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "temperature", "tint", "vibrance", "saturation"]
    public static let wheelKeys = ["shadows", "midtones", "highlights"]
    public static let wheelFields = ["hue", "amount", "level"]
    public static let detailKeys = ["vignette", "grain"]
    public static let effectKeys = ["blur", "pixelate", "chromaBleed", "tapeDamage", "filmArtifacts", "halftone", "twoInkPrint", "ascii", "dither",
                                    "bloom", "monoScreen", "scanlines", "chromaticAberration", "crtCurvature", "digitalGlitch", "engraving", "crosshatch", "kuwahara"]

    public static func adjustId(_ key: String) -> String { "grade.adjust.\(key)" }
    public static func wheelId(_ wheel: String, _ field: String) -> String { "grade.wheels.\(wheel).\(field)" }
    public static func detailId(_ key: String) -> String { "grade.details.\(key)" }
    public static func effectId(_ key: String) -> String { "grade.effects.\(key)" }

    /// Curve channels, as the grade's JSON stores them: `curves` holds the RGB and delta curves, `hueCurves` the hue ones.
    public static let curveChannels = ["master", "red", "green", "blue", "lumaVsSaturation", "saturationVsSaturation"]
    public static let hueCurveChannels = ["hueVsHue", "hueVsSaturation", "hueVsLuma"]
    public static let maxCurvePoints = 16, maxSecondaries = 4
    /// A secondary's animatable settings: the track field, then its path inside the secondary's JSON object.
    public static let secondaryFields: [(field: String, path: [String])] = [
        ("hueCenter", ["key", "hue", "center"]), ("hueRange", ["key", "hue", "range"]), ("hueSoftness", ["key", "hue", "softness"]),
        ("satMin", ["key", "saturation", "min"]), ("satMax", ["key", "saturation", "max"]), ("satSoftness", ["key", "saturation", "softness"]),
        ("lumaMin", ["key", "luma", "min"]), ("lumaMax", ["key", "luma", "max"]), ("lumaSoftness", ["key", "luma", "softness"]),
        ("hueShift", ["correction", "hueShift"]), ("saturation", ["correction", "saturation"]), ("luma", ["correction", "luma"]),
        ("temperature", ["correction", "temperature"]), ("tint", ["correction", "tint"]),
    ]
    /// The qualifier (key) fields and the correction fields of a secondary, in row order.
    public static let secondaryKeyFields = secondaryFields.prefix(9).map(\.field)
    public static let secondaryCorrectionFields = secondaryFields.suffix(5).map(\.field)

    public static func curveId(_ channel: String, _ point: Int, _ axis: String) -> String { "grade.curves.\(channel).\(point).\(axis)" }
    public static func hueCurveId(_ channel: String, _ point: Int, _ axis: String) -> String { "grade.hueCurves.\(channel).\(point).\(axis)" }
    public static func secondaryId(_ index: Int, _ field: String) -> String { "grade.secondaries.\(index).\(field)" }
    /// The ids that animate a curve's `count` points: x and y of each. `hue` picks the hue curves.
    public static func curveIds(_ channel: String, count: Int, hue: Bool = false) -> [String] {
        (0..<count).flatMap { i in ["x", "y"].map { hue ? hueCurveId(channel, i, $0) : curveId(channel, i, $0) } }
    }
    /// The ids of the given fields of secondary `index` (all fields when `fields` is nil).
    public static func secondaryIds(_ index: Int, fields: [String]? = nil) -> [String] {
        (fields ?? secondaryFields.map(\.field)).map { secondaryId(index, $0) }
    }

    /// The path of a curve or secondary id inside the grade's JSON; array positions are numbers (`["curves", "master", "0", "1"]`
    /// is the output of the first master point). Nil for an id that is not one of these.
    static func dynamicPath(_ parameterId: String) -> [String]? {
        guard parameterId.hasPrefix(prefix) else { return nil }
        let parts = parameterId.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        switch (parts.first, parts.count) {
        case ("curves", 4), ("hueCurves", 4):
            let channels = parts[0] == "curves" ? curveChannels : hueCurveChannels
            guard channels.contains(parts[1]), let point = position(parts[2], below: maxCurvePoints), ["x", "y"].contains(parts[3]) else { return nil }
            return [parts[0], parts[1], String(point), parts[3] == "x" ? "0" : "1"]
        case ("secondaries", 3):
            guard let index = position(parts[1], below: maxSecondaries), let field = secondaryFields.first(where: { $0.field == parts[2] }) else { return nil }
            return ["secondaries", String(index)] + field.path
        default: return nil
        }
    }
    private static func position(_ text: String, below limit: Int) -> Int? {
        guard let n = Int(text), n >= 0, n < limit, String(n) == text else { return nil }
        return n
    }

    /// Every animatable grade parameter id, in inspector order.
    public static let allIds: [String] = [intensityId] + adjustKeys.map(adjustId)
        + wheelKeys.flatMap { w in wheelFields.map { wheelId(w, $0) } } + detailKeys.map(detailId) + effectKeys.map(effectId)
    static let idSet = Set(allIds)

    public static func isGradeParameter(_ parameterId: String) -> Bool { idSet.contains(parameterId) || dynamicPath(parameterId) != nil }

    /// The JSON path of an id inside the grade's parameters (`["adjust", "exposure"]`), nil for an unknown id.
    public static func path(_ parameterId: String) -> [String]? {
        guard idSet.contains(parameterId) else { return dynamicPath(parameterId) }
        let parts = parameterId.dropFirst(prefix.count).split(separator: ".").map(String.init)
        return parts
    }

    /// The clip's grade effect (the first `color-grading` effect), as the inspector and the renderer find it.
    public static func gradeEffect(_ clip: NativeProjectClip) -> NativeClipEffect? {
        clip.effects.first { $0.effectId == "color-grading" }
    }

    /// The value the grade's JSON holds for an id, nil when it holds none (the contract or preset default applies).
    public static func authoredValue(_ parameterId: String, in clip: NativeProjectClip) -> Double? {
        guard let path = path(parameterId), let params = gradeEffect(clip)?.parameters else { return nil }
        var node: NativeJSONValue = .object(params)
        for key in path {
            switch node {
            case .object(let o): guard let next = o[key] else { return nil }; node = next
            case .array(let a): guard let i = Int(key), a.indices.contains(i) else { return nil }; node = a[i]
            default: return nil
            }
        }
        if case .number(let v) = node { return v }
        return nil
    }

    /// The grade's parameters with `values` (grade parameter id -> value) written at their paths; other ids are
    /// ignored. Missing objects on a path are created, so a clip with no grade effect animates from the defaults.
    public static func writing(_ values: [String: Double], into parameters: NativeJSONObject) -> NativeJSONObject {
        var out = parameters
        for (id, v) in values.sorted(by: { $0.key < $1.key }) {
            guard let path = path(id), v.isFinite else { continue }
            if idSet.contains(id) { out = set(out, path[...], .number(v)); continue }
            // A curve point or secondary that is not in the grade has nothing to animate: nothing is created for it.
            if case .object(let changed)? = replacing(.object(out), path[...], v) { out = changed }
        }
        return out
    }

    static func set(_ o: NativeJSONObject, _ path: ArraySlice<String>, _ v: NativeJSONValue) -> NativeJSONObject {
        guard let key = path.first else { return o }
        var out = o
        if path.count == 1 { out[key] = v; return out }
        var child = NativeJSONObject()
        if case .object(let c)? = o[key] { child = c }
        out[key] = .object(set(child, path.dropFirst(), v))
        return out
    }

    /// `node` with the number at `path` set to `v`, or nil when a step of the path does not exist. Objects take a new last
    /// key; an array position must already be there.
    static func replacing(_ node: NativeJSONValue, _ path: ArraySlice<String>, _ v: Double) -> NativeJSONValue? {
        guard let key = path.first else { return .number(v) }
        switch node {
        case .object(let o):
            var out = o
            if path.count == 1 { out[key] = .number(v); return .object(out) }
            guard let child = o[key], let next = replacing(child, path.dropFirst(), v) else { return nil }
            out[key] = next
            return .object(out)
        case .array(let a):
            guard let i = Int(key), a.indices.contains(i), let next = replacing(a[i], path.dropFirst(), v) else { return nil }
            var out = a
            out[i] = next
            return .array(out)
        default: return nil
        }
    }

    /// The grade parameters animated on a clip (tracks with keys): the fixed ids in `allIds` order, then curve points and
    /// secondary settings in a stable order.
    public static func animatedIds(_ clip: NativeProjectClip) -> [String] {
        let keyed = Set(clip.parameterTracks.filter { !$0.keyframes.isEmpty }.map(\.parameterId))
        let dynamic = keyed.filter { !idSet.contains($0) && dynamicPath($0) != nil }
        return allIds.filter(keyed.contains) + dynamic.sorted { orderKey($0) < orderKey($1) }
    }
    /// Sorts a point or secondary id by its section, name, then position (numerically), then axis or field.
    private static func orderKey(_ id: String) -> String {
        id.dropFirst(prefix.count).split(separator: ".").map { Int($0).map { String(format: "%04d", $0) } ?? String($0) }.joined(separator: ".")
    }

    /// The curve channels that have an animated point, as (hue curves?, channel name), for the editor to hold their point count.
    public static func animatedCurveChannels(_ clip: NativeProjectClip) -> Set<String> {
        Set(animatedIds(clip).compactMap { id in
            let parts = id.dropFirst(prefix.count).split(separator: ".")
            return parts.count == 4 && (parts[0] == "curves" || parts[0] == "hueCurves") ? "\(parts[0]).\(parts[1])" : nil
        })
    }
    /// Whether any secondary setting is animated: the number of secondaries is then fixed.
    public static func hasAnimatedSecondaries(_ clip: NativeProjectClip) -> Bool {
        animatedIds(clip).contains { $0.hasPrefix("grade.secondaries.") }
    }
}
