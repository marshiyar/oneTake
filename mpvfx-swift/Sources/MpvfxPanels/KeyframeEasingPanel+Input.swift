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
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline

/// Pointer, wheel and keys. A drag (curve handle, speed handle) shows live and commits once, on release; every
/// commit is one undo step over every target key and calls `onEdited`.
extension KeyframeEasingPanel {
    @discardableResult
    public func pointerDown(_ p: CanvasPoint) -> Bool {
        if dropdown.pointerDown(p) { return true }
        let hit = hits.hit(p)
        if field != nil, case .field(let k)? = hit, k == field?.key { return true }
        commitField()
        guard let hit, let editor, let t = target else { return false }
        press(hit, p, editor, t)
        return true
    }

    func press(_ hit: Hit, _ p: CanvasPoint, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) {
        if pressView(hit, p, t) { return }
        let current = t.focused.flatMap { editor.outgoing($0) }
        switch hit {
        case .copy: state.copy(editor, t)
        case .paste: edited(state.paste(editor, t))
        case .speedHandle(let side): drag = speedDragStart(side, editor, t)
        case .curveHandle(let i): drag = curvePoints(current).map { .curveHandle(i, $0) }
        case .preset(let key): Self.presets.first { $0.key == key }.map { edited(KeyframeEasing.apply(editor, t, $0.value)) }
        case .customPreset(let id): editor.easingPresets.first { $0.id == id }.map { edited(KeyframeEasing.apply(editor, t, $0.outgoing)) }
        case .deletePreset(let id): edited(editor.deleteEasingPreset(id: id))
        case .field(let key): field = PanelTextField(key: key, value: fieldValue(key, editor, t, current))
        default: break
        }
    }

    /// Presses that change only what the panel shows (no document edit); true when `hit` was one.
    func pressView(_ hit: Hit, _ p: CanvasPoint, _ t: KeyframeEasingTarget) -> Bool {
        switch hit {
        case .property: openPropertyMenu(t)
        case .graphMode(let g): state.graph = g
        case .zoomIn: state.zoom *= 1.5
        case .zoomOut: state.zoom /= 1.5
        case .fit: state.zoom = 1; state.pan = 0
        case .graph: drag = .pan(startX: p.x, startPan: state.pan)
        case .curve, .preview: startPreview()
        case .savePreset: field = PanelTextField(key: "presetName", value: "")
        case .disabled: break
        default: return false
        }
        return true
    }

    func speedDragStart(_ side: KeyframeEasing.Side, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> Drag? {
        guard let f = t.focused, let s = KeyframeEasing.sides(editor, f) else { return nil }
        return side == .out ? .speedHandle(.out, influence: s.outInfluence, velocity: s.outVelocity)
                            : .speedHandle(.in, influence: s.inInfluence, velocity: s.inVelocity)
    }

    func openPropertyMenu(_ t: KeyframeEasingTarget) {
        guard let anchor = hits.rect(where: { $0 == .property }) else { return }
        let options = t.properties.map { PanelDropdown.Option(value: $0, label: Self.label($0)) }
        dropdown.open(key: "easing-property", options: options, selected: t.parameterId, anchor: anchor, bounds: bounds) { [weak self] v in
            guard let self else { return }
            self.state.chosenProperty = v
            // The panel now shows another property: keys selected on the old one no longer apply.
            self.selectedKeyframes = self.selectedKeyframes.filter { $0.parameterId == v }
        }
    }

    @discardableResult
    public func pointerMove(_ p: CanvasPoint) -> Bool {
        if dropdown.isOpen { return dropdown.pointerMove(p) }
        guard let d = drag else {
            let h = hits.hit(p)
            defer { hovered = h }
            return h != hovered
        }
        switch d {
        case .pan(let x0, let pan0):
            let w = graphBox?.plot.width ?? 1
            state.pan = pan0 - (p.x - x0) / max(1, w) / state.zoom
        case .speedHandle(let side, _, _):
            if let v = speedHandleValues(side, at: p) { drag = .speedHandle(side, influence: v.influence, velocity: v.velocity) }
        case .curveHandle(let i, var q):
            guard let box = curveBox else { return false }
            let x = (p.x - box.plot.x) / max(1, box.plot.width)
            let y = box.range.lowerBound + (box.plot.maxY - p.y) / max(1, box.plot.height) * (box.range.upperBound - box.range.lowerBound)
            if i == 1 { q.x1 = x; q.y1 = y } else { q.x2 = x; q.y2 = y }
            drag = .curveHandle(i, InspectorPanel.clampCubic(q))
        }
        return true
    }

    public func pointerUp(_ p: CanvasPoint) {
        guard let d = drag else { return }
        drag = nil
        guard let editor, let t = target else { return }
        switch d {
        case .pan: break
        case .speedHandle(let side, let inf, let vel):
            edited(KeyframeEasing.setSide(editor, t, side, influence: inf, velocity: vel))
        case .curveHandle(_, let q):
            edited(KeyframeEasing.apply(editor, t, .cubicBezier(q)))
        }
    }

    /// The wheel over the graph: pan, or zoom with the command key. False elsewhere.
    @discardableResult
    public func scroll(_ p: CanvasPoint, dy: Double, zoom: Bool) -> Bool {
        guard let b = graphBox, b.plot.insetBy(-8).contains(p) else { return false }
        scrollGraph(dy: dy, zoom: zoom)
        return true
    }

    public var isEditingText: Bool { field != nil }

    @discardableResult
    public func keyDown(_ k: EditorKey) -> Bool {
        if dropdown.key(k) { return true }
        guard var f = field else { return false }
        switch f.key(k) {
        case .commit: field = f; commitField()
        case .cancel: field = nil
        case .editing: field = f
        case .none: return false
        }
        return true
    }

    // MARK: Fields

    func fieldValue(_ key: String, _ editor: TimelineEditor, _ t: KeyframeEasingTarget, _ current: NativeInterpolation?) -> String {
        let u = Self.unit(t.parameterId)
        let sides = t.focused.flatMap { KeyframeEasing.sides(editor, $0) }
        let p = curvePoints(current)
        let values: [String: Double?] = [
            "outInfluence": sides.map { $0.outInfluence * 100 }, "inInfluence": sides.map { $0.inInfluence * 100 },
            "outVelocity": sides.map { $0.outVelocity * u.factor }, "inVelocity": sides.map { $0.inVelocity * u.factor },
            "x1": p?.x1, "y1": p?.y1, "x2": p?.x2, "y2": p?.y2,
        ]
        return values[key].flatMap { $0 }.map { PanelFormat.number($0, decimals: 2) } ?? ""
    }

    /// Applies a typed number (or saves a preset name). Unparseable text changes nothing.
    func commitField() {
        guard let f = field else { return }
        field = nil
        guard let editor, let t = target else { return }
        if f.key == "presetName" {
            let current = t.focused.flatMap { editor.outgoing($0) }
            if let v = current { edited(editor.saveEasingPreset(name: f.draft, outgoing: v) != nil) }
            return
        }
        guard f.draft != f.original, let v = PanelFormat.parse(f.draft), v.isFinite else { return }
        edited(applyNumber(f.key, v, editor, t))
    }

    func applyNumber(_ key: String, _ v: Double, _ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> Bool {
        let factor = Self.unit(t.parameterId).factor
        switch key {
        case "outInfluence": return KeyframeEasing.setSide(editor, t, .out, influence: v / 100, velocity: nil)
        case "inInfluence": return KeyframeEasing.setSide(editor, t, .in, influence: v / 100, velocity: nil)
        case "outVelocity": return KeyframeEasing.setSide(editor, t, .out, influence: nil, velocity: v / factor)
        case "inVelocity": return KeyframeEasing.setSide(editor, t, .in, influence: nil, velocity: v / factor)
        default:
            guard var p = curvePoints(t.focused.flatMap { editor.outgoing($0) }) else { return false }
            switch key { case "x1": p.x1 = v; case "y1": p.y1 = v; case "x2": p.x2 = v; default: p.y2 = v }
            return KeyframeEasing.apply(editor, t, .cubicBezier(InspectorPanel.clampCubic(p)))
        }
    }

    // MARK: Edits and the preview run

    func edited(_ ok: Bool) {
        guard ok else { return }
        onEdited?()
        startPreview()
    }

    func startPreview() {
        previewPhase = 0
        onAnimate?()
    }

    /// Advances the motion preview (1.2 s per run); true while it still needs frames.
    @discardableResult
    public func tick(_ dt: Double) -> Bool {
        guard let p = previewPhase else { return false }
        let next = p + max(0, dt) / 1.2
        previewPhase = next >= 1 ? nil : next
        return previewPhase != nil
    }
}
