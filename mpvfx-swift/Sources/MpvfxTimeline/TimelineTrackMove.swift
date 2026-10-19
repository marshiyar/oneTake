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
import MpvfxCanvas
import MpvfxTheme

/// Where a clip drag lands: an existing display row, or a new track inserted at a row boundary
/// (0 = above the top row, `rows.count` = below the bottom row). Rows are the timeline's visible
/// display rows (`TimelineView.tracks`).
public enum TimelineDropTarget: Equatable, Sendable {
    case row(Int)
    case insert(Int)
}

/// A resolved clip drag: which clips move, by how many frames, and where they land.
/// Single clip: `target` is the landing row or insert boundary (resolveZoneDropPlacement).
/// Several clips: the whole formation shifts by `rowDelta` rows (rigid group move); an invalid
/// formation (locked member, missing row, collision) moves nothing.
public struct TimelineMovePlan: Equatable, Sendable {
    public var clipIds: [String]
    public var deltaFrames: Double
    /// Track ids of the display rows the plan was resolved against.
    public var rows: [String]
    public var target: TimelineDropTarget
    public var rowDelta: Int
    public var valid: Bool
    /// Swap (a deliberate addition beyond the original): the clips on the aimed row that the single dragged clip
    /// displaces, each keeping its time, and where they go: the dragged clip's origin row when they fit there,
    /// else the nearest free row (above first, then below), else a new track below the aimed row.
    public var displaced: [String] = []
    public var displacedTarget: TimelineDropTarget? = nil
    public var isSwap: Bool { !displaced.isEmpty }
}

/// Pure drop geometry and placement rules (timeline collision).
public enum TimelineTrackDrop {
    /// resolveInsertRow: a pointer above the top row, below the bottom row, or within `band` (fraction of the
    /// row height) of a row boundary asks for a new track at that boundary; elsewhere nil (a normal lane target).
    public static func insertRow(rowFloat: Double, rowCount: Int, band: Double) -> Int? {
        if rowCount == 0 { return 0 }
        if rowFloat <= 0 { return 0 }
        if rowFloat >= Double(rowCount) { return rowCount }
        let lane = rowFloat.rounded(.down)
        let frac = rowFloat - lane
        if frac < band { return Int(lane) }
        if frac > 1 - band { return Int(lane) + 1 }
        return nil
    }

    /// resolveTimelineMove's row: origin row plus the rounded row travel (Math.round), clamped to the rows.
    public static func desiredRow(originRow: Int, originRowFloat: Double, rowFloat: Double, rowCount: Int) -> Int {
        let delta = Int((rowFloat - originRowFloat + 0.5).rounded(.down))
        return max(0, min(rowCount - 1, originRow + delta))
    }

    /// resolvePlacement + resolveZoneDropPlacement: an explicit boundary drop inserts; else the aimed row when
    /// free, else the nearest free row above (nearest first), then below; when every row is taken a new track
    /// opens on the side of the aimed row the pointer is nearer. `free(row)` answers for the dragged span.
    public static func placement(rowCount: Int, desiredRow: Int, deliberateInsertRow: Int?, preferInsertAbove: Bool,
                                 free: (Int) -> Bool) -> TimelineDropTarget {
        if let ins = deliberateInsertRow { return .insert(ins) }
        guard (0..<rowCount).contains(desiredRow) else { return .insert(preferInsertAbove ? 0 : rowCount) }
        if free(desiredRow) { return .row(desiredRow) }
        for up in stride(from: desiredRow - 1, through: 0, by: -1) where free(up) { return .row(up) }
        for down in (desiredRow + 1)..<max(desiredRow + 1, rowCount) where free(down) { return .row(down) }
        return .insert(max(0, min(rowCount, desiredRow + (preferInsertAbove ? 0 : 1))))
    }
}

public extension TimelineEditor {
    /// Resolve a clip drag against the document. `rows` are the display rows' track ids, `grabbedId` the clip
    /// under the pointer, `desiredRow` the row the pointer aims at, `insertRow` an explicit boundary drop.
    /// Clips on a row never overlap: a locked track is never a destination and a locked clip never moves.
    /// `swap`: a single clip dropped onto a busy row trades places with what it overlaps (`planSwap`); false keeps the
    /// original placement (the held Option/Alt key while dragging).
    func planMove(clipIds: [String], grabbed grabbedId: String, deltaFrames rawDelta: Double, rows: [String], desiredRow: Int,
                  insertRow: Int?, preferInsertAbove: Bool, swap: Bool = false) -> TimelineMovePlan {
        let ids = Set(clipIds)
        let located: [(clip: NativeProjectClip, row: Int?, locked: Bool)] = clipIds.compactMap { id in
            guard let (t, c) = clip(id) else { return nil }
            return (c, rows.firstIndex(of: t.id), t.locked == true)
        }
        // clampGroupMoveDelta: the formation stops when any member would cross 0.
        let minStart = located.map(\.clip.startFrame).min() ?? 0
        let delta = max(rawDelta, -minStart)
        let originRow = clip(grabbedId).flatMap { rows.firstIndex(of: $0.track.id) } ?? 0
        var plan = TimelineMovePlan(clipIds: clipIds, deltaFrames: delta, rows: rows, target: .row(originRow), rowDelta: 0, valid: false)
        guard located.count == clipIds.count, !clipIds.isEmpty, !located.contains(where: { $0.locked || $0.row == nil }) else { return plan }
        let tracks = Dictionary(document.sequence.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func free(_ row: Int, _ start: Double, _ end: Double) -> Bool {
            guard rows.indices.contains(row), let t = tracks[rows[row]], t.locked != true else { return false }
            return !t.clips.contains { !ids.contains($0.id) && $0.startFrame < end && start < $0.startFrame + $0.durationFrames }
        }
        if located.count == 1 {
            let c = located[0].clip
            let s = c.startFrame + delta, e = s + c.durationFrames
            if swap, insertRow == nil, let swapped = planSwap(plan, clip: c, originRow: located[0].row!, aimedRow: desiredRow, start: s, end: e) {
                return swapped
            }
            plan.target = TimelineTrackDrop.placement(rowCount: rows.count, desiredRow: desiredRow, deliberateInsertRow: insertRow,
                                                      preferInsertAbove: preferInsertAbove) { free($0, s, e) }
            if case .row(let r) = plan.target { plan.rowDelta = r - located[0].row! }
            plan.valid = true
            return plan
        }
        // Rigid group: every member shifts by the same rows and frames, or nothing moves.
        let rowDelta = desiredRow - originRow
        let ok = located.allSatisfy { m in
            let s = m.clip.startFrame + delta
            return s >= 0 && free(m.row! + rowDelta, s, s + m.clip.durationFrames)
        }
        guard ok else { return plan }
        plan.rowDelta = rowDelta; plan.target = .row(originRow + rowDelta); plan.valid = true
        return plan
    }

    /// Commit a resolved drag as one undo step: the moves, the new track for an insert drop, and the removal of
    /// rows the drag left empty (a lane exists while it holds clips).
    @discardableResult
    func commitMove(_ plan: TimelineMovePlan) -> Bool {
        guard plan.valid, !plan.clipIds.isEmpty else { return false }
        if plan.isSwap { return commitSwap(plan) }
        let moving = plan.clipIds.compactMap { id in clip(id).map { (id: id, track: $0.track, clip: $0.clip) } }
        guard moving.count == plan.clipIds.count else { return false }
        let isInsert: Bool = { if case .insert = plan.target { return true }; return false }()
        guard plan.deltaFrames != 0 || plan.rowDelta != 0 || isInsert else { return false }
        let sources = Set(moving.map(\.track.id))
        let label = isInsert ? "Move clip to new track" : moving.count == 1 ? "Move clip" : "Move clips"
        return transaction(label) { step, scratch in
            var destination: [String: String] = [:]
            switch plan.target {
            case .insert(let boundary):
                guard moving.count == 1 else { return false }
                var d = scratch()
                let audio = d.assets.first { $0.id == moving[0].clip.assetId }?.kind == .audio
                let kind: NativeProjectTrackKind = audio ? .audio : .video
                let tid = Self.freshTrackId(d, kind)
                let authored = (d.sequence.tracks.enumerated().map { ($0.element.lane ?? Self.indexLane($0.offset)).authoredTrack }.max() ?? 0) + 1
                d.sequence.tracks.append(NativeProjectTrack(id: tid, kind: kind, lane: .init(authoredTrack: authored, displayTrack: 0), clips: []))
                var order = displayTrackIds
                if boundary < plan.rows.count, let at = order.firstIndex(of: plan.rows[boundary]) { order.insert(tid, at: at) }
                else if let last = plan.rows.last, let at = order.firstIndex(of: last) { order.insert(tid, at: at + 1) }
                else { order.append(tid) }
                Self.renumberDisplay(&d, order)
                guard step(.restoreDocument(d)) else { return false }
                destination[moving[0].id] = tid
            case .row:
                for m in moving {
                    guard let r = plan.rows.firstIndex(of: m.track.id), plan.rows.indices.contains(r + plan.rowDelta) else { return false }
                    destination[m.id] = plan.rows[r + plan.rowDelta]
                }
            }
            let moves = moving.map { m in
                NativeProjectClipMove(address: .init(sequenceId: sequenceId, trackId: m.track.id, clipId: m.id),
                                      destination: .init(trackId: destination[m.id]!, startFrame: m.clip.startFrame + plan.deltaFrames))
            }
            guard step(moves.count == 1 ? .move(address: moves[0].address, destination: moves[0].destination) : .moveMany(moves)) else { return false }
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

public extension TimelineView {
    /// getTimelineRowPositionFromY: the pointer's position in rows from the top of the first row (negative above
    /// it, past `tracks.count` below the last), the row under it, the fraction inside that row and its height.
    func rowPosition(atY y: Double) -> (rowFloat: Double, row: Int, fraction: Double, rowHeight: Double) {
        let cy = y + scrollY
        let frames = bandFrames().compactMap { f -> (Int, TimelineBandFrame)? in if case .track(let i) = f.band { return (i, f) }; return nil }
        guard let first = frames.first, let last = frames.last else { return (cy / trackHeight, 0, 0, trackHeight) }
        if cy < first.1.top {
            let f = (cy - first.1.top) / first.1.height
            return (f, Int(f.rounded(.down)), f - f.rounded(.down), first.1.height)
        }
        if cy >= last.1.bottom {
            let f = Double(frames.count) + (cy - last.1.bottom) / trackHeight
            return (f, Int(f.rounded(.down)), f - f.rounded(.down), trackHeight)
        }
        for (i, f) in frames where cy < f.bottom {
            // A group header above row i reads as the middle of row i (never a boundary drop).
            let frac = cy < f.top ? 0.5 : (cy - f.top) / f.height
            return (Double(i) + frac, i, frac, f.height)
        }
        return (Double(frames.count), frames.count, 0, trackHeight)
    }

    /// Top of the boundary above display row `k` (the bottom of the last row for `k == tracks.count`).
    func boundaryTop(_ k: Int) -> Double {
        if k < tracks.count { return rowTop(k) }
        guard let last = tracks.indices.last else { return TimelineLayout.rowTop(0) - scrollY }
        return rowTop(last) + trackRowHeight(last)
    }

    /// TimelineCanvas drop placeholder (clip-sized slot at the landing spot) or insertion line (new track).
    func drawDropPreview(_ c: CanvasContext, contentWidth: Double) {
        guard case let .move(ids, delta, td, _)? = drag, let target = dropTarget else { return }
        switch target {
        case .insert(let k):
            c.fillRect(CanvasRect(x: TimelineLayout.contentOrigin, y: boundaryTop(k) - 0.5, width: contentWidth, height: 1), theme.accent)
        case .row:
            for (i, t) in tracks.enumerated() {
                for clip in t.clips where ids.contains(clip.id) {
                    let row = i + td
                    guard tracks.indices.contains(row) else { continue }
                    let r = CanvasRect(x: x(for: clip.start + delta), y: rowTop(row) + TimelineLayout.clipY,
                                       width: max(clip.duration * pixelsPerSecond, 4), height: trackHeight - 2 * TimelineLayout.clipY)
                    drawDropSlot(c, r)
                }
            }
        }
        // Swap: a second slot in the same style where each displaced clip goes (its time unchanged), or the
        // new-track line when it opens one.
        guard let swap = displacedDrop else { return }
        switch swap.target {
        case .insert(let k):
            c.fillRect(CanvasRect(x: TimelineLayout.contentOrigin, y: boundaryTop(k) - 0.5, width: contentWidth, height: 1), theme.accent)
        case .row(let row):
            guard tracks.indices.contains(row) else { return }
            for t in tracks { for clip in t.clips where swap.clipIds.contains(clip.id) {
                drawDropSlot(c, CanvasRect(x: x(for: clip.start), y: rowTop(row) + TimelineLayout.clipY,
                                           width: max(clip.duration * pixelsPerSecond, 4), height: trackHeight - 2 * TimelineLayout.clipY))
            } }
        }
    }

    /// The mint landing slot (TimelineCanvas drop placeholder).
    func drawDropSlot(_ c: CanvasContext, _ r: CanvasRect) {
        c.fillRoundedRect(r, radius: 4, CanvasColor(ThemeTokens.mint.alpha(0.12)))
        c.strokeRoundedRect(r.insetBy(0.5), radius: 4, CanvasColor(ThemeTokens.mint.alpha(0.55)), width: 1)
    }
}

extension TimelineController {
    /// Resolve the live clip move (timelineClipDragPreview computeDragPreview): the pointer's row travel picks the
    /// aimed row, a boundary or edge hover asks for a new track, and the editor's placement settles the landing.
    func updateMovePlan(_ editor: TimelineEditor, ids: [String], grabbed: String, anchorRow: Int, deltaSeconds: Double,
                        snapTime: Double?, x0: Double, y0: Double, y: Double) {
        let rows = view.tracks.map(\.id)
        let origin = view.rowPosition(atY: y0), now = view.rowPosition(atY: y)
        let desired = TimelineTrackDrop.desiredRow(originRow: anchorRow, originRowFloat: origin.rowFloat, rowFloat: now.rowFloat, rowCount: rows.count)
        let insert = ids.count == 1
            ? TimelineTrackDrop.insertRow(rowFloat: now.rowFloat, rowCount: rows.count, band: TimelineLayout.clipY / max(now.rowHeight, 1)) : nil
        let plan = editor.planMove(clipIds: ids, grabbed: grabbed, deltaFrames: (deltaSeconds * editor.fps).rounded(), rows: rows,
                                   desiredRow: desired, insertRow: insert, preferInsertAbove: now.fraction < 0.5, swap: !dragSwapDisabled)
        movePlan = plan
        view.displacedDrop = plan.isSwap ? plan.displacedTarget.map { (plan.displaced, $0) } : nil
        guard plan.valid else {
            // A refused formation stays where it was (resolveRigidGroupMove invalid).
            view.drag = .move(clipIds: ids, deltaSeconds: 0, trackDelta: 0, snapTime: nil)
            view.dropTarget = .row(anchorRow); view.dragLiftY = y - y0
            return
        }
        view.drag = .move(clipIds: ids, deltaSeconds: plan.deltaFrames / editor.fps, trackDelta: plan.rowDelta, snapTime: snapTime)
        view.dropTarget = plan.target
        view.dragLiftY = y - y0
    }
}
