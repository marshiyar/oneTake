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
import MpvfxTimeline

extension InspectorPanel {
    static func gainSliderInput(_ text: String) -> Double? {
        if text.trimmingCharacters(in: .whitespaces).lowercased() == "-∞ db" { return AudioGainFader.min }
        guard let db = PanelFormat.parse(text), db.isFinite else { return nil }
        // Clamp the displayed dB before converting; AudioGainFader.clamp treats infinite gain as unity.
        return AudioGainFader.position(gain: pow(10, max(-60, min(12, db)) / 20))
    }

    static func effectSliderInput(_ text: String, key: String) -> Double? {
        guard let x = PanelFormat.parse(text.replacingOccurrences(of: "deg", with: "°")), x.isFinite else { return nil }
        switch key {
        case "blur": return pow(max(0, (x - 0.75) / 32), 1 / 1.35) * 100
        case "pixelate": return (x - 1) / 47 * 100
        case "scanlineCount": return (x - 50) / 450 * 100
        case "ditherSize": return (x - 1) / 4 * 100
        case "monoScreenSize": return (x - 4) / 14 * 100
        case "asciiSize": return (x - 4) / 76 * 100
        case "kuwaharaRadius": return (x - 2) / 14 * 100
        case "kuwaharaSaturation": return x / 2
        default: return x
        }
    }

    func sliderInput(_ text: String, _ s: InspectorRow.Slider) -> Double? {
        if let parse = s.parseInput { return parse(text) }
        return PanelFormat.parse(text.replacingOccurrences(of: "×", with: "x"))
    }

    /// Use the same commit as the pointer, so animated properties write a key at the playhead.
    func sliderKey(_ k: EditorKey) -> Bool {
        guard focus.visible, !k.command, !k.alt, let hit = focus.current else { return false }
        let key: String
        switch hit {
        case .slider(let id), .field(let id): key = id
        default: return false
        }
        guard let s = slider(key), !s.disabled else { return false }
        switch k.code {
        case .enter, .space:
            openField(key); onEdited?(); return true
        case .delete, .backspace:
            if !k.isRepeat { s.reset?(); onEdited?() }
            return true
        case .left, .right, .up, .down, .home, .end:
            commitSliderKey(k, s); return true
        default: return false
        }
    }

    func commitSliderKey(_ k: EditorKey, _ s: InspectorRow.Slider) {
        let step = (s.step ?? (s.max - s.min) / 100) * (k.shift ? 10 : 1)
        let value: Double
        switch k.code {
        case .home: value = s.min
        case .end: value = s.max
        case .left, .down: value = max(s.min, s.position - step)
        default: value = min(s.max, s.position + step)
        }
        guard value != s.position, let editor else { return }
        let old = sliderKeySequence
        let repeating = k.isRepeat && old?.key == s.key && old?.selection == selection && old?.time == time && old?.code == k.code
        let token = repeating ? (old?.token ?? UUID().uuidString) : UUID().uuidString
        sliderKeySequence = (s.key, selection, time, k.code, token)
        // A host's initial repeat delay may exceed the editor's normal coalescing window.
        let window = editor.coalesceWindow
        if repeating { editor.coalesceWindow = .infinity }
        defer { editor.coalesceWindow = window }
        editor.withHistory("Set \(s.label)", coalesceKey: "inspector-slider:\(token)") { s.commit(value) }
        onEdited?()
    }
}
