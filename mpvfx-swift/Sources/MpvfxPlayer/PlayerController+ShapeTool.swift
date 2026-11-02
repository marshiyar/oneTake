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
// The Shape tool on the stage (issue #324). ⇧S turns it on with the kind drawn last (rectangle at first) and off again,
// while the stage has the keys; the keys 1 to 4 or a click on a chip of the picker choose rectangle, ellipse, line or
// arrow, and Esc cancels a drag, then turns the tool off. A drag inside the composition frame draws the shape (Shift
// and Option as StageShapeDraft says), a click makes the default size; letting go adds it at the playhead through
// `onCreateShape` and selects it, and the tool goes off.
import Foundation
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline

extension PlayerController {
    /// Turns the tool on with `kind`, or off with nil. A shape being dragged is dropped.
    public func setShapeTool(_ kind: String?) {
        if let kind { lastShapeKind = kind }
        view.shapeTool = kind
        view.shapeDraft = nil
        if case .shape? = gesture { gesture = nil }
        needsDisplay?()
    }

    /// The tool's keys; nil when the key is not the tool's. Without a host to add shapes (`onCreateShape`) the tool is off.
    func shapeToolKey(_ k: EditorKey) -> Bool? {
        guard onCreateShape != nil, !view.cropActive, recorder == nil else { return nil }
        if case .char(let ch) = k.code, k.shift, ch == "s" || ch == "S" {
            if !k.isRepeat { setShapeTool(view.shapeTool == nil ? lastShapeKind : nil) }
            return true
        }
        guard view.shapeTool != nil else { return nil }
        switch k.code {
        case .escape:
            if case .shape? = gesture { gesture = nil; view.shapeDraft = nil; needsDisplay?() } else { setShapeTool(nil) }
            return true
        case .char(let ch):
            guard !k.shift, let n = Int(String(ch)), StageShapeDraft.kinds.indices.contains(n - 1) else { return nil }
            setShapeTool(StageShapeDraft.kinds[n - 1])
            return true
        default: return nil
        }
    }

    /// A press while the tool is on: a chip chooses the kind, a press inside the frame starts the drag.
    func shapePress(_ p: CanvasPoint, viewport: CanvasRect) -> Bool {
        if let kind = StageShapePicker.kind(at: p, in: viewport) { setShapeTool(kind); return true }
        guard view.frameRect(in: size).contains(p) else { return false }
        gesture = .shape(from: p)
        view.shapeDraft = nil
        needsDisplay?()
        return true
    }

    private func compositionPoint(_ p: CanvasPoint) -> CanvasPoint {
        let frame = view.frameRect(in: size), s = max(view.scale(in: size), 1e-9)
        return CanvasPoint((p.x - frame.x) / s, (p.y - frame.y) / s)
    }

    private func draft(from start: CanvasPoint, to p: CanvasPoint, kind: String) -> StageShapeDraft {
        StageShapeDraft.make(kind: kind, from: compositionPoint(start), to: compositionPoint(p), shift: shiftHeld,
                             alt: modifiers.contains(.alt), click: hypot(p.x - start.x, p.y - start.y) < Self.dragThreshold)
    }

    /// The drag moved: show the shape it would make (nothing until it passes the click threshold).
    func updateShapeDraft(_ p: CanvasPoint) {
        guard case .shape(let start)? = gesture, let kind = view.shapeTool else { return }
        view.shapeDraft = hypot(p.x - start.x, p.y - start.y) < Self.dragThreshold ? nil : draft(from: start, to: p, kind: kind)
        needsDisplay?()
    }

    /// The press ended: add the shape at the playhead, select it and turn the tool off.
    func finishShape(at p: CanvasPoint) {
        guard case .shape(let start)? = gesture, let kind = view.shapeTool else { return }
        let made = draft(from: start, to: p, kind: kind)
        view.shapeDraft = nil
        defer { needsDisplay?() }
        guard let id = onCreateShape?(made, view.playback.currentTime) else { return }
        setShapeTool(nil)
        if view.elements.contains(where: { $0.id == id }) { setSelection([id]) } else {
            view.selectedIds = [id]; onSelect?(id); onSelectionChange?([id])
        }
    }
}
