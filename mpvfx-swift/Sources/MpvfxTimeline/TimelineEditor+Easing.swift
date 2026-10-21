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

/// Document edits behind the Keyframe Easing panel and the easy-ease keys (F9): per-key outgoing curves, easy ease on
/// either side of a key, and the project's custom presets. Each call is one undo step.
public extension TimelineEditor {
    /// Sets each listed key's outgoing curve in one undo step; false when nothing changes (or a key is missing).
    @discardableResult
    func setOutgoing(_ changes: [(TimelineKeyframeRef, NativeInterpolation)]) -> Bool {
        var cmds: [NativeProjectAtomicPropertyCommand] = []
        for (r, v) in changes {
            guard let cur = outgoing(r), cur != v, let a = parameterAddress(clipId: r.clipId, r.parameterId) else { continue }
            cmds.append(.keyframe(.setOutgoing(address: a, frame: r.frame, outgoing: v)))
        }
        guard !cmds.isEmpty else { return false }
        return applyProperty(cmds.count == 1 ? .atomic(cmds[0]) : .batch(cmds))
    }

    /// The authored key before `ref` on its parameter, nil for the first.
    func previousKeyframe(_ ref: TimelineKeyframeRef) -> TimelineKeyframeRef? {
        neighbour(ref) { frames, f in frames.last { $0 < f } }
    }

    /// The authored key after `ref` on its parameter, nil for the last.
    func nextKeyframe(_ ref: TimelineKeyframeRef) -> TimelineKeyframeRef? {
        neighbour(ref) { frames, f in frames.first { $0 > f } }
    }

    /// Easy ease (F9; ⇧F9 in only, ⌘⇧F9 out only): each key's out side is its own outgoing curve, its in side the
    /// previous key's. Sides with no segment (the first key's in, the last key's out) and holds are left alone.
    @discardableResult
    func easyEase(_ refs: [TimelineKeyframeRef], out: Bool, in inSide: Bool) -> Bool {
        var next: [TimelineKeyframeRef: NativeInterpolation] = [:]
        var order: [TimelineKeyframeRef] = []
        func ease(_ r: TimelineKeyframeRef, out o: Bool, in i: Bool) {
            guard let cur = next[r] ?? outgoing(r) else { return }
            if next[r] == nil { order.append(r) }
            next[r] = KeyframeEase.easyEase(cur, out: o, in: i)
        }
        for r in refs.sorted(by: { $0.parameterId != $1.parameterId ? $0.parameterId < $1.parameterId : $0.frame < $1.frame }) {
            if out, nextKeyframe(r) != nil { ease(r, out: true, in: false) }
            if inSide, let prev = previousKeyframe(r) { ease(prev, out: false, in: true) }
        }
        return withHistory("Easy ease") { setOutgoing(order.compactMap { r in next[r].map { (r, $0) } }) }
    }

    /// The project's custom easing presets, in saved order.
    var easingPresets: [NativeEasingPreset] { document.easingPresets ?? [] }

    /// Saves a preset (name trimmed and cut to the limit) and returns its id; nil when the name is blank, the list is
    /// full or the curve is not one the document accepts.
    @discardableResult
    func saveEasingPreset(name: String, outgoing: NativeInterpolation) -> String? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(NATIVE_EASING_PRESET_NAME_LIMIT))
        guard !trimmed.isEmpty, easingPresets.count < NATIVE_EASING_PRESET_LIMIT else { return nil }
        let used = Set(easingPresets.map(\.id))
        var n = used.count + 1
        while used.contains("easing-preset:\(n)") { n += 1 }
        let id = "easing-preset:\(n)"
        var d = document
        d.easingPresets = easingPresets + [NativeEasingPreset(id: id, name: trimmed, outgoing: outgoing)]
        return commitPresets(d, label: "Save easing preset") ? id : nil
    }

    /// Deletes one preset; false when no preset has that id.
    @discardableResult
    func deleteEasingPreset(id: String) -> Bool {
        guard easingPresets.contains(where: { $0.id == id }) else { return false }
        var d = document
        let left = easingPresets.filter { $0.id != id }
        d.easingPresets = left.isEmpty ? nil : left
        return commitPresets(d, label: "Delete easing preset")
    }
}

extension TimelineEditor {
    func neighbour(_ ref: TimelineKeyframeRef, _ pick: ([Double], Double) -> Double?) -> TimelineKeyframeRef? {
        guard let (_, c) = clip(ref.clipId), let track = c.parameterTracks.first(where: { $0.parameterId == ref.parameterId }),
              let f = pick(track.keyframes.map(\.frame).sorted(), ref.frame) else { return nil }
        return TimelineKeyframeRef(clipId: ref.clipId, parameterId: ref.parameterId, frame: f)
    }

    /// Validates the changed document and records it with a restore inverse (one undo step).
    func commitPresets(_ d: NativeProjectDocument, label: String) -> Bool {
        let before = document
        do {
            let validated = try parseNativeProjectDocument(d, engine: engine)
            withHistory(label) { replaceDocument(validated, inverse: .restoreDocument(before)) }
            return true
        } catch {
            return false   // the document refused the list (a bad curve): nothing is recorded
        }
    }
}
