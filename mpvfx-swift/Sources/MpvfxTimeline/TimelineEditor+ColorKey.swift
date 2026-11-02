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

/// A clip's colour key (issue #300): the settings of its `color-key` effect, `{ v: 1, kind: "chroma", color, similarity,
/// smoothness, spill }`. `color` is linear RGB, 0…1 per channel; the other three are 0…1. A value that holds its default is
/// not written, so a key that only turns the effect on stores just `v` and `kind`.
public struct ColorKeySettings: Equatable, Sendable {
    public static let defaultColor = [0.0, 1.0, 0.0]
    public static let defaultSimilarity = 0.1, defaultSmoothness = 0.1, defaultSpill = 0.0
    public var color = Self.defaultColor
    public var similarity = Self.defaultSimilarity
    public var smoothness = Self.defaultSmoothness
    public var spill = Self.defaultSpill
    public init() {}

    var json: NativeJSONObject {
        var o: NativeJSONObject = ["v": .number(1), "kind": .string("chroma")]
        if color != Self.defaultColor { o["color"] = .array(color.map { .number($0) }) }
        if similarity != Self.defaultSimilarity { o["similarity"] = .number(similarity) }
        if smoothness != Self.defaultSmoothness { o["smoothness"] = .number(smoothness) }
        if spill != Self.defaultSpill { o["spill"] = .number(spill) }
        return o
    }

    /// Nil for parameters that are not version 1 of the chroma contract (a newer editor's key: kept, not edited).
    init?(_ p: NativeJSONObject?) {
        guard let p, p["v"]?.numberValue == 1, p["kind"]?.stringValue == "chroma" else { return nil }
        if let c = p["color"] {
            guard let a = c.arrayValue, a.count == 3, let r = a[0].numberValue, let g = a[1].numberValue, let b = a[2].numberValue else { return nil }
            color = [r, g, b]
        }
        similarity = p["similarity"]?.numberValue ?? Self.defaultSimilarity
        smoothness = p["smoothness"]?.numberValue ?? Self.defaultSmoothness
        spill = p["spill"]?.numberValue ?? Self.defaultSpill
    }
}

public extension TimelineEditor {
    static let colorKeyEffectId = "color-key"

    private func colorKeyEffect(_ clipId: String) -> NativeClipEffect? {
        clip(clipId)?.clip.effects.first { $0.effectId == Self.colorKeyEffectId }
    }

    /// The clip's colour key; nil when it has none, or one from a newer version of the editor.
    func colorKey(clipId: String) -> ColorKeySettings? { ColorKeySettings(colorKeyEffect(clipId)?.parameters) }

    /// Whether the clip's colour key is switched on (false with none).
    func isColorKeyEnabled(clipId: String) -> Bool { colorKeyEffect(clipId)?.enabled ?? false }

    /// Writes the clip's colour key (nil removes it), adding the effect when the clip has none. One undo step; false,
    /// with nothing recorded, when nothing changes, the clip is locked or missing, the key is from a newer version, or
    /// the document refuses a value (outside 0…1).
    @discardableResult
    func setColorKey(clipId: String, _ settings: ColorKeySettings?, label: String = "Edit color key", coalesceKey: String? = nil) -> Bool {
        editClipEffects(clipId, label: label, coalesceKey: coalesceKey) { effects in
            let i = effects.firstIndex { $0.effectId == Self.colorKeyEffectId }
            if let i, ColorKeySettings(effects[i].parameters) == nil { return false }   // a newer version's key stays as it is
            guard let settings else {
                guard let i else { return false }
                effects.remove(at: i); return true
            }
            if let i {
                guard effects[i].parameters != settings.json else { return false }
                effects[i].parameters = settings.json
            } else {
                var n = 1
                while effects.contains(where: { $0.id == "effect:color-key-\(n)" }) { n += 1 }
                effects.append(NativeClipEffect(id: "effect:color-key-\(n)", effectId: Self.colorKeyEffectId, enabled: true, parameters: settings.json))
            }
            return true
        }
    }

    /// Switches the clip's colour key on or off without touching its settings.
    @discardableResult
    func setColorKeyEnabled(clipId: String, _ enabled: Bool) -> Bool {
        editClipEffects(clipId, label: enabled ? "Turn on color key" : "Turn off color key") { effects in
            guard let i = effects.firstIndex(where: { $0.effectId == Self.colorKeyEffectId }), effects[i].enabled != enabled else { return false }
            effects[i].enabled = enabled; return true
        }
    }

    private func editClipEffects(_ clipId: String, label: String, coalesceKey: String? = nil,
                                 _ body: (inout [NativeClipEffect]) -> Bool) -> Bool {
        guard !isClipLocked(clipId) else { return false }
        var d = document
        for t in d.sequence.tracks.indices {
            guard let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            guard body(&d.sequence.tracks[t].clips[i].effects) else { return false }
            return withHistory(label, coalesceKey: coalesceKey) { commitPresets(d, label: label) }
        }
        return false
    }
}
