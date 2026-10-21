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
// Cut transitions on the timeline editor: each transition edit is one undo step, refused on a locked track, and a
// clip edit that removes or shortens a transition says so through `onNotice`.
import Foundation
import MpvfxShared

public extension TimelineEditor {
    /// Applies a transition edit as one undo step ("Add transition", "Remove transition", …). A refusal (locked
    /// track, too little media for a dissolve, a value the document rejects) sets `lastFailure` and changes nothing.
    @discardableResult
    func applyTransition(_ command: NativeCutTransitionCommand) -> Bool {
        if let trackId = transitionTrackId(command), isTrackLocked(trackId) {
            lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "Track is locked"); return false
        }
        do {
            let r = try applyNativeCutTransitionCommand(document, command, engine: engine)
            guard case .success(let doc, let inverse) = r else { lastFailure = r.failure; return false }
            lastFailure = nil
            withHistory(Self.transitionLabel(command)) { replaceDocument(doc, inverse: inverse) }
            return true
        } catch { lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "\(error)"); return false }
    }

    /// The track a transition command edits (nil when the transition does not exist).
    internal func transitionTrackId(_ command: NativeCutTransitionCommand) -> String? {
        let id: String
        switch command {
        case .add(let trackId, _): return trackId
        case .setLength(let i, _), .setKind(let i, _), .setAlignment(let i, _), .setColor(let i, _), .setDirection(let i, _), .setSoftness(let i, _), .remove(let i): id = i
        }
        return document.sequence.tracks.first { $0.cutTransitions.contains { $0.id == id } }?.id
    }

    internal static func transitionLabel(_ command: NativeCutTransitionCommand) -> String {
        switch command {
        case .add: "Add transition"
        case .remove: "Remove transition"
        case .setLength: "Change transition length"
        case .setKind: "Change transition kind"
        case .setAlignment: "Change transition alignment"
        case .setDirection: "Change transition direction"
        case .setSoftness: "Change transition softness"
        case .setColor: "Change transition colour"
        }
    }

    /// Records (and hands to `onNotice`) what the edit that turned `before` into the current document did to
    /// transitions.
    internal func reportTransitionChanges(from before: NativeProjectDocument) {
        lastNotice = nativeCutTransitionChangeNotice(before: before, after: document)
        if let lastNotice { onNotice?(lastNotice) }
    }
}
