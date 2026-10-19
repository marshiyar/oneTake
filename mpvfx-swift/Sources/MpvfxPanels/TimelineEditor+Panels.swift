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

/// Document edits behind the inspector and the media bin. Each is one undo step on the shared TimelineEditor
/// history (the same history the timeline, canvas and Cmd+Z use); none keeps state of its own.
public extension TimelineEditor {
    static let scaleId = "transform.scale", opacityId = "visual.opacity", volumeId = "audio.volume"

    func isAnimated(clipId: String, _ parameterId: String) -> Bool {
        clip(clipId)?.clip.parameterTracks.contains { $0.parameterId == parameterId && !$0.keyframes.isEmpty } ?? false
    }

    /// Whether the parameter has an explicit value (static or animated): drives the value tier.
    func isExplicit(clipId: String, _ parameterId: String) -> Bool {
        guard let c = clip(clipId)?.clip else { return false }
        return c.staticParameters?[parameterId] != nil || isAnimated(clipId: clipId, parameterId)
    }

    /// Sets a parameter: a keyframe at the playhead when it is animated, otherwise its static value.
    @discardableResult
    func setParameter(clipId: String, _ parameterId: String, _ value: NativeParameterValue, time: Double) -> Bool {
        guard !isClipLocked(clipId), let (_, c) = clip(clipId), let a = parameterAddress(clipId: clipId, parameterId),
              let frame = localFrame(clipId: clipId, time: time) else { return false }
        if isAnimated(clipId: clipId, parameterId) {
            let type: NativeValueType
            switch value { case .number: type = .number; case .vec2: type = .vec2; case .rgba: type = .rgba }
            return applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: type, frame: frame, value: value,
                                                            baselineValue: c.staticParameters?[parameterId] ?? value))))
        }
        if c.staticParameters?[parameterId] == value { return false }
        return applyProperty(.atomic(.setStatic(address: a, value: value)))
    }

    /// Removes a static value (the ↺ "fall back to default" affordance). Animated parameters are left alone.
    @discardableResult
    func clearStaticParameter(clipId: String, _ parameterId: String) -> Bool {
        editClip(clipId) { c in
            guard var sp = c.staticParameters, sp[parameterId] != nil else { return false }
            sp[parameterId] = nil
            c.staticParameters = sp.isEmpty ? nil : sp
            return true
        }
    }

    /// "Reset all Design changes": drops every static parameter, keyframe track and crop of the clip.
    @discardableResult
    func resetDesign(clipId: String) -> Bool {
        editClip(clipId) { c in
            guard c.staticParameters != nil || !c.parameterTracks.isEmpty || c.crop != nil || c.style != nil else { return false }
            c.staticParameters = nil; c.parameterTracks = []; c.crop = nil; c.cropPivotSegments = nil; c.style = nil
            return true
        }
    }

    func numberValue(clipId: String, _ parameterId: String, time: Double) -> Double? {
        switch parameterValue(clipId: clipId, parameterId: parameterId, time: time) {
        case .number(let v)?: return v
        case .vec2(let v)?: return v.x
        default: return nil
        }
    }

    // MARK: Keyframes (per property, inspector ◆ buttons)

    /// Clip-local keyframe frames of a parameter, sorted.
    func keyframeFrames(clipId: String, _ parameterId: String) -> [Double] {
        clip(clipId)?.clip.parameterTracks.first { $0.parameterId == parameterId }?.keyframes.map(\.frame).sorted() ?? []
    }

    func hasKeyframe(clipId: String, _ parameterId: String, time: Double) -> Bool {
        guard let f = localFrame(clipId: clipId, time: time) else { return false }
        return keyframeFrames(clipId: clipId, parameterId).contains(f)
    }

    /// ◆: add a keyframe holding the current value at the playhead, or remove the one there.
    @discardableResult
    func toggleKeyframe(clipId: String, _ parameterId: String, time: Double, fallback: NativeParameterValue) -> Bool {
        guard !isClipLocked(clipId), let (_, c) = clip(clipId), let a = parameterAddress(clipId: clipId, parameterId),
              let f = localFrame(clipId: clipId, time: time) else { return false }
        if hasKeyframe(clipId: clipId, parameterId, time: time) {
            return applyProperty(.atomic(.keyframe(.delete(address: a, frame: f))))
        }
        let v = parameterValue(clipId: clipId, parameterId: parameterId, time: time) ?? fallback
        let type: NativeValueType
        switch v { case .number: type = .number; case .vec2: type = .vec2; case .rgba: type = .rgba }
        return applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: type, frame: f, value: v,
                                                        baselineValue: c.staticParameters?[parameterId] ?? v))))
    }

    /// Composition time of the previous/next keyframe of the parameter relative to `time`.
    func adjacentKeyframeTime(clipId: String, _ parameterId: String, time: Double, forward: Bool) -> Double? {
        guard let (_, c) = clip(clipId) else { return nil }
        let now = (time * fps).rounded() - c.startFrame
        let frames = keyframeFrames(clipId: clipId, parameterId)
        let pick = forward ? frames.first { $0 > now } : frames.last { $0 < now }
        return pick.map { ($0 + c.startFrame) / fps }
    }

    /// Outgoing interpolation of the keyframe at the playhead (or the last one before it).
    func interpolation(clipId: String, _ parameterId: String, time: Double) -> NativeInterpolation? {
        guard let (_, c) = clip(clipId), let track = c.parameterTracks.first(where: { $0.parameterId == parameterId }),
              let f = localFrame(clipId: clipId, time: time) else { return nil }
        return (track.keyframes.last { $0.frame <= f } ?? track.keyframes.first)?.outgoing
    }

    /// The keyframe at/before the playhead (else the first) of each listed parameter that has keys.
    func keyframesAtOrBefore(clipId: String, parameterIds: [String], time: Double) -> [TimelineKeyframeRef] {
        guard let (_, c) = clip(clipId), let f = localFrame(clipId: clipId, time: time) else { return [] }
        return parameterIds.compactMap { pid in
            guard let track = c.parameterTracks.first(where: { $0.parameterId == pid }),
                  let k = track.keyframes.last(where: { $0.frame <= f }) ?? track.keyframes.first else { return nil }
            return TimelineKeyframeRef(clipId: clipId, parameterId: pid, frame: k.frame)
        }
    }

    /// Keyframe easing for the keyframe at/before the playhead of each listed parameter (one undo step).
    @discardableResult
    func setInterpolation(clipId: String, parameterIds: [String], time: Double, _ outgoing: NativeInterpolation) -> Bool {
        setOutgoing(keyframesAtOrBefore(clipId: clipId, parameterIds: parameterIds, time: time), outgoing)
    }

    // MARK: Effects

    @discardableResult
    func setEffectEnabled(clipId: String, effectId: String, _ enabled: Bool) -> Bool {
        editClip(clipId) { c in
            guard let i = c.effects.firstIndex(where: { $0.id == effectId }), c.effects[i].enabled != enabled else { return false }
            c.effects[i].enabled = enabled; return true
        }
    }

    @discardableResult
    func removeEffect(clipId: String, effectId: String) -> Bool {
        editClip(clipId) { c in
            guard let i = c.effects.firstIndex(where: { $0.id == effectId }) else { return false }
            c.effects.remove(at: i); return true
        }
    }

    // MARK: Helpers

    /// Edits one clip in a copy of the document, validates, and commits with a restore-document inverse.
    @discardableResult
    func editClip(_ clipId: String, _ body: (inout NativeProjectClip) -> Bool) -> Bool {
        guard !isClipLocked(clipId) else { return false }
        var d = document
        for t in d.sequence.tracks.indices {
            if let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) {
                guard body(&d.sequence.tracks[t].clips[i]) else { return false }
                return commitValidated(d)
            }
        }
        return false
    }

    func commitValidated(_ d: NativeProjectDocument) -> Bool {
        guard d != document, let validated = try? parseNativeProjectDocument(d, engine: engine) else { return false }
        replaceDocument(validated, inverse: .restoreDocument(document))
        return true
    }
}

// MARK: - Color grading (stored as the clip's "color-grading" effect)
public extension TimelineEditor {
    func colorGrading(clipId: String) -> ColorGrading? {
        guard let e = clip(clipId)?.clip.effects.first(where: { $0.effectId == ColorGrading.effectId }) else { return nil }
        var g = ColorGrading(json: e.parameters ?? NativeJSONObject())
        if !e.enabled { g.enabled = false }
        return g
    }

    /// Writes the grade (nil or neutral removes it). One undo step.
    @discardableResult
    func setColorGrading(clipId: String, _ grading: ColorGrading?) -> Bool {
        editClip(clipId) { c in
            let i = c.effects.firstIndex { $0.effectId == ColorGrading.effectId }
            guard let g = grading, g.isAuthored else {
                guard let i else { return false }
                c.effects.remove(at: i); return true
            }
            if let i {
                let next = NativeClipEffect(id: c.effects[i].id, effectId: ColorGrading.effectId, enabled: g.enabled, parameters: g.json, spread: c.effects[i].spread)
                guard next != c.effects[i] else { return false }
                c.effects[i] = next
            } else {
                var n = 1; let ids = Set(c.effects.map(\.id)); while ids.contains("effect:grade-\(n)") { n += 1 }
                c.effects.append(NativeClipEffect(id: "effect:grade-\(n)", effectId: ColorGrading.effectId, enabled: g.enabled, parameters: g.json))
            }
            return true
        }
    }

    /// "Copy grade to": the same grade on every visual clip of the same asset ("source-file") or of the project.
    @discardableResult
    func copyColorGrading(from clipId: String, toAllProjectMedia: Bool) -> Int {
        guard let g = colorGrading(clipId: clipId), let src = clip(clipId)?.clip else { return 0 }
        let kinds = Dictionary(document.assets.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        var d = document; var count = 0
        for t in d.sequence.tracks.indices where t >= 0 && d.sequence.tracks[t].locked != true {
            for ci in d.sequence.tracks[t].clips.indices {
                let c = d.sequence.tracks[t].clips[ci]
                guard c.id != clipId, let k = kinds[c.assetId], k == .video || k == .image, toAllProjectMedia || c.assetId == src.assetId else { continue }
                var e = d.sequence.tracks[t].clips[ci].effects
                let eff = NativeClipEffect(id: e.first { $0.effectId == ColorGrading.effectId }?.id ?? "effect:grade-1", effectId: ColorGrading.effectId,
                                           enabled: g.enabled, parameters: g.json)
                if let i = e.firstIndex(where: { $0.effectId == ColorGrading.effectId }) { e[i] = eff } else { e.append(eff) }
                d.sequence.tracks[t].clips[ci].effects = e; count += 1
            }
        }
        return count > 0 && commitValidated(d) ? count : 0
    }
}
