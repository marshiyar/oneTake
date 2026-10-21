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
// Moves through clip edits. Moves are attached to the clip's edges, so a move, trim or retime keeps them in place;
// only the lengths may have to shrink when the clip gets shorter than In + Out. Split gives the In to the left part,
// the Out to the right part and the Loop to both (the rule fades follow). Only `frames` is rewritten, so keys of a
// move this build does not know survive; moves from a newer version are copied unchanged.
import Foundation

public enum NativeSplitPart: Sendable { case left, right }

extension NativeProjectClip {
    /// This clip's moves on the clip once it is `duration` frames long (trim, retime).
    public func movesFitted(toDuration duration: Double) -> NativeClipMoves? { moves?.fitted(toDuration: duration) }
    /// This clip's moves on one part of a split at `duration` frames.
    public func movesForSplitPart(_ part: NativeSplitPart, duration: Double) -> NativeClipMoves? {
        moves?.splitPart(part, duration: duration)
    }
}

extension NativeClipMoves {
    /// The moves of one part of a split clip of `duration` frames: In on the left, Out on the right, Loop on both,
    /// fitted to the part. Nil when the part keeps no move.
    public func splitPart(_ part: NativeSplitPart, duration: Double) -> NativeClipMoves? {
        guard isCurrentVersion else { return self }
        var next = self
        next.remove(part == .left ? .out : .in)
        return next.fitted(toDuration: duration)
    }

    /// The moves on a clip that is now `duration` frames long. When In + Out no longer fit, both shrink in
    /// proportion (rounded down, so they fit) and a move left with no frames is removed. Nil when no move remains.
    public func fitted(toDuration duration: Double) -> NativeClipMoves? {
        guard isCurrentVersion else { return self }
        let inFrames = inMove?.frames ?? 0, outFrames = outMove?.frames ?? 0
        let total = inFrames + outFrames
        guard total > 0, Double(total) > duration else { return isEmpty ? nil : self }
        let d = max(0, Int(duration.rounded(.down)))
        var next = self
        next.setFrames(.in, inFrames * d / total)
        next.setFrames(.out, outFrames * d / total)
        return next.isEmpty ? nil : next
    }

    /// Rewrites one move's `frames` in place; zero removes the move. A slot without a readable move is left alone.
    mutating func setFrames(_ slot: NativeMoveSlot, _ frames: Int) {
        guard slot != .loop, edgeMove(slot == .in ? .in : .out) != nil else { return }
        guard frames > 0 else { return remove(slot) }
        var move = stored[slot.rawValue]
        move?["frames"] = .number(Double(frames))
        stored[slot.rawValue] = move
    }
}
