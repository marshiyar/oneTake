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

extension InspectorPanel {
    var hasUserLookSelection: Bool {
        guard userLookStore != nil, let editor else { return false }
        return editor.document.sequence.tracks.flatMap(\.clips).contains { c in
            selection.contains(c.id) && editor.document.assets.contains { $0.id == c.assetId && ($0.kind == .video || $0.kind == .image) }
        }
    }
    func userLooksGroup(_ editor: TimelineEditor) -> InspectorGroup {
        guard let store = userLookStore else { return .init(id: "looks", title: "Saved looks", summary: "", rows: []) }
        let chosen = store.looks.first { $0.id == selectedUserLook }
        let name = userLookNameDraft ?? chosen?.name ?? "My look"
        var rows: [InspectorRow] = [
            .init(.note("Save this clip’s grade and effects, or apply a saved look to the selected clips.")),
            .init(.number(.init(key: "looks:name", label: "Name", text: name, tier: .explicitCustom,
                commit: { [weak self] in self?.userLookNameDraft = $0 }))),
            .init(.buttons([
                .init(key: "looks:save", label: "Save current", style: .accent, action: { [weak self] in self?.saveUserLook() }, disabled: selection.count != 1),
                .init(key: "looks:rename", label: "Rename", style: .muted, action: { [weak self] in self?.renameUserLook() }, disabled: chosen == nil),
                .init(key: "looks:delete", label: "Delete", style: .danger, action: { [weak self] in self?.deleteUserLook() }, disabled: chosen == nil),
            ])),
        ]
        if store.looks.isEmpty { rows.append(.init(.note("No saved looks. Name this look, then choose Save current."))) }
        for look in store.looks {
            rows.append(.init(.buttons([.init(key: "looks:pick:\(look.id)", label: look.name,
                style: chosen?.id == look.id ? .chipActive : .chip, action: { [weak self] in
                    self?.selectedUserLook = look.id; self?.userLookNameDraft = nil; self?.userLookError = nil
                    self?.onOpenGroupChanged?("looks")
                })])))
        }
        rows.append(.init(.buttons([.init(key: "looks:apply", label: "Apply to selection", style: .accent,
            action: { [weak self] in self?.applySelectedUserLook() }, disabled: chosen == nil)])))
        if let error = userLookError { rows.append(.init(.note(error.localizedDescription))) }
        return .init(id: "looks", title: "Saved looks", summary: "\(store.looks.count)", rows: rows)
    }
    func userLookOperation(_ body: () throws -> Void) {
        do { try body(); userLookError = nil }
        catch let error as UserLookError { userLookError = error }
        catch { userLookError = .writeFailed(error.localizedDescription) }
        onOpenGroupChanged?("looks")
    }
    func saveUserLook() {
        userLookOperation {
            guard let store = userLookStore, let editor, selection.count == 1, let id = selection.first,
                  let effects = editor.effectsForUserLook(clipId: id, time: time, resolveLut: resolveUserLookLut) else { throw UserLookError.noVisualSelection }
            let chosen = store.looks.first { $0.id == selectedUserLook }
            let look = try store.save(name: userLookNameDraft ?? chosen?.name ?? "My look", effects: effects)
            selectedUserLook = look.id; userLookNameDraft = nil
        }
    }
    func renameUserLook() {
        userLookOperation {
            guard let store = userLookStore, let chosen = store.looks.first(where: { $0.id == selectedUserLook }) else { throw UserLookError.missingLook }
            try store.rename(id: chosen.id, name: userLookNameDraft ?? chosen.name); userLookNameDraft = nil
        }
    }
    func deleteUserLook() {
        userLookOperation {
            guard let store = userLookStore, let id = selectedUserLook else { throw UserLookError.missingLook }
            try store.delete(id: id); selectedUserLook = nil; userLookNameDraft = nil
        }
    }
    func applySelectedUserLook() {
        userLookOperation {
            guard let store = userLookStore, let editor, let look = store.looks.first(where: { $0.id == selectedUserLook }) else { throw UserLookError.missingLook }
            if try editor.applyUserLook(look, to: Set(selection), lutExists: userLookLutExists) > 0 { onEdited?() }
        }
    }
}
