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

/// A keyframeable parameter of a clip and the value it holds when it has neither keys nor a static value
/// (the inspector row's default).
public struct TimelineKeyableParameter: Equatable, Sendable {
    public var parameterId: String, fallback: NativeParameterValue
    public init(_ parameterId: String, _ fallback: NativeParameterValue) { self.parameterId = parameterId; self.fallback = fallback }
}

/// ⌘K / ⇧⌘K: key the properties of the selected clips at the playhead (one undo step for all of them).
public extension TimelineEditor {
    /// Every keyframeable property the inspector shows for the clip, as the parameters it keys: visual clips (video,
    /// image, element) Position, Size, Rotation, Scale, Opacity, Depth, Tilt X, Tilt Y and Perspective (Roll is
    /// Rotation); clips with sound (audio, video) Volume. Position keys the scalar x / y tracks when those carry
    /// the animation (recorded and older projects), else the vec2 track. Video and image clips add the grade values
    /// their grade sets or animates (`gradeKeyableParameters`, issue #179).
    func keyableParameters(clipId: String, time: Double) -> [TimelineKeyableParameter] {
        guard let (_, c) = clip(clipId) else { return [] }
        let kind = document.assets.first { $0.id == c.assetId }?.kind ?? .element
        var out: [TimelineKeyableParameter] = []
        if kind == .video || kind == .image || kind == .element { out += visualKeyableParameters(clipId: clipId, time: time) }
        if kind == .audio || kind == .video { out.append(.init(Self.volumeId, .number(clipVolume(clipId: clipId)))) }
        return out
    }

    internal func visualKeyableParameters(clipId: String, time: Double) -> [TimelineKeyableParameter] {
        let tr = transform(clipId: clipId, time: time), box = defaultLayout(clipId: clipId)
        var out = positionKeyableParameters(clipId: clipId, x: tr.x ?? 0, y: tr.y ?? 0)
        out.append(.init(Self.widthId, .number(tr.width ?? box.width)))
        out.append(.init(Self.heightId, .number(tr.height ?? box.height)))
        out.append(.init(Self.rotationId, .number(0)))
        out.append(.init(Self.scaleId, .vec2(Vec2Value(x: 1, y: 1))))
        out.append(.init(Self.opacityId, .number(1)))
        out += NativeTransform3D.parameterIds.map { .init($0, .number(0)) }
        if kind(ofClip: clipId) != .element { out += gradeKeyableParameters(clipId: clipId) }
        return out
    }

    /// Grade parameters (issue #179) the clip's grade sets away from neutral, or that already animate. Keying all
    /// forty of an untouched grade would only bury the lanes in flat keys.
    internal func gradeKeyableParameters(clipId: String) -> [TimelineKeyableParameter] {
        guard let (_, c) = clip(clipId) else { return [] }
        let animated = Set(NativeGradeParameter.animatedIds(c))
        return NativeGradeParameter.allIds.compactMap { id in
            let authored = NativeGradeParameter.authoredValue(id, in: c)
            let neutral = id == NativeGradeParameter.intensityId ? 1.0 : 0.0
            guard animated.contains(id) || (authored.map { abs($0 - neutral) > 1e-9 } ?? false) else { return nil }
            return .init(id, .number(authored ?? neutral))
        }
    }

    internal func kind(ofClip clipId: String) -> NativeProjectAssetKind {
        guard let (_, c) = clip(clipId) else { return .element }
        return document.assets.first { $0.id == c.assetId }?.kind ?? .element
    }

    internal func positionKeyableParameters(clipId: String, x: Double, y: Double) -> [TimelineKeyableParameter] {
        let scalar = [TimelineKeyableParameter(POSITION_X_PARAMETER_ID, .number(x)), .init(POSITION_Y_PARAMETER_ID, .number(y))]
            .filter { isParameterAnimated(clipId: clipId, $0.parameterId) }
        let vec = TimelineKeyableParameter(Self.positionId, .vec2(Vec2Value(x: x, y: y)))
        if scalar.isEmpty || isParameterAnimated(clipId: clipId, Self.positionId) { return [vec] + scalar }
        return scalar
    }

    func isParameterAnimated(clipId: String, _ parameterId: String) -> Bool {
        clip(clipId)?.clip.parameterTracks.contains { $0.parameterId == parameterId && !$0.keyframes.isEmpty } ?? false
    }

    /// ⌘K (`animatedOnly` false): a key at the playhead on every keyframeable property of each clip, holding the
    /// value shown there. ⇧⌘K (`animatedOnly` true): only on the properties that already have keys. A property
    /// already keyed at that frame is left as it is; locked clips are skipped. One undo step ("Add keyframes");
    /// false when nothing was written.
    @discardableResult
    func keyProperties(clipIds: [String], time: Double, animatedOnly: Bool) -> Bool {
        let cmds = clipIds.filter { !isClipLocked($0) }.flatMap { keyCommands(clipId: $0, time: time, animatedOnly: animatedOnly) }
        guard !cmds.isEmpty else { return false }
        return withHistory(animatedOnly ? "Key animated properties" : "Add keyframes") {
            applyProperty(cmds.count == 1 ? .atomic(cmds[0]) : .batch(cmds))
        }
    }

    internal func keyCommands(clipId: String, time: Double, animatedOnly: Bool) -> [NativeProjectAtomicPropertyCommand] {
        guard let (track, c) = clip(clipId), let frame = localFrame(clipId: clipId, time: time) else { return [] }
        return keyableParameters(clipId: clipId, time: time).compactMap { p in
            let keys = c.parameterTracks.first { $0.parameterId == p.parameterId }?.keyframes ?? []
            guard !keys.contains(where: { $0.frame == frame }), !animatedOnly || !keys.isEmpty else { return nil }
            let v = parameterValue(clipId: clipId, parameterId: p.parameterId, time: time) ?? p.fallback
            let a = NativeProjectParameterAddress(sequenceId: sequenceId, trackId: track.id, clipId: clipId, parameterId: p.parameterId)
            return .keyframe(.upsert(address: a, valueType: Self.valueType(v), frame: frame, value: v,
                                     baselineValue: c.staticParameters?[p.parameterId] ?? v))
        }
    }

    static func valueType(_ v: NativeParameterValue) -> NativeValueType {
        switch v { case .number: .number; case .vec2: .vec2; case .rgba: .rgba }
    }
}
