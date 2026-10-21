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

/// One row under a keyed clip. A clip shows one summary row by default (every key of every property, one mark per
/// frame); expanded (U, or the summary row's disclosure) it adds its animated properties grouped by kind: a kind with
/// one property shows that property's row, a kind with several shows a kind row (all its keys) and, unless that kind
/// is collapsed, one row per property under it.
public enum TimelineLaneRow: Hashable, Sendable { case summary, kind(TimelineKeyframeKind), property(String) }

extension TimelineView {
    /// The rows under `clip`, top to bottom; none when it has no keys.
    public func laneRows(_ clip: TimelineClipModel) -> [TimelineLaneRow] {
        guard !clip.lanes.isEmpty else { return [] }
        guard expandedClips.contains(clip.id) else { return [.summary] }
        var rows: [TimelineLaneRow] = [.summary]
        for kind in TimelineKeyframeKind.allCases {
            let lanes = propertyLanes(clip, kind: kind)
            guard !lanes.isEmpty else { continue }
            if lanes.count == 1 { rows.append(.property(lanes[0].group)); continue }
            rows.append(.kind(kind))
            if !(collapsedKinds[clip.id]?.contains(kind) ?? false) { rows += lanes.map { .property($0.group) } }
        }
        return rows
    }

    /// The clip's lanes of one kind, in the inspector's order.
    func propertyLanes(_ clip: TimelineClipModel, kind: TimelineKeyframeKind) -> [TimelineLaneModel] {
        clip.lanes.filter { $0.kind == kind }.sorted { (TimelineKeyframeCatalog.order(ofGroup: $0.group), $0.label) < (TimelineKeyframeCatalog.order(ofGroup: $1.group), $1.label) }
    }

    /// The property groups a row shows the keys of; nil for the summary (every channel).
    public func rowScope(_ row: TimelineLaneRow, _ clip: TimelineClipModel) -> Set<String>? {
        switch row {
        case .summary: nil
        case .kind(let k): Set(clip.lanes.filter { $0.kind == k }.map(\.group))
        case .property(let g): [g]
        }
    }

    /// The row's index in `clip.lanes` when it is one property's row (the lane index the older API takes).
    func propertyLaneIndex(_ row: TimelineLaneRow, _ clip: TimelineClipModel) -> Int? {
        guard case .property(let g) = row else { return nil }
        return clip.lanes.firstIndex { $0.group == g }
    }

    public func rowLabel(_ row: TimelineLaneRow, _ clip: TimelineClipModel) -> String {
        switch row {
        case .summary: "Keyframes"
        case .kind(let k): k.label
        case .property(let g): clip.lanes.first { $0.group == g }?.label ?? g
        }
    }

    /// The kind a row draws with; nil for the summary, whose marks take their own keys' kinds.
    public func rowKind(_ row: TimelineLaneRow, _ clip: TimelineClipModel) -> TimelineKeyframeKind? {
        switch row {
        case .summary: nil
        case .kind(let k): k
        case .property(let g): clip.lanes.first { $0.group == g }?.kind ?? TimelineKeyframeCatalog.kind(ofGroup: g)
        }
    }

    /// Top of the first lane row of track `i` (view coordinates).
    func laneBase(track i: Int) -> Double {
        rowTop(i) + trackHeight + Double(effectLaneCount(track: i)) * TimelineLayout.effectStripHeight
    }

    /// The rows of track `i`: every row any of its clips shows, in one order (summary, then each kind's row and
    /// its properties), so a row means the same property under every clip of the track and the header labels
    /// all of them.
    public func trackLaneRows(_ i: Int) -> [TimelineLaneRow] {
        guard tracks.indices.contains(i) else { return [] }
        return Array(Set(tracks[i].clips.flatMap { laneRows($0) })).sorted { Self.rank($0) < Self.rank($1) }
    }

    static func rank(_ row: TimelineLaneRow) -> (Int, Int, Int, String) {
        switch row {
        case .summary: (-1, 0, 0, "")
        case .kind(let k): (k.order, 0, 0, "")
        case .property(let g): (TimelineKeyframeCatalog.kind(ofGroup: g).order, 1, TimelineKeyframeCatalog.order(ofGroup: g), g)
        }
    }

    /// The clip a header row of track `i` speaks for: the selected clip showing it, else the first that does.
    func rowOwner(_ row: TimelineLaneRow, track i: Int) -> TimelineClipModel? {
        guard tracks.indices.contains(i) else { return nil }
        let showing = tracks[i].clips.filter { laneRows($0).contains(row) }
        return showing.first { selection.contains($0.id) } ?? showing.first
    }

    /// The track row under a view-space y on track `i`, with its top.
    func trackLaneRow(track i: Int, y: Double) -> (row: TimelineLaneRow, top: Double)? {
        let base = laneBase(track: i), rows = trackLaneRows(i)
        let j = Int(((y - base) / TimelineLayout.laneHeight).rounded(.down))
        guard y >= base, rows.indices.contains(j) else { return nil }
        return (rows[j], base + Double(j) * TimelineLayout.laneHeight)
    }

    /// The lane row under a view-space y on track `i`, when `clip` shows it.
    func laneRow(_ clip: TimelineClipModel, track i: Int, y: Double) -> (row: TimelineLaneRow, top: Double)? {
        guard let hit = trackLaneRow(track: i, y: y), laneRows(clip).contains(hit.row) else { return nil }
        return hit
    }

    /// Top of `row` on track `i` (view coordinates); nil when the track does not show it.
    func laneTop(_ row: TimelineLaneRow, track i: Int) -> Double? {
        trackLaneRows(i).firstIndex(of: row).map { laneBase(track: i) + Double($0) * TimelineLayout.laneHeight }
    }

    // MARK: Disclosure (the summary row and kind rows in the header column)

    /// The caret box of a summary or kind row header.
    static func disclosureRect(laneTop y: Double, row: TimelineLaneRow) -> CanvasRect {
        let indent: Double = row == .summary ? 4 : 16
        return CanvasRect(x: indent, y: y + (TimelineLayout.laneHeight - 24) / 2, width: 24, height: 24)
    }

    /// The summary or kind row whose disclosure caret is under (x, y) on track `i`.
    func laneDisclosure(atX x: Double, y: Double, track i: Int) -> (clip: TimelineClipModel, row: TimelineLaneRow)? {
        guard x < TimelineLayout.labelColumnWidth, let hit = trackLaneRow(track: i, y: y), let clip = rowOwner(hit.row, track: i) else { return nil }
        switch hit.row {
        case .property: return nil
        case .summary, .kind:
            let r = Self.disclosureRect(laneTop: hit.top, row: hit.row)
            return x >= r.x && x <= r.maxX ? (clip, hit.row) : nil
        }
    }
}

public extension TimelineController {
    /// A click in a lane row's header: its disclosure caret, else its ‹ ◆ ›. True when one was hit.
    internal func laneHeaderClick(x: Double, y: Double, row: Int) -> Bool {
        if let d = view.laneDisclosure(atX: x, y: y, track: row) { return toggleDisclosure(clipId: d.clip.id, row: d.row) || true }
        guard let lc = view.laneControl(atX: x, y: y, track: row) else { return false }
        laneRowControlClick(clipId: lc.clip.id, row: lc.row, control: lc.control)
        return true
    }

    /// The summary row's caret expands / collapses the clip's property rows; a kind row's folds that kind.
    @discardableResult func toggleDisclosure(clipId: String, row: TimelineLaneRow) -> Bool {
        switch row {
        case .summary:
            if view.expandedClips.contains(clipId) { view.expandedClips.remove(clipId) } else { view.expandedClips.insert(clipId) }
        case .kind(let k):
            var kinds = view.collapsedKinds[clipId] ?? []
            if kinds.contains(k) { kinds.remove(k) } else { kinds.insert(k) }
            view.collapsedKinds[clipId] = kinds.isEmpty ? nil : kinds
        case .property:
            return false
        }
        clampScroll(); needsDisplay?(); return true
    }
}
