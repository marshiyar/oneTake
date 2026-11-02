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
// The Moves group (issue #274), after Transform: an In, an Out and a Loop, each with a kind select ("None" removes it),
// its length, a direction for a Slide, the amount, and the ease as presets. Every pick and value is one undo step through
// TimelineEditor.setEdgeMove / setLoopMove, saved in project.json as `clip.moves`; an amount, direction or ease left at
// its default is not stored, and its reset removes the key. Every row and button is a focusable control, so Tab, the
// arrows and Return reach all of them.
import Foundation
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline

extension InspectorPanel {
    static let movesGroupId = "moves"

    /// The slots of the group, in order.
    enum MoveRowSlot: String, CaseIterable {
        case `in`, out, loop
        var label: String { self == .in ? "In" : self == .out ? "Out" : "Loop" }
    }

    static func moveKindLabel(_ raw: String) -> String { raw.prefix(1).uppercased() + raw.dropFirst() }

    /// The kinds a slot offers on `clip`: Draw only as an In, and only on a shape clip.
    static func moveKinds(_ slot: MoveRowSlot, clip: NativeProjectClip) -> [String] {
        switch slot {
        case .loop: return NativeLoopMoveKind.allCases.map(\.rawValue)
        case .in, .out:
            return NativeEdgeMoveKind.allCases.map(\.rawValue).filter { $0 != "draw" || (slot == .in && clip.shape != nil) }
        }
    }

    static func moveAmountLabel(_ kind: String) -> String {
        switch kind {
        case "slide": "Distance (% of frame)"
        case "rise", "drop", "float": "Distance (% of height)"
        case "grow", "shrink", "pulse": "Scale (%)"
        case "spin", "sway": "Angle (degrees)"
        default: "Amount (%)"
        }
    }

    /// The ease presets, with the ease each stands for.
    static let moveEasePresets: [(key: String, label: String, ease: NativeInterpolation)] = [
        ("ease-out", "Ease out", NativeMoveEase.easeOut), ("ease-in", "Ease in", NativeMoveEase.easeIn),
        ("ease-in-out", "Ease in-out", NativeMoveEase.easeInOut), ("linear", "Linear", .linear),
    ]

    /// A length typed as frames ("15", "15f"), seconds ("0.5s") or timecode ("1:05" is 1 s 5 f, "0:1:05" is 1 min 1 s 5 f)
    /// at `fps`; nil when it is not one of those or is shorter than a frame.
    public static func parseMoveFrames(_ text: String, fps: Double) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, fps > 0 else { return nil }
        let rate = Int(fps.rounded())
        var frames: Double?
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.allSatisfy({ $0 != nil && $0! >= 0 }), (2...3).contains(parts.count) else { return nil }
            let n = parts.compactMap { $0 }
            frames = n.count == 2 ? Double(n[0] * rate + n[1]) : Double(n[0] * 60 * rate + n[1] * rate + n[2])
        } else if t.hasSuffix("s"), let seconds = Double(t.dropLast()) {
            frames = (seconds * fps).rounded()
        } else {
            let plain = t.hasSuffix("f") ? String(t.dropLast()) : t
            guard let n = Double(plain), n == n.rounded() else { return nil }
            frames = n
        }
        guard let frames, frames.isFinite, frames >= 1, frames <= 1_000_000 else { return nil }
        return Int(frames)
    }

    func movesGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup? {
        guard s.isVisual else { return nil }
        if let stored = s.clip.moves, !stored.isCurrentVersion {
            return InspectorGroup(id: Self.movesGroupId, title: "Moves", summary: "Newer version",
                                  rows: [.init(.note("These moves are from a newer version of the editor: they are kept in the project but not drawn."))])
        }
        var rows: [InspectorRow] = []
        for slot in MoveRowSlot.allCases { rows += moveRows(editor, s, slot) }
        if let failure = editor.lastFailure, failure.message.contains("move") { rows.append(.init(.note(failure.message))) }
        let moves = s.clip.moves
        var parts: [String] = []
        if let m = moves?.inMove { parts.append("In \(Self.moveKindLabel(m.kind.rawValue))") }
        if let m = moves?.outMove { parts.append("Out \(Self.moveKindLabel(m.kind.rawValue))") }
        if let m = moves?.loop { parts.append(Self.moveKindLabel(m.kind.rawValue)) }
        return InspectorGroup(id: Self.movesGroupId, title: "Moves", summary: parts.isEmpty ? "none" : parts.joined(separator: " · "), rows: rows)
    }

    /// The rows of one slot: the kind select, then, once there is a move, its length, direction, amount and ease.
    private func moveRows(_ editor: TimelineEditor, _ s: Selected, _ slot: MoveRowSlot) -> [InspectorRow] {
        let id = s.id, moves = s.clip.moves
        let key = "moves.\(slot.rawValue)"
        let kind: String? = slot == .loop ? moves?.loop?.kind.rawValue : moves?.edgeMove(slot == .in ? .in : .out)?.kind.rawValue
        var rows: [InspectorRow] = [InspectorRow(.custom(moveKindRow(editor, s, slot, kind: kind)), controls: [
            InspectorRow(.buttons(moveKindButtons(editor, s, slot, kind: kind)))])]
        guard let kind else { return rows }
        let fps = editor.fps
        func write(_ change: (inout NativeEdgeMove) -> Void, loop: (inout NativeLoopMove) -> Void) {
            if slot == .loop {
                guard var m = editor.clipMoves(clipId: id)?.loop else { return }
                loop(&m)
                edited(editor.setLoopMove(clipIds: [id], m), label: "Edit moves")
            } else {
                let edge: NativeMoveEdge = slot == .in ? .in : .out
                guard var m = editor.clipMoves(clipId: id)?.edgeMove(edge) else { return }
                change(&m)
                edited(editor.setEdgeMove(clipIds: [id], edge, m), label: "Edit moves")
            }
        }
        let edgeMove = slot == .loop ? nil : moves?.edgeMove(slot == .in ? .in : .out)
        let loopMove = slot == .loop ? moves?.loop : nil
        // Length.
        let frames = edgeMove?.frames ?? loopMove?.periodFrames ?? 1
        rows.append(.init(.number(.init(key: "\(key).frames", label: slot == .loop ? "Period (frames)" : "Length (frames)",
            text: PanelFormat.number(Double(frames), decimals: 0), tier: .explicitCustom,
            commit: { text in
                guard let n = Self.parseMoveFrames(text, fps: fps) else { return }
                write({ $0.frames = n }, loop: { $0.periodFrames = n })
            }))))
        // Direction (Slide).
        if let move = edgeMove, move.kind.takesDirection {
            rows.append(.init(.segmented(.init(key: "\(key).direction", label: "Direction",
                options: NativeMoveDirection.allCases.map { ($0.rawValue, Self.moveKindLabel($0.rawValue), $0 == move.resolvedDirection) },
                select: { value in
                    guard let d = NativeMoveDirection(rawValue: value) else { return }
                    write({ $0.direction = d == .left ? nil : d }, loop: { _ in })
                }))))
        }
        // Amount.
        let amount: Double?, resolved: Double?
        if let move = edgeMove { amount = move.amount; resolved = kind == "draw" ? nil : move.resolvedAmount }
        else { amount = loopMove?.amount; resolved = loopMove?.resolvedAmount }
        if let resolved {
            rows.append(.init(.number(.init(key: "\(key).amount", label: Self.moveAmountLabel(kind), text: PanelFormat.number(resolved),
                tier: amount == nil ? .default : .explicitCustom,
                commit: { text in
                    guard let v = PanelFormat.parse(text), v.isFinite else { return }
                    write({ $0.amount = v }, loop: { $0.amount = v })
                },
                reset: amount == nil ? nil : { write({ $0.amount = nil }, loop: { $0.amount = nil }) }))))
        }
        // Ease.
        let ease = edgeMove?.resolvedEase(slot == .in ? .in : .out) ?? loopMove?.resolvedEase
        rows.append(.init(.segmented(.init(key: "\(key).ease", label: "Ease",
            options: Self.moveEasePresets.map { ($0.key, $0.label, $0.ease == ease) },
            select: { value in
                guard let preset = Self.moveEasePresets.first(where: { $0.key == value }) else { return }
                write({ $0.ease = preset.ease }, loop: { $0.ease = preset.ease })
            }))))
        return rows
    }

    /// The pick of a kind, as buttons keyed `moves.in.kind.slide` ... and `moves.in.kind.none`, for the keyboard and for tests.
    private func moveKindButtons(_ editor: TimelineEditor, _ s: Selected, _ slot: MoveRowSlot, kind: String?) -> [InspectorRow.Button] {
        (["none"] + Self.moveKinds(slot, clip: s.clip)).map { value in
            InspectorRow.Button(key: "moves.\(slot.rawValue).kind.\(value)", label: Self.moveKindLabel(value),
                                style: value == (kind ?? "none") ? .chipActive : .chip,
                                action: { [weak self] in self?.pickMoveKind(editor, s, slot, value) })
        }
    }

    func pickMoveKind(_ editor: TimelineEditor, _ s: Selected, _ slot: MoveRowSlot, _ value: String) {
        let id = s.id, moves = s.clip.moves
        let length = max(1, min(15, Int(s.clip.durationFrames) / 3))
        if slot == .loop {
            let previous = moves?.loop
            let next: NativeLoopMove? = value == "none" ? nil : NativeLoopMoveKind(rawValue: value).map {
                NativeLoopMove(kind: $0, periodFrames: previous?.periodFrames ?? 30, amount: nil, ease: previous?.ease)
            }
            guard next != previous else { return }
            edited(editor.setLoopMove(clipIds: [id], next), label: "Edit moves")
        } else {
            let edge: NativeMoveEdge = slot == .in ? .in : .out
            let previous = moves?.edgeMove(edge)
            var next: NativeEdgeMove?
            if value != "none", let k = NativeEdgeMoveKind(rawValue: value) {
                next = NativeEdgeMove(kind: k, frames: previous?.frames ?? length)
                next?.ease = previous?.ease
            }
            guard next != previous else { return }
            edited(editor.setEdgeMove(clipIds: [id], edge, next), label: "Edit moves")
        }
    }

    /// "In" and the kind select (PanelSelect, as the Media group's Fit draws it) and the reset to None (part 1).
    private func moveKindRow(_ editor: TimelineEditor, _ s: Selected, _ slot: MoveRowSlot, kind: String?) -> InspectorCustomRow {
        let rowId = "moves.\(slot.rawValue)"
        return InspectorCustomRow(id: rowId, height: 30, draw: { c, r, panel in
            panel.drawMoveKind(c, r, rowId: rowId, label: slot.label, kind: kind)
        }, pointer: { [weak self] part, _, phase in
            guard phase == 0, let self else { return }
            if part == 1 { self.pickMoveKind(editor, s, slot, "none") } else { self.openMoveKindDropdown(editor, s, slot, rowId: rowId, kind: kind) }
        })
    }

    func drawMoveKind(_ c: CanvasContext, _ r: CanvasRect, rowId: String, label: String, kind: String?) {
        let tier: PropertyValueTier = kind == nil ? .default : .explicitCustom
        PanelDraw.text(c, label, in: CanvasRect(x: r.x, y: r.midY - 8.25, width: 86, height: 16.5),
                       font: PanelTheme.font(11), color: tier.labelColor)
        let right = Self.valueEdge(r)
        if kind != nil {
            let reset = CanvasRect(x: right + PanelGrid.itemGap + (PanelGrid.minTarget - 11) / 2, y: r.midY - 5.5, width: 11, height: 11)
            let hot = hovered == .custom(rowId, 1)
            PanelIcon.reset.draw(c, in: reset, color: hot ? PanelTheme.text1 : PanelTheme.inspectorText)
            addHit(CanvasRect(x: right + PanelGrid.itemGap, y: r.midY - PanelGrid.minTarget / 2,
                              width: PanelGrid.minTarget, height: PanelGrid.minTarget), .custom(rowId, 1))
        }
        let field = CanvasRect(x: r.x + 96, y: r.midY - 14, width: max(0, right - r.x - 96), height: 28)
        PanelSelect.draw(c, field, text: kind.map(Self.moveKindLabel) ?? "None", hovered: hovered == .custom(rowId, 0))
        addHit(field, .custom(rowId, 0))
    }

    func openMoveKindDropdown(_ editor: TimelineEditor, _ s: Selected, _ slot: MoveRowSlot, rowId: String, kind: String?) {
        guard let anchor = hits.rect(where: { $0 == .custom(rowId, 0) }) else { return }
        let options = (["none"] + Self.moveKinds(slot, clip: s.clip)).map { PanelDropdown.Option(value: $0, label: Self.moveKindLabel($0)) }
        onOpenDropdown?("moves-\(slot.rawValue)", options, kind ?? "none", anchor) { [weak self] value in
            self?.pickMoveKind(editor, s, slot, value)
        }
    }
}
