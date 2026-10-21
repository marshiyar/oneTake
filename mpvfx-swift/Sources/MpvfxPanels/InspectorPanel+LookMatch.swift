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

struct LookMatchUIState {
    var reference: String?
    var pending: LookMatchRequest?
    var message: String?
}

final class LookMatchRequest {
    weak var editor: TimelineEditor?
    let document: NativeProjectDocument
    let target: String, reference: String
    let time: Double, referenceTime: Double
    var targetFrame: CanvasImage?
    init(editor: TimelineEditor, target: String, reference: String, time: Double, referenceTime: Double) {
        self.editor = editor; document = editor.document; self.target = target; self.reference = reference
        self.time = time; self.referenceTime = referenceTime
    }
}

extension InspectorPanel {
    func matchLookCandidates(_ target: String) -> [(id: String, label: String)] {
        guard let editor else { return [] }
        let assets = Dictionary(editor.document.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return editor.document.sequence.tracks.filter { $0.hidden != true }.flatMap(\.clips).compactMap { c in
            guard c.id != target, c.hidden != true, let asset = assets[c.assetId],
                  asset.kind == .video || asset.kind == .image else { return nil }
            return (c.id, asset.name)
        }
    }

    /// The reference is a transient choice; the resulting ordinary grade is the state saved in project.json.
    func matchLookRows(_ target: String) -> [InspectorRow] {
        let candidates = matchLookCandidates(target)
        let chosen = candidates.first { $0.id == lookMatch.reference }
        let referenceRow = InspectorCustomRow(id: "grade:match-reference", height: 30, draw: { [weak self] c, r, panel in
            guard let self else { return }
            self.resumeLookMatch(target)
            PanelDraw.text(c, "Match look", in: CanvasRect(x: r.x, y: r.midY - 8, width: 78, height: 16),
                           font: PanelTheme.font(11), color: PanelTheme.text1)
            let field = CanvasRect(x: r.x + 86, y: r.y + 1, width: max(0, r.width - 86), height: 28)
            PanelSelect.draw(c, field, text: chosen?.label ?? (candidates.isEmpty ? "No other visual clips" : "Choose reference…"),
                             hovered: panel.hovered == .custom("grade:match-reference", 0))
            if !candidates.isEmpty { panel.addHit(field, .custom("grade:match-reference", 0)) }
        }, pointer: { [weak self] _, _, phase in
            guard let self, phase == 0, let anchor = self.hits.rect(where: { $0 == .custom("grade:match-reference", 0) }) else { return }
            self.onOpenDropdown?("match-look-reference", candidates.map { .init(value: $0.id, label: $0.label) },
                                 self.lookMatch.reference ?? "", anchor) { [weak self] id in
                guard let self, self.matchLookCandidates(target).contains(where: { $0.id == id }) else { return }
                self.lookMatch.reference = id; self.lookMatch.pending = nil; self.lookMatch.message = nil
                self.onEdited?()
            }
        })
        var rows: [InspectorRow] = [.init(.spacer(4)), .init(.custom(referenceRow)),
            .init(.buttons([.init(key: "grade:match-look", label: lookMatch.pending == nil ? "Match reference look" : "Matching…", style: .muted,
                action: { [weak self] in self?.startLookMatch(target) }, disabled: chosen == nil || lookMatch.pending != nil)]))]
        if let message = lookMatch.message { rows.append(.init(.note(message))) }
        return rows
    }

    func cancelLookMatch() { lookMatch.pending = nil; lookMatch.message = nil }

    func validateLookMatchContext() {
        guard let request = lookMatch.pending else { return }
        guard let editor, request.editor === editor, editor.document == request.document,
              selection == [request.target], time == request.time, lookMatch.reference == request.reference else {
            cancelLookMatch(); return
        }
    }

    func startLookMatch(_ target: String) {
        guard let editor, selection == [target], !editor.isClipLocked(target),
              let reference = lookMatch.reference, matchLookCandidates(target).contains(where: { $0.id == reference }),
              let clip = editor.clip(reference)?.clip else { return }
        let fps = Double(editor.document.frameRate.numerator) / Double(editor.document.frameRate.denominator)
        let referenceTime = (clip.startFrame + max(0, clip.durationFrames - 1) / 2) / fps
        lookMatch.pending = LookMatchRequest(editor: editor, target: target, reference: reference, time: time, referenceTime: referenceTime)
        lookMatch.message = nil
        resumeLookMatch(target)
        onEdited?()
    }

    /// Capture source first, reference second. A context change cancels before any frame request or edit; both
    /// captured pictures belong to the same immutable document state even when rendering takes multiple redraws.
    func resumeLookMatch(_ target: String) {
        guard let request = lookMatch.pending else { return }
        guard let editor, request.editor === editor, editor.document == request.document,
              selection == [request.target], target == request.target, time == request.time,
              lookMatch.reference == request.reference else {
            lookMatch.pending = nil; lookMatch.message = nil; return
        }
        guard let frame = matchLookFrame else { failLookMatch("No preview renderer available"); return }
        if request.targetFrame == nil {
            switch frame(request.target, request.time, Self.sampleFrameSize, Self.sampleFrameSize) {
            case .rendering: return
            case .ready(let image): request.targetFrame = image
            case .unavailable, .failed: failLookMatch("The selected clip has no frame to measure"); return
            }
        }
        switch frame(request.reference, request.referenceTime, Self.sampleFrameSize, Self.sampleFrameSize) {
        case .rendering: return
        case .unavailable, .failed: failLookMatch("The reference clip has no frame to measure")
        case .ready(let reference):
            guard let source = request.targetFrame else { return }
            let shown = editor.gradeShown(clipId: request.target, time: request.time)
            guard let next = LookMatch.matched(shown, source: source, reference: reference) else {
                failLookMatch("Use enabled, non-empty clip grades to match a look"); return
            }
            lookMatch.pending = nil; lookMatch.message = "Matched; Exposure, Contrast and Offset remain editable"
            if next != shown { edited(editor.commitGrade(clipId: request.target, time: request.time, shown: shown, next: next)) }
            else { onEdited?() }
        }
    }

    private func failLookMatch(_ message: String) { lookMatch.pending = nil; lookMatch.message = message; onEdited?() }
}
