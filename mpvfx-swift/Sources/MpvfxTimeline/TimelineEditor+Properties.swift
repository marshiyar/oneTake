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

/// Stage transform values for one clip at one time: transform.position (vec2, canvas px offset),
/// layout.width / layout.height (px), transform.rotation (degrees).
public struct ClipTransform: Equatable, Sendable {
    public var x: Double?, y: Double?, width: Double?, height: Double?, rotation: Double?
    public init(x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil, rotation: Double? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.rotation = rotation
    }
}

public extension TimelineEditor {
    static let positionId = "transform.position", rotationId = "transform.rotation"
    static let widthId = "layout.width", heightId = "layout.height"

    func clip(_ id: String) -> (track: NativeProjectTrack, clip: NativeProjectClip)? {
        for t in document.sequence.tracks { if let c = t.clips.first(where: { $0.id == id }) { return (t, c) } }
        return nil
    }

    /// Clip-local integer frame for a composition time, clamped into the clip.
    func localFrame(clipId: String, time: Double) -> Double? {
        guard let (_, c) = clip(clipId) else { return nil }
        return max(0, min(c.durationFrames - 1, (time * fps).rounded() - c.startFrame))
    }

    /// Current value of a parameter: its animated track at `time` if any, else the static value.
    func parameterValue(clipId: String, parameterId: String, time: Double) -> NativeParameterValue? {
        guard let (_, c) = clip(clipId) else { return nil }
        if let track = c.parameterTracks.first(where: { $0.parameterId == parameterId }), !track.keyframes.isEmpty,
           let f = localFrame(clipId: clipId, time: time) {
            return try? evaluateNativeParameterTrack(track, projectFrame: f, engine: engine)
        }
        if let box = naturalLayout(clipId: clipId) {
            switch parameterId {
            case "layout.left": return .number(box.left)
            case "layout.top": return .number(box.top)
            case Self.widthId: return .number(box.width)
            case Self.heightId: return .number(box.height)
            default: break
            }
        }
        return c.staticParameters?[parameterId]
    }

    /// The default box (fitTimelineAssetGeometry of the media's natural size) when the clip's size is untouched,
    /// else nil (nativeClipNaturalLayout).
    func naturalLayout(clipId: String) -> NativeClipLayoutBox? {
        guard let (_, c) = clip(clipId), let asset = document.assets.first(where: { $0.id == c.assetId }),
              asset.kind == .video || asset.kind == .image else { return nil }
        return nativeClipNaturalLayout(c, natural: naturalSize(asset), canvasWidth: document.canvas.width, canvasHeight: document.canvas.height)
    }

    /// The default box for the clip's media whether or not its size was edited (full canvas when unknown).
    func defaultLayout(clipId: String) -> NativeClipLayoutBox {
        let asset = clip(clipId).flatMap { c in document.assets.first { $0.id == c.clip.assetId } }
        let natural = asset.flatMap { $0.kind == .video || $0.kind == .image ? naturalSize($0) : nil }
        return fitTimelineAssetGeometry(natural, compWidth: document.canvas.width, compHeight: document.canvas.height)
    }

    /// layout.left / layout.top at `time` (the box origin transform.position offsets).
    func layoutOrigin(clipId: String, time: Double) -> (x: Double, y: Double) {
        func num(_ id: String) -> Double { if case .number(let v)? = parameterValue(clipId: clipId, parameterId: id, time: time) { return v }; return 0 }
        return (num("layout.left"), num("layout.top"))
    }

    /// Static commands that write a clip's natural default box out, so an edit to its geometry starts from the
    /// box it shows (a resize keeps the clip's current left/top/width/height as its starting point).
    internal func bakeNaturalLayout(clipId: String) -> [NativeProjectAtomicPropertyCommand] {
        guard let box = naturalLayout(clipId: clipId), let (track, _) = clip(clipId) else { return [] }
        return [("layout.left", box.left), ("layout.top", box.top), (Self.widthId, box.width), (Self.heightId, box.height)].map {
            .setStatic(address: NativeProjectParameterAddress(sequenceId: sequenceId, trackId: track.id, clipId: clipId, parameterId: $0.0),
                       value: .number($0.1))
        }
    }

    /// Size ↺: back to the natural default box (layout.left/top/width/height cleared), one undo step.
    @discardableResult
    func resetSize(clipId: String) -> Bool {
        guard let (track, c) = clip(clipId), track.locked != true, naturalLayout(clipId: clipId) == nil else { return false }
        let ids = NATIVE_CLIP_LAYOUT_PARAMETERS
        guard !c.parameterTracks.contains(where: { ids.contains($0.parameterId) && !$0.keyframes.isEmpty }),
              ids.contains(where: { c.staticParameters?[$0] != nil }) else { return false }
        var d = document
        guard let t = d.sequence.tracks.firstIndex(where: { $0.id == track.id }),
              let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) else { return false }
        var sp = d.sequence.tracks[t].clips[i].staticParameters ?? [:]
        for id in ids { sp[id] = nil }
        d.sequence.tracks[t].clips[i].staticParameters = sp.isEmpty ? nil : sp
        let before = document
        guard let validated = try? parseNativeProjectDocument(d, engine: engine) else { return false }
        withHistory("Reset size") { replaceDocument(validated, inverse: .restoreDocument(before)) }
        return true
    }

    func transform(clipId: String, time: Double) -> ClipTransform {
        var t = ClipTransform()
        if case .vec2(let p)? = parameterValue(clipId: clipId, parameterId: Self.positionId, time: time) { t.x = p.x; t.y = p.y }
        if case .number(let v)? = parameterValue(clipId: clipId, parameterId: Self.widthId, time: time) { t.width = v }
        if case .number(let v)? = parameterValue(clipId: clipId, parameterId: Self.heightId, time: time) { t.height = v }
        if case .number(let v)? = parameterValue(clipId: clipId, parameterId: Self.rotationId, time: time) { t.rotation = v }
        return t
    }

    /// Writes the non-nil fields. Animated parameters get a keyframe at the playhead ("Drag: Move element /
    /// add keyframe"); static ones are set. One undo step for the whole edit.
    @discardableResult
    func applyTransform(clipId: String, time: Double, _ t: ClipTransform) -> Bool {
        guard let (track, c) = clip(clipId), let frame = localFrame(clipId: clipId, time: time) else { return false }
        var cmds: [NativeProjectAtomicPropertyCommand] = []
        func put(_ pid: String, _ type: NativeValueType, _ v: NativeParameterValue) {
            let a = NativeProjectParameterAddress(sequenceId: sequenceId, trackId: track.id, clipId: clipId, parameterId: pid)
            if c.parameterTracks.contains(where: { $0.parameterId == pid && !$0.keyframes.isEmpty }) {
                let baseline = c.staticParameters?[pid] ?? v
                cmds.append(.keyframe(.upsert(address: a, valueType: type, frame: frame, value: v, baselineValue: baseline)))
            } else {
                cmds.append(.setStatic(address: a, value: v))
            }
        }
        if let x = t.x, let y = t.y { put(Self.positionId, .vec2, .vec2(Vec2Value(x: x, y: y))) }
        if let w = t.width { put(Self.widthId, .number, .number(w)) }
        if let h = t.height { put(Self.heightId, .number, .number(h)) }
        if let r = t.rotation { put(Self.rotationId, .number, .number(r)) }
        guard !cmds.isEmpty else { return false }
        return applyProperty(cmds.count == 1 ? .atomic(cmds[0]) : .batch(cmds))
    }

    func parameterAddress(clipId: String, _ parameterId: String) -> NativeProjectParameterAddress? {
        guard let (track, _) = clip(clipId) else { return nil }
        return NativeProjectParameterAddress(sequenceId: sequenceId, trackId: track.id, clipId: clipId, parameterId: parameterId)
    }

    /// Outgoing interpolation of one authored keyframe (nil when there is no key at that frame).
    func outgoing(_ ref: TimelineKeyframeRef) -> NativeInterpolation? {
        guard let (_, c) = clip(ref.clipId), let track = c.parameterTracks.first(where: { $0.parameterId == ref.parameterId }) else { return nil }
        return track.keyframes.first { $0.frame == ref.frame }?.outgoing
    }

    /// Sets the outgoing interpolation of each listed keyframe (one undo step); false when nothing changes.
    @discardableResult
    func setOutgoing(_ refs: [TimelineKeyframeRef], _ outgoing: NativeInterpolation) -> Bool {
        var cmds: [NativeProjectAtomicPropertyCommand] = []
        for r in refs {
            guard let cur = self.outgoing(r), cur != outgoing, let a = parameterAddress(clipId: r.clipId, r.parameterId) else { continue }
            cmds.append(.keyframe(.setOutgoing(address: a, frame: r.frame, outgoing: outgoing)))
        }
        guard !cmds.isEmpty else { return false }
        return applyProperty(cmds.count == 1 ? .atomic(cmds[0]) : .batch(cmds))
    }

    /// Property commands return no inverse; undo restores the prior document (restoreDocument).
    @discardableResult
    func applyProperty(_ command: NativeProjectPropertyCommand) -> Bool {
        // A locked track takes no property edits (inspector, stage drags, keyframes): the lock guards the clips.
        let atoms: [NativeProjectAtomicPropertyCommand]
        switch command { case .atomic(let a): atoms = [a]; case .batch(let b): atoms = b }
        if atoms.contains(where: { isTrackLocked(Self.address(of: $0).trackId) }) {
            lastPropertyFailure = .init(code: .documentMismatch, message: "Track is locked"); return false
        }
        // An edit to an untouched clip's geometry first writes out the natural box it shows (same undo step).
        var baked: [NativeProjectAtomicPropertyCommand] = []
        for id in Set(atoms.map { Self.address(of: $0) }.filter { NATIVE_CLIP_LAYOUT_PARAMETERS.contains($0.parameterId) }.map(\.clipId)).sorted() {
            baked += bakeNaturalLayout(clipId: id)
        }
        let command: NativeProjectPropertyCommand = baked.isEmpty ? command : .batch(baked + atoms)
        let before = document
        guard let r = try? applyNativeProjectPropertyCommand(document, command, engine: engine) else { return false }
        guard case .success(let doc) = r else {
            if case .failure(_, let f) = r { lastPropertyFailure = f }
            return false
        }
        withHistory("Edit property") { replaceDocument(doc, inverse: .restoreDocument(before)) }
        return true
    }
}

extension TimelineEditor {
    static func address(of a: NativeProjectAtomicPropertyCommand) -> NativeProjectParameterAddress {
        switch a {
        case .setStatic(let ad, _), .offsetTrack(let ad, _), .collapseTrack(let ad, _): return ad
        case .keyframe(let k):
            switch k {
            case .upsert(let ad, _, _, _, _, _), .updateValue(let ad, _, _), .delete(let ad, _), .move(let ad, _, _),
                 .moveMany(let ad, _, _), .deleteMany(let ad, _), .setOutgoing(let ad, _, _), .setMotionPath(let ad, _, _),
                 .setAutoRotate(let ad, _): return ad
            }
        }
    }
}

// MARK: - Position keyframe toggle
public extension TimelineEditor {
    /// Frame (clip-local) of a position keyframe at the playhead, if one exists.
    func positionKeyframeActive(clipId: String, time: Double) -> Bool {
        guard let (_, c) = clip(clipId), let f = localFrame(clipId: clipId, time: time) else { return false }
        return c.parameterTracks.contains { $0.parameterId == Self.positionId && $0.keyframes.contains { $0.frame == f } }
    }

    /// Toolbar/K toggle: remove the position keyframe at the playhead, or add one holding the current position.
    @discardableResult
    func togglePositionKeyframe(clipId: String, time: Double) -> Bool {
        guard let (track, c) = clip(clipId), let f = localFrame(clipId: clipId, time: time) else { return false }
        let a = NativeProjectParameterAddress(sequenceId: sequenceId, trackId: track.id, clipId: clipId, parameterId: Self.positionId)
        if positionKeyframeActive(clipId: clipId, time: time) {
            return applyProperty(.atomic(.keyframe(.delete(address: a, frame: f))))
        }
        let cur = transform(clipId: clipId, time: time)
        let v = NativeParameterValue.vec2(Vec2Value(x: cur.x ?? 0, y: cur.y ?? 0))
        return applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: .vec2, frame: f, value: v,
                                                        baselineValue: c.staticParameters?[Self.positionId] ?? v))))
    }
}

/// useKeyframeKeyboard (capture phase, before playback JKL): with a keyframeable (non-audio) element selected
/// on the stage, K toggles its position keyframe at the playhead. Otherwise K falls through to playback (pause).
public enum KeyframeKeyboard {
    public static func handle(_ k: EditorKey, editor: TimelineEditor, stageSelection: String?, kind: TimelineClipKind?, time: Double) -> Bool {
        guard !k.command, !k.alt, let id = stageSelection, kind != .audio else { return false }
        if case .char(let ch) = k.code, ch == "k" || ch == "K" { return editor.togglePositionKeyframe(clipId: id, time: time) }
        return false
    }
}

// MARK: - Crop (stored on the clip in the native document)
public extension TimelineEditor {
    func crop(clipId: String) -> NativeClipCrop? { clip(clipId)?.1.crop }

    /// Sets (or clears, for nil / all-zero) a clip's crop as one undo step. Returns false if nothing changed.
    @discardableResult
    func setCrop(clipId: String, _ crop: NativeClipCrop?) -> Bool {
        let next = (crop?.isZero ?? true) ? nil : crop
        guard let (track, c) = clip(clipId), c.crop != next, track.locked != true else { return false }
        let before = document
        var doc = document
        guard let t = doc.sequence.tracks.firstIndex(where: { $0.id == track.id }),
              let i = doc.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) else { return false }
        doc.sequence.tracks[t].clips[i].crop = next
        // Crop insets are measured on the box the clip shows: keep its natural default box written out.
        if let box = naturalLayout(clipId: clipId) {
            var sp = doc.sequence.tracks[t].clips[i].staticParameters ?? [:]
            sp["layout.left"] = .number(box.left); sp["layout.top"] = .number(box.top)
            sp[Self.widthId] = .number(box.width); sp[Self.heightId] = .number(box.height)
            doc.sequence.tracks[t].clips[i].staticParameters = sp
        }
        guard let validated = try? parseNativeProjectDocument(doc, engine: engine) else { return false }
        withHistory("Crop clip") { replaceDocument(validated, inverse: .restoreDocument(before)) }
        return true
    }
}
