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

/// The kinds of keyframeable property. Each kind has its own mark shape and colour in the timeline lanes and the
/// inspector (TimelineKeyframeGlyph), so a key never reads as another property's. Cases are in lane order.
public enum TimelineKeyframeKind: String, CaseIterable, Sendable, Comparable {
    /// Position, size, rotation and scale.
    case transform
    /// Depth, tilt X / Y and perspective (roll is `transform.rotation`, a transform key).
    case threeD = "3d"
    case opacity
    /// Colour, grade and style parameters.
    case color
    /// Effect parameters, and any parameter no other kind claims.
    case effect
    case audio

    public var label: String {
        switch self {
        case .transform: "Transform"
        case .threeD: "3D"
        case .opacity: "Opacity"
        case .color: "Color"
        case .effect: "Effect"
        case .audio: "Audio"
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
}

/// Where a parameter track shows in the timeline: its property group (one lane per group), the lane label and
/// the kind that picks the lane's mark.
public struct TimelineKeyframeProperty: Equatable, Sendable {
    public var group: String, label: String, kind: TimelineKeyframeKind
    public init(group: String, label: String, kind: TimelineKeyframeKind) { self.group = group; self.label = label; self.kind = kind }
}

/// Parameter id -> timeline property. The inspector's keyframeable rows map one to one onto these groups:
/// Position (the vec2 track and the scalar x / y tracks), Size (layout.*), Rotation (also the 3D Roll row),
/// Scale, Opacity, Depth, Tilt X, Tilt Y, Perspective and Volume.
public enum TimelineKeyframeCatalog {
    static let exact: [String: TimelineKeyframeProperty] = [
        TimelineEditor.positionId: .init(group: "position", label: "Position", kind: .transform),
        POSITION_X_PARAMETER_ID: .init(group: "position", label: "Position", kind: .transform),
        POSITION_Y_PARAMETER_ID: .init(group: "position", label: "Position", kind: .transform),
        NativeTransform3D.zId: .init(group: "depth", label: "Depth", kind: .threeD),
        NativeTransform3D.rotationXId: .init(group: "tiltX", label: "Tilt X", kind: .threeD),
        NativeTransform3D.rotationYId: .init(group: "tiltY", label: "Tilt Y", kind: .threeD),
        NativeTransform3D.perspectiveId: .init(group: "perspective", label: "Perspective", kind: .threeD),
        TimelineEditor.volumeId: .init(group: "audio", label: "Volume", kind: .audio),
    ]

    /// Prefix rules, first match wins; checked after `exact`.
    static let prefixes: [(prefix: String, property: TimelineKeyframeProperty)] = [
        ("transform.scale", .init(group: "scale", label: "Scale", kind: .transform)),
        ("transform.rotation", .init(group: "rotation", label: "Rotation", kind: .transform)),
        ("layout.", .init(group: "size", label: "Size", kind: .transform)),
    ]

    /// Kinds of parameters grouped one lane per parameter, by id prefix.
    static let kindPrefixes: [(prefix: String, kind: TimelineKeyframeKind)] = [
        ("grade.effects.", .effect), ("grade.", .color), ("color.", .color), ("style.", .color),
        ("effect.", .effect), ("effects.", .effect), ("fx.", .effect),
        ("audio.", .audio),
    ]

    public static func property(_ parameterId: String) -> TimelineKeyframeProperty {
        if let p = exact[parameterId] { return p }
        if let p = prefixes.first(where: { parameterId.hasPrefix($0.prefix) }) { return p.property }
        if parameterId.contains("opacity") || parameterId == "visual.autoAlpha" { return .init(group: "opacity", label: "Opacity", kind: .opacity) }
        let kind = kindPrefixes.first { parameterId.hasPrefix($0.prefix) }?.kind ?? .effect
        return .init(group: parameterId, label: label(parameterId), kind: kind)
    }

    /// Grade parameters (`grade.<section>.<key>`, issue #179) are named by what follows their section, so the three
    /// wheels' hues read "Shadows Hue", "Midtones Hue"…; other parameters by their last component.
    static func label(_ parameterId: String) -> String {
        if parameterId == "grade.intensity" { return "Grade Amount" }
        var parts = parameterId.split(separator: ".").map(String.init)
        if parts.first == "grade" {
            parts.removeFirst()
            if ["adjust", "wheels", "details", "effects"].contains(parts.first ?? ""), parts.count > 1 { parts.removeFirst() }
        } else {
            parts = [parts.last ?? parameterId]
        }
        return parts.map { TimelineEditor.titleCase(splitCamel($0)) }.joined(separator: " ")
    }

    /// "chromaticAberration" -> "chromatic Aberration" (titleCase then capitalises the first word).
    static func splitCamel(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// Lane order inside a kind: the inspector's row order, then any other group (by label, at the caller).
    static let groupOrder = ["position", "size", "rotation", "scale", "opacity", "depth", "tiltX", "tiltY", "perspective", "audio"]
        + NativeGradeParameter.allIds
    public static func order(ofGroup group: String) -> Int { groupOrder.firstIndex(of: group) ?? groupOrder.count }

    /// The kind of a lane's property group (the group ids `property(_:)` returns).
    public static func kind(ofGroup group: String) -> TimelineKeyframeKind {
        let named = Array(exact.values) + prefixes.map(\.property)
        return named.first { $0.group == group }?.kind ?? property(group).kind
    }
}
