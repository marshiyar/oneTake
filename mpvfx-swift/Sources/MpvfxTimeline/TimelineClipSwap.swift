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

/// Clip swap on drop (a deliberate addition beyond the original, which only ever moves the dragged clip to the
/// nearest free row). Rules:
/// - Only a single dragged clip swaps. A multi-clip selection keeps the rigid-formation move (nothing swaps).
/// - The clip must be aimed at a row other than its own, inside the rows (an explicit boundary or edge drop still
///   opens a new track), and overlap at least one clip there. Every clip it overlaps on that row is displaced
///   together and keeps its time.
/// - The displaced clips go to the dragged clip's origin row when they all fit there with no collision; else to
///   the nearest row where they all fit (above the aimed row first, nearest first, then below); else a new track
///   opens directly below the aimed row.
/// - Locked rows refuse: a locked aimed row never swaps (its clips never move) and a locked row never receives
///   displaced clips. The dragged clip's own row is unlocked, or the drag never starts.
/// - Kinds: the aimed row must accept the dragged clip's kind and the origin row every displaced clip's kind (a
///   row accepts clips of its own kind, a mixed row any). Otherwise nothing swaps and the original placement
///   applies. A fallback row must accept the displaced kinds too; a new track takes their kind.
/// - Holding Option/Alt while dragging turns the swap off (the original placement), live while the drag runs.
/// - The whole swap is one undo step, "Swap clips". Preview and export stack by the new rows.
public extension TimelineEditor {
    internal func clipKind(_ c: NativeProjectClip) -> NativeProjectTrackKind {
        document.assets.first { $0.id == c.assetId }?.kind == .audio ? .audio : .video
    }
    internal static func accepts(_ t: NativeProjectTrack, _ kind: NativeProjectTrackKind) -> Bool { t.kind == .mixed || t.kind == kind }

    /// The swap for one dragged clip landing on `start..<end` of display row `aimedRow`, or nil when the drop is not
    /// a swap (free span, own row, out of the rows, locked or incompatible row) and the original placement applies.
    internal func planSwap(_ base: TimelineMovePlan, clip a: NativeProjectClip, originRow: Int, aimedRow: Int,
                           start: Double, end: Double) -> TimelineMovePlan? {
        let rows = base.rows
        guard aimedRow != originRow, rows.indices.contains(aimedRow), rows.indices.contains(originRow) else { return nil }
        let tracks = Dictionary(document.sequence.tracks.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        guard let aimed = tracks[rows[aimedRow]], let origin = tracks[rows[originRow]], aimed.locked != true else { return nil }
        let hit = aimed.clips.filter { $0.id != a.id && $0.startFrame < end && start < $0.startFrame + $0.durationFrames }
        guard !hit.isEmpty, Self.accepts(aimed, clipKind(a)) else { return nil }
        let kinds = Set(hit.map(clipKind))
        guard kinds.allSatisfy({ Self.accepts(origin, $0) }) else { return nil }
        let leaving = Set(hit.map(\.id) + [a.id])
        func fits(_ row: Int) -> Bool {
            guard row != aimedRow, rows.indices.contains(row), let t = tracks[rows[row]], t.locked != true,
                  kinds.allSatisfy({ Self.accepts(t, $0) }) else { return false }
            return hit.allSatisfy { b in
                !t.clips.contains { !leaving.contains($0.id) && $0.startFrame < b.startFrame + b.durationFrames && b.startFrame < $0.startFrame + $0.durationFrames }
            }
        }
        var plan = base
        plan.target = .row(aimedRow); plan.rowDelta = aimedRow - originRow; plan.valid = true
        plan.displaced = hit.map(\.id)
        plan.displacedTarget = fits(originRow) ? .row(originRow)
            : TimelineTrackDrop.placement(rowCount: rows.count, desiredRow: aimedRow, deliberateInsertRow: nil, preferInsertAbove: false, free: fits)
        return plan
    }

    /// Commit a swap as one undo step: a new track for the displaced clips when nothing else fits, the dragged clip
    /// onto the aimed row, the displaced clips (same times) onto their row, then rows left empty go.
    internal func commitSwap(_ plan: TimelineMovePlan) -> Bool {
        guard plan.valid, plan.clipIds.count == 1, case .row(let aimedRow) = plan.target, let dt = plan.displacedTarget,
              plan.rows.indices.contains(aimedRow), let (aTrack, aClip) = clip(plan.clipIds[0]) else { return false }
        let displaced = plan.displaced.compactMap { id in clip(id).map { (id: id, track: $0.track, clip: $0.clip) } }
        guard displaced.count == plan.displaced.count else { return false }
        let sources = Set([aTrack.id] + displaced.map(\.track.id))
        return transaction("Swap clips") { step, scratch in
            let destination: String
            switch dt {
            case .row(let r):
                guard plan.rows.indices.contains(r) else { return false }
                destination = plan.rows[r]
            case .insert(let boundary):
                var d = scratch()
                let kinds = Set(displaced.map { clipKind($0.clip) })
                let kind: NativeProjectTrackKind = kinds.count == 1 ? kinds.first! : .mixed
                let tid = Self.freshTrackId(d, kind)
                let authored = (d.sequence.tracks.enumerated().map { ($0.element.lane ?? Self.indexLane($0.offset)).authoredTrack }.max() ?? 0) + 1
                d.sequence.tracks.append(NativeProjectTrack(id: tid, kind: kind, lane: .init(authoredTrack: authored, displayTrack: 0), clips: []))
                var order = displayTrackIds
                if boundary < plan.rows.count, let at = order.firstIndex(of: plan.rows[boundary]) { order.insert(tid, at: at) }
                else if let last = plan.rows.last, let at = order.firstIndex(of: last) { order.insert(tid, at: at + 1) }
                else { order.append(tid) }
                Self.renumberDisplay(&d, order)
                guard step(.restoreDocument(d)) else { return false }
                destination = tid
            }
            var moves = [NativeProjectClipMove(address: .init(sequenceId: sequenceId, trackId: aTrack.id, clipId: aClip.id),
                                               destination: .init(trackId: plan.rows[aimedRow], startFrame: aClip.startFrame + plan.deltaFrames))]
            moves += displaced.map { b in
                NativeProjectClipMove(address: .init(sequenceId: sequenceId, trackId: b.track.id, clipId: b.id),
                                      destination: .init(trackId: destination, startFrame: b.clip.startFrame))
            }
            guard step(.moveMany(moves)) else { return false }
            var d = scratch()
            let emptied = Set(d.sequence.tracks.filter { sources.contains($0.id) && $0.clips.isEmpty && $0.locked != true }.map(\.id))
            if emptied.isEmpty { return true }
            let order = d.sequence.tracks.enumerated()
                .sorted { ($0.element.lane?.displayTrack ?? Double($0.offset), $0.offset) < ($1.element.lane?.displayTrack ?? Double($1.offset), $1.offset) }
                .map(\.element.id).filter { !emptied.contains($0) }
            d.sequence.tracks.removeAll { emptied.contains($0.id) }
            Self.renumberDisplay(&d, order)
            return step(.restoreDocument(d))
        }
    }
}
