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
// Edits to a clip's In, Out and Loop moves (issue #274): the setters behind the inspector's Moves group, the timeline's
// wedges and the clip menu's Copy / Paste / Remove moves. Each call is one undo step however many clips it reaches, skips
// clips on locked tracks and clips whose moves come from a newer version (kept as they are), and is refused, with nothing
// recorded, when the document would not take the result (In and Out longer than the clip, a Draw on a clip without a shape).
import Foundation
import MpvfxShared

public extension TimelineEditor {
    /// The clip's moves as stored (nil when it has none).
    func clipMoves(clipId: String) -> NativeClipMoves? { clip(clipId)?.clip.moves }

    /// Sets the In or Out of every listed clip (nil removes it).
    @discardableResult
    func setEdgeMove(clipIds: Set<String>, _ edge: NativeMoveEdge, _ move: NativeEdgeMove?) -> Bool {
        editMoves(clipIds, label: move == nil ? "Remove move" : "Set move") { moves, _ in
            if edge == .in { moves.inMove = move } else { moves.outMove = move }
        }
    }

    /// Sets the Loop of every listed clip (nil removes it).
    @discardableResult
    func setLoopMove(clipIds: Set<String>, _ move: NativeLoopMove?) -> Bool {
        editMoves(clipIds, label: move == nil ? "Remove move" : "Set move") { moves, _ in moves.loop = move }
    }

    /// Replaces the moves of every listed clip with `moves` (nil removes them all), fitted to each clip's length; a Draw
    /// is left out on a clip without a shape. One undo step ("Paste moves" or "Remove moves").
    @discardableResult
    func setClipMoves(clipIds: Set<String>, _ moves: NativeClipMoves?) -> Bool {
        editMoves(clipIds, label: moves == nil ? "Remove moves" : "Paste moves") { current, clip in
            guard let moves, moves.isReadable else { current = NativeClipMoves(); return }
            var next = moves.fitted(toDuration: clip.durationFrames) ?? NativeClipMoves()
            if next.inMove?.kind.rawValue == "draw", clip.shape == nil { next.remove(.in) }
            current = next
        }
    }

    /// A copy of the clip's moves for the clipboard; nil when it has none or they are from a newer version.
    func copyMoves(clipId: String) -> NativeClipMoves? {
        guard let moves = clipMoves(clipId: clipId), !moves.isEmpty, moves.isReadable else { return nil }
        return moves
    }

    private func editMoves(_ ids: Set<String>, label: String, _ body: (inout NativeClipMoves, NativeProjectClip) -> Void) -> Bool {
        var d = document
        var changed = false
        for t in d.sequence.tracks.indices where d.sequence.tracks[t].locked != true {
            for i in d.sequence.tracks[t].clips.indices where ids.contains(d.sequence.tracks[t].clips[i].id) {
                let clip = d.sequence.tracks[t].clips[i]
                if let existing = clip.moves, !existing.isCurrentVersion { continue }
                var moves = clip.moves ?? NativeClipMoves()
                body(&moves, clip)
                let next: NativeClipMoves? = moves.isEmpty ? nil : moves
                guard next != clip.moves else { continue }
                d.sequence.tracks[t].clips[i].moves = next
                changed = true
            }
        }
        return changed && commitPresets(d, label: label)
    }
}
