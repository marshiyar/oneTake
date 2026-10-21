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
/// effect's master amount). Curves and secondaries are not animatable.
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

    /// Every animatable grade parameter id, in inspector order.
    public static let allIds: [String] = [intensityId] + adjustKeys.map(adjustId)
        + wheelKeys.flatMap { w in wheelFields.map { wheelId(w, $0) } } + detailKeys.map(detailId) + effectKeys.map(effectId)
    static let idSet = Set(allIds)

    public static func isGradeParameter(_ parameterId: String) -> Bool { idSet.contains(parameterId) }

    /// The JSON path of an id inside the grade's parameters (`["adjust", "exposure"]`), nil for an unknown id.
    public static func path(_ parameterId: String) -> [String]? {
        guard isGradeParameter(parameterId) else { return nil }
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
            guard case .object(let o) = node, let next = o[key] else { return nil }
            node = next
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
            out = set(out, path[...], .number(v))
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

    /// The grade parameters animated on a clip (tracks with keys), in `allIds` order.
    public static func animatedIds(_ clip: NativeProjectClip) -> [String] {
        let keyed = Set(clip.parameterTracks.filter { !$0.keyframes.isEmpty }.map(\.parameterId))
        return allIds.filter(keyed.contains)
    }
}
