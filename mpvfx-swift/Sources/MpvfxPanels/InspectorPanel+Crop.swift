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

/// A step of the crop session, the same four the stage toolbar offers.
public enum InspectorCropCommand: Equatable, Sendable { case start, reset, cancel, apply }

/// The stage's crop tool, linked by the host: the Media group's "Edit crop" and its edge fields drive that one
/// session, so the inspector and the stage toolbar never run two crops at once. Without a link (a standalone
/// inspector) the group runs its own session on the document.
public struct InspectorCropLink {
    /// The clip the session is cropping, nil when none is open.
    public var activeClip: () -> String?
    /// The session's draft insets (nothing is written to the document before Apply).
    public var insets: () -> NativeClipCrop?
    public var run: (InspectorCropCommand) -> Void
    public var setInsets: (NativeClipCrop) -> Void
    public init(activeClip: @escaping () -> String?, insets: @escaping () -> NativeClipCrop?,
                run: @escaping (InspectorCropCommand) -> Void, setInsets: @escaping (NativeClipCrop) -> Void) {
        self.activeClip = activeClip; self.insets = insets; self.run = run; self.setInsets = setInsets
    }
}

extension InspectorPanel {
    /// The clip under crop: the linked stage session's, else the inspector's own.
    var cropSessionClip: String? { cropLink.map { $0.activeClip() } ?? cropActive }

    func runCrop(_ cmd: InspectorCropCommand, _ editor: TimelineEditor, _ s: Selected) {
        if let link = cropLink { link.run(cmd); onEdited?(); return }
        switch cmd {
        case .start: cropActive = s.id; cropLinkAll = false; onEdited?()
        case .reset: edited(editor.setCrop(clipId: s.id, nil))
        case .cancel:
            if let before = cropBefore { _ = editor.setCrop(clipId: s.id, before) }
            cropActive = nil; onEdited?()
        case .apply: cropActive = nil; cropBefore = nil; onEdited?()
        }
    }

    /// One entry point (issue #188): "Edit crop", a standard button that starts the same session as the stage
    /// toolbar's Crop; while it runs, Reset / Cancel / Apply and the edge fields.
    func cropRows(_ editor: TimelineEditor, _ s: Selected) -> [InspectorRow] {
        guard cropSessionClip == s.id else {
            return [.init(.buttons([.init(key: "crop:start", label: "Edit crop", style: .chip) { [weak self] in
                self?.runCrop(.start, editor, s)
            }]))]
        }
        let rows: [InspectorRow] = [.init(.subheader("Crop", buttons: [
            .init(key: "crop:reset", label: "↺", style: .muted) { [weak self] in self?.runCrop(.reset, editor, s) },
            .init(key: "crop:cancel", label: "Cancel", style: .muted) { [weak self] in self?.runCrop(.cancel, editor, s) },
            .init(key: "crop:apply", label: "Apply", style: .accent) { [weak self] in self?.runCrop(.apply, editor, s) },
        ])), .init(.segmented(.init(key: "crop:links", label: "Link edges",
                                    options: [(key: "all", label: "All", active: cropLinkAll), (key: "sides", label: "Sides", active: !cropLinkAll)],
                                    select: { [weak self] k in self?.cropLinkAll = k == "all"; self?.onEdited?() })))]
        return rows + [cropEdgeRow(editor, s)]
    }

    private func cropEdgeRow(_ editor: TimelineEditor, _ s: Selected) -> InspectorRow {
        let crop = cropLink?.insets() ?? editor.crop(clipId: s.id) ?? NativeClipCrop()
        let set: (String, Double) -> Bool = { [weak self] edge, v in self?.setCropEdge(edge, v, editor, s) ?? false }
        if cropLinkAll {
            return .init(.quad([numberRow(key: "crop:all", label: "All", value: crop.top, decimals: 0, suffix: "px",
                                          tier: crop.isZero ? .default : .explicitCustom, step: 1, apply: { set("top", $0) })]))
        }
        return .init(.quad([("top", "T", crop.top), ("right", "R", crop.right), ("bottom", "B", crop.bottom), ("left", "L", crop.left)].map { e in
            numberRow(key: "crop:\(e.0)", label: e.1, value: e.2, decimals: 0, suffix: "", tier: e.2 == 0 ? .default : .explicitCustom,
                      step: 1, apply: { set(e.0, $0) })
        }))
    }

    /// Writes one edge (or all four when linked): to the linked session's draft, else to the document.
    private func setCropEdge(_ edge: String, _ v: Double, _ editor: TimelineEditor, _ s: Selected) -> Bool {
        var c = cropLink?.insets() ?? editor.crop(clipId: s.id) ?? NativeClipCrop()
        let px = v.isFinite ? max(0, v) : 0
        if cropLinkAll { c = NativeClipCrop(top: px, right: px, bottom: px, left: px) } else {
            switch edge { case "top": c.top = px; case "right": c.right = px; case "bottom": c.bottom = px; default: c.left = px }
        }
        guard let link = cropLink else { return editor.setCrop(clipId: s.id, c) }
        link.setInsets(c)
        return false   // a draft: nothing reaches the document or the undo history before Apply
    }
}
