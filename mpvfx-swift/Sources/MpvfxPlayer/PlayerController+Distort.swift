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

/// The distort tool: four draggable corners on the selected picture (corner-pin). Like Crop it is a draft until
/// Apply, which commits one undo step (the host writes `StageElement.corners`); Cancel and Esc put the clip back.
///
/// Keys: D opens and closes it; Tab and Shift+Tab pick the corner; the arrow keys move it one canvas pixel (Shift ten);
/// 0 resets the draft to the plain box; Enter applies, Shift+Enter applies and keys the corners at the playhead;
/// Esc cancels. The tool runs inside the crop tool's state (`view.cropActive`), so the toolbar's Reset, Cancel and Apply
/// group and every guard that keeps other edits out of a crop session apply to it as well.
extension PlayerController {
    static let distortKeyStep = 1.0, distortKeyShiftStep = 10.0, distortHandleHit = 12.0

    public func runDistort(_ cmd: PreviewToolbar.CropCommand) {
        switch cmd {
        case .start:
            guard !view.cropActive, view.cropAvailable, let e = selected, !e.locked, !view.playback.isPlaying else { return }
            let start = distortCorners?(e.id) ?? .identity
            distortOriginal = e; distortStart = start; distortKeyframe = false
            view.distortActive = true; view.cropActive = true; view.activeCorner = .topLeft
            update(e.id) { $0.corners = start }
        case .reset:
            guard view.distortActive, let id = distortOriginal?.id else { return }
            update(id) { $0.corners = .identity }
        case .cancel: cancelDistort()
        case .apply: applyDistort(keyframed: false)
        }
    }

    /// The corners being edited, nil when the tool is closed.
    public var distortDraft: NativeClipCorners? {
        guard view.distortActive, let id = distortOriginal?.id else { return nil }
        return view.elements.first { $0.id == id }?.corners
    }

    func applyDistort(keyframed: Bool) {
        guard view.distortActive, let o = distortOriginal, let e = view.elements.first(where: { $0.id == o.id }) else { return }
        view.distortActive = false; view.cropActive = false
        distortKeyframe = keyframed
        // Reset (an all-zero draft) is a change when the clip had corners; keying is a change on its own.
        if (e.corners ?? .identity) != distortStart || keyframed { onCommit?(e) }
        update(o.id) { $0.corners = nil }   // the document's corners show again
        distortOriginal = nil; distortKeyframe = false
        needsDisplay?()
    }

    func cancelDistort() {
        guard view.distortActive else { return }
        if let o = distortOriginal { update(o.id) { $0.corners = nil } }
        view.distortActive = false; view.cropActive = false; distortOriginal = nil
        needsDisplay?()
    }

    /// Where each corner of `ve` (a chrome element, view px) sits with `corners` applied, in the order of `Corner.allCases`.
    static func cornerPoints(_ ve: StageElement, _ corners: NativeClipCorners) -> [(NativeClipCorners.Corner, CanvasPoint)] {
        let r = ve.rect
        let natural: [NativeClipCorners.Corner: CanvasPoint] = [.topLeft: CanvasPoint(r.x, r.y), .topRight: CanvasPoint(r.maxX, r.y),
                                                                 .bottomRight: CanvasPoint(r.maxX, r.maxY), .bottomLeft: CanvasPoint(r.x, r.maxY)]
        return NativeClipCorners.Corner.allCases.map { c in
            let n = natural[c]!, o = corners[c]
            return (c, PlayerView.rotate(CanvasPoint(n.x + o.x * r.width, n.y + o.y * r.height), about: ve.centre, ve.rotation))
        }
    }

    func distortPress(_ p: CanvasPoint) {
        guard let id = distortOriginal?.id, let e = view.elements.first(where: { $0.id == id }) else { return }
        let ve = view.chromeElement(e, in: size)
        let hit = Self.cornerPoints(ve, e.corners ?? .identity)
            .map { ($0.0, hypot($0.1.x - p.x, $0.1.y - p.y)) }.filter { $0.1 <= Self.distortHandleHit }.min { $0.1 < $1.1 }
        guard let corner = hit?.0 else { return }
        view.activeCorner = corner
        gesture = .corner(id: id, corner: corner)
        needsDisplay?()
    }

    func dragCorner(_ id: String, _ corner: NativeClipCorners.Corner, _ p: CanvasPoint) {
        guard let e = view.elements.first(where: { $0.id == id }) else { return }
        let ve = view.chromeElement(e, in: size), lp = local(p, ve), r = ve.rect
        guard r.width > 0, r.height > 0 else { return }
        let nx = corner == .topLeft || corner == .bottomLeft ? r.x : r.maxX
        let ny = corner == .topLeft || corner == .topRight ? r.y : r.maxY
        let m = NativeClipCorners.maxOffset
        update(id) { el in
            var c = el.corners ?? .identity
            c[corner] = .init(x: max(-m, min(m, (lp.x - nx) / r.width)), y: max(-m, min(m, (lp.y - ny) / r.height)))
            el.corners = c
        }
    }

    /// The distort keys; false when the tool is closed and the key is not D.
    func distortKey(_ k: EditorKey) -> Bool {
        guard view.distortActive else {
            guard case .char(let ch) = k.code, ch == "d" || ch == "D", !k.shift, !k.isRepeat, gesture == nil, !view.cropActive,
                  view.cropAvailable else { return false }
            runDistort(.start); return view.distortActive
        }
        guard let id = distortOriginal?.id else { return false }
        let all = NativeClipCorners.Corner.allCases, i = all.firstIndex(of: view.activeCorner) ?? 0
        let step = k.shift ? Self.distortKeyShiftStep : Self.distortKeyStep
        switch k.code {
        case .char(let ch) where (ch == "d" || ch == "D") && !k.shift: cancelDistort(); return true
        case .tab:
            view.activeCorner = all[(i + (k.shift ? all.count - 1 : 1)) % all.count]; needsDisplay?(); return true
        case .enter where k.shift: applyDistort(keyframed: true); return true
        case .char(let ch) where ch == "0": runDistort(.reset); return true
        case .left, .right, .up, .down:
            guard let e = view.elements.first(where: { $0.id == id }), e.rect.width > 0, e.rect.height > 0 else { return true }
            var dx = 0.0, dy = 0.0
            switch k.code { case .left: dx = -step; case .right: dx = step; case .up: dy = -step; default: dy = step }
            let m = NativeClipCorners.maxOffset, corner = view.activeCorner
            update(id) { el in
                var c = el.corners ?? .identity
                let o = c[corner]
                c[corner] = .init(x: max(-m, min(m, o.x + dx / e.rect.width)), y: max(-m, min(m, o.y + dy / e.rect.height)))
                el.corners = c
            }
            return true
        default: return false   // Enter and Esc reach the crop keys, which route to this tool
        }
    }
}
