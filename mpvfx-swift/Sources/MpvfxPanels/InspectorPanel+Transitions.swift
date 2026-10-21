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

extension InspectorPanel {
    /// Select either side of a touching cut to add or edit its transition using ordinary keyboard-capable rows.
    func transitionGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup? {
        guard s.isVisual else { return nil }
        let clips = s.track.clips.sorted { $0.startFrame < $1.startFrame }
        let existing = s.track.cutTransitions.first { $0.fromClipId == s.id } ?? s.track.cutTransitions.first { $0.toClipId == s.id }
        let pair: (NativeProjectClip, NativeProjectClip)?
        if let from = clips.first(where: { $0.id == existing?.fromClipId }), let to = clips.first(where: { $0.id == existing?.toClipId }) { pair = (from, to) }
        else if let next = clips.first(where: { $0.startFrame == s.clip.startFrame + s.clip.durationFrames }) { pair = (s.clip, next) }
        else if let previous = clips.first(where: { $0.startFrame + $0.durationFrames == s.clip.startFrame }) { pair = (previous, s.clip) }
        else { pair = nil }
        guard let (from, to) = pair else { return nil }
        var rows: [InspectorRow] = []
        if let transition = existing {
            guard transition.isKnown, let id = transition.id else {
                return InspectorGroup(id: "transitions", title: "Transition", summary: "Newer transition",
                                      rows: [.init(.note("This transition is preserved from a newer editor and cannot be edited here."))])
            }
            func apply(_ command: NativeCutTransitionCommand) { edited(editor.applyTransition(command), label: "Edit transition") }
            rows.append(.init(.segmented(.init(key: "transition:kind", label: "Kind",
                options: NativeCutTransitionKind.allCases.map { ($0.rawValue, $0.rawValue.capitalized, $0 == transition.kind) },
                select: { value in if let kind = NativeCutTransitionKind(rawValue: value) { apply(.setKind(id: id, kind: kind)) } }))))
            rows.append(.init(.number(.init(key: "transition:duration", label: "Duration (frames)",
                text: PanelFormat.number(transition.durationFrames ?? 1, decimals: 0), tier: .explicitCustom,
                commit: { value in if let length = PanelFormat.parse(value) { apply(.setLength(id: id, durationFrames: length)) } }))))
            if transition.kind == .wipe || transition.kind == .push {
                rows.append(.init(.segmented(.init(key: "transition:direction", label: "Direction",
                    options: NativeTransitionDirection.allCases.map { ($0.rawValue, $0.rawValue.capitalized, $0 == transition.direction) },
                    select: { value in if let direction = NativeTransitionDirection(rawValue: value) { apply(.setDirection(id: id, direction: direction)) } }))))
            }
            if transition.kind == .wipe {
                rows.append(.init(.slider(.init(key: "transition:softness", label: "Softness", position: transition.softness * 100, min: 0, max: 100,
                    display: "\(Int(transition.softness * 100))%", format: { "\(Int($0.rounded()))%" }, tier: .explicitCustom,
                    commit: { apply(.setSoftness(id: id, softness: $0 / 100)) }))))
            }
            if transition.kind == .dip {
                rows.append(.init(.segmented(.init(key: "transition:color", label: "Dip to",
                    options: [("#000000", "Black", (transition.color ?? "#000000") == "#000000"), ("#ffffff", "White", transition.color?.lowercased() == "#ffffff")],
                    select: { apply(.setColor(id: id, color: $0)) }))))
            }
            rows.append(.init(.buttons([.init(key: "transition:remove", label: "Remove transition", style: .muted, action: { apply(.remove(id: id)) })])))
        } else {
            rows.append(.init(.buttons([.init(key: "transition:add", label: "Add transition", style: .accent, action: { [weak self] in
                // A dip requires no extra media; changing kind later validates available handles atomically.
                let transition = NativeCutTransition(id: UUID().uuidString.lowercased(), cut: (from.id, to.id), kind: .dip,
                    durationFrames: min(30, from.durationFrames, to.durationFrames))
                self?.edited(editor.applyTransition(.add(trackId: s.track.id, transition: transition)), label: "Add transition")
            })])))
        }
        if let failure = editor.lastFailure { rows.append(.init(.note(failure.message))) }
        return InspectorGroup(id: "transitions", title: "Transition", summary: existing?.kind?.rawValue.capitalized ?? "Hard cut", rows: rows)
    }
}
