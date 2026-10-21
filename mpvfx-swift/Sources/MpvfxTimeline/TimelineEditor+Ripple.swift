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

/// Ripple edits: deletes and trims that pull (or push) the rest of the lane so no hole opens.
/// Each runs as one undo step: the clip commands are applied to a scratch document and the
/// result is committed with a restoreDocument inverse.
public extension TimelineEditor {
    /// Run clip commands against a scratch copy of the document and commit the final state as a
    /// single undoable edit. `body` returns false (or a command fails) to abandon the transaction.
    @discardableResult
    func transaction(_ label: String = "Edit", _ body: (_ step: (NativeProjectClipCommand) -> Bool, _ scratch: () -> NativeProjectDocument) -> Bool) -> Bool {
        var doc = document
        var failed = false
        let step: (NativeProjectClipCommand) -> Bool = { cmd in
            guard !failed else { return false }
            do {
                let r = try applyNativeProjectClipCommand(doc, cmd, engine: self.engine)
                guard case .success(let next, _) = r else { self.lastFailure = r.failure; failed = true; return false }
                doc = next; return true
            } catch {
                self.lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "\(error)"); failed = true; return false
            }
        }
        guard body(step, { doc }), !failed, doc != document else { return false }
        let before = document
        withHistory(label) { replaceDocument(doc, inverse: .restoreDocument(document)) }
        reportTransitionChanges(from: before)
        lastFailure = nil
        return true
    }

    /// Ripple delete: remove the clips, then on each affected lane shift every later clip left by
    /// the length of the holes the delete opened before it (spans still covered by a kept clip on
    /// the same lane are not holes). Clips on other lanes stay put.
    @discardableResult
    func rippleDelete(_ ids: Set<String>) -> Bool {
        let addrs = ids.sorted().compactMap { address(clipId: $0) }
        guard !addrs.isEmpty, !addrs.contains(where: { isTrackLocked($0.trackId) }) else { return false }
        let before = document
        return transaction("Ripple delete") { step, scratch in
            guard step(addrs.count == 1 ? .delete(address: addrs[0]) : .deleteMany(addrs)) else { return false }
            var moves: [NativeProjectClipMove] = []
            for track in before.sequence.tracks {
                let removed = track.clips.filter { ids.contains($0.id) }
                guard !removed.isEmpty, let after = scratch().sequence.tracks.first(where: { $0.id == track.id }) else { continue }
                let holes = Self.subtract(Self.union(removed.map { ($0.startFrame, $0.startFrame + $0.durationFrames) }),
                                          Self.union(after.clips.map { ($0.startFrame, $0.startFrame + $0.durationFrames) }))
                for c in after.clips {
                    let shift = holes.reduce(0.0) { $0 + max(0, min($1.1, c.startFrame) - $1.0) }
                    if shift > 0 {
                        moves.append(.init(address: .init(sequenceId: sequenceId, trackId: track.id, clipId: c.id),
                                           destination: .init(trackId: track.id, startFrame: max(0, c.startFrame - shift))))
                    }
                }
            }
            return moves.isEmpty || step(moves.count == 1 ? .move(address: moves[0].address, destination: moves[0].destination) : .moveMany(moves))
        }
    }

    /// Ripple trim. `.end`: the clip's out-point moves to `frame` and every later clip on the lane
    /// shifts by the same amount. `.start`: the in-point is trimmed by `frame - start` but the clip
    /// keeps its position, and every later clip on the lane shifts by the opposite amount.
    @discardableResult
    func rippleTrim(clipId: String, edge: TrimEdge, toFrame frame: Double) -> Bool {
        guard let a = address(clipId: clipId), !isTrackLocked(a.trackId),
              let track = document.sequence.tracks.first(where: { $0.id == a.trackId }),
              let c = track.clips.first(where: { $0.id == clipId }) else { return false }
        let start = c.startFrame, end = c.startFrame + c.durationFrames
        let delta: Double = edge == .end ? frame - end : -(frame - start)   // change in clip length
        guard delta != 0 else { return false }
        let followers = track.clips.filter { $0.id != clipId && $0.startFrame >= end }
        func shift(_ by: Double) -> NativeProjectClipCommand? {
            let moves = followers.map { f in
                NativeProjectClipMove(address: .init(sequenceId: sequenceId, trackId: a.trackId, clipId: f.id),
                                      destination: .init(trackId: a.trackId, startFrame: f.startFrame + by))
            }
            if moves.isEmpty { return nil }
            return moves.count == 1 ? .move(address: moves[0].address, destination: moves[0].destination) : .moveMany(moves)
        }
        return transaction("Ripple trim") { step, _ in
            switch edge {
            case .end:
                if delta > 0, let s = shift(delta), !step(s) { return false }   // make room first
                guard step(.trimOut(address: a, endFrameExclusive: frame)) else { return false }
                if delta < 0, let s = shift(delta), !step(s) { return false }
                return true
            case .start:
                if delta > 0 {
                    // Extending the head: push the clip and its followers right, then pull the in-point back.
                    if let s = shift(delta), !step(s) { return false }
                    guard step(.move(address: a, destination: .init(trackId: a.trackId, startFrame: start + delta))),
                          step(.trimIn(address: a, startFrame: start)) else { return false }
                    return true
                }
                guard step(.trimIn(address: a, startFrame: frame)),
                      step(.move(address: a, destination: .init(trackId: a.trackId, startFrame: start))) else { return false }
                if let s = shift(delta) { return step(s) }
                return true
            }
        }
    }

    /// Split several clips at one frame as a single undo step. Clips on locked tracks are skipped.
    @discardableResult
    func split(_ ids: [String], atFrame frame: Double) -> Bool {
        let addrs = ids.compactMap { address(clipId: $0) }.filter { !isTrackLocked($0.trackId) }
        if addrs.isEmpty { return false }
        if addrs.count == 1 { return apply(.split(address: addrs[0], splitFrame: frame)) }
        return transaction("Split clips") { step, _ in addrs.allSatisfy { step(.split(address: $0, splitFrame: frame)) } }
    }

    /// Close every gap on every unlocked lane (one undo step).
    @discardableResult
    func closeAllGapsEverywhere() -> Bool {
        let starts = tracks.filter { !isTrackLocked($0.id) }.flatMap { TimelineGaps.compaction($0.clips) }
        return withHistory("Close all gaps") { shift(starts) }
    }

    internal static func union(_ spans: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for s in spans.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, s.0 <= last.1 { out[out.count - 1].1 = max(last.1, s.1) } else { out.append(s) }
        }
        return out
    }

    internal static func subtract(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for s in a {
            var pieces = [s]
            for cut in b {
                pieces = pieces.flatMap { p -> [(Double, Double)] in
                    guard cut.1 > p.0, cut.0 < p.1 else { return [p] }
                    return [(p.0, cut.0), (cut.1, p.1)].filter { $0.1 > $0.0 }
                }
            }
            out += pieces
        }
        return out
    }
}
