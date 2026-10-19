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

/// Lane gaps and clip clipboard on the native document.
public enum TimelineGaps {
    public static let epsilon = 1e-3
    public struct GapAt: Equatable { public var gapStart: Double, gapEnd: Double; public var followingIds: [String] }

    static func sorted(_ clips: [TimelineClipModel]) -> [TimelineClipModel] {
        clips.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }

    /// resolveTrackGapAt
    public static func gap(at time: Double, in clips: [TimelineClipModel], floor: Double = 0) -> GapAt? {
        let s = sorted(clips)
        if s.contains(where: { time >= $0.start - epsilon && time < $0.end - epsilon }) { return nil }
        let following = s.filter { $0.start > time - epsilon }
        guard let first = following.first else { return nil }
        let gapStart = max(floor, s.filter { $0.start <= time - epsilon }.map(\.end).max() ?? floor)
        guard first.start - gapStart > epsilon else { return nil }
        return GapAt(gapStart: gapStart, gapEnd: first.start, followingIds: following.map(\.id))
    }

    /// resolveAllGapIntervals
    public static func intervals(_ clips: [TimelineClipModel], floor: Double = 0) -> [(start: Double, end: Double)] {
        var out: [(Double, Double)] = []; var cursor = floor
        for c in sorted(clips) { if c.start - cursor > epsilon { out.append((cursor, c.start)) }; cursor = max(cursor, c.end) }
        return out
    }

    /// resolveAllTrackGaps: compact the lane contiguous from `floor`.
    public static func compaction(_ clips: [TimelineClipModel], floor: Double = 0) -> [(id: String, newStart: Double)] {
        var out: [(String, Double)] = []; var cursor = floor
        for c in sorted(clips) {
            let ns = (cursor * 1000).rounded() / 1000
            if abs(ns - c.start) > epsilon { out.append((c.id, ns)) }
            cursor = ns + c.duration
        }
        return out
    }
}

public extension TimelineEditor {
    /// One undoable move of several clips to new starts on their own tracks.
    @discardableResult
    func shift(_ starts: [(id: String, newStart: Double)]) -> Bool {
        let moves: [NativeProjectClipMove] = starts.compactMap { s in
            guard let a = address(clipId: s.id) else { return nil }
            return NativeProjectClipMove(address: a, destination: .init(trackId: a.trackId, startFrame: (s.newStart * fps).rounded()))
        }
        if moves.isEmpty { return false }
        return moves.count == 1 ? apply(.move(address: moves[0].address, destination: moves[0].destination)) : apply(.moveMany(moves))
    }

    /// "Close gap": shift every following clip on the lane left by the gap width.
    @discardableResult
    func closeGap(trackId: String, at time: Double) -> Bool {
        guard let t = tracks.first(where: { $0.id == trackId }), let g = TimelineGaps.gap(at: time, in: t.clips) else { return false }
        let w = g.gapEnd - g.gapStart
        return withHistory("Close gap") { shift(t.clips.filter { g.followingIds.contains($0.id) }.map { ($0.id, $0.start - w) }) }
    }

    /// "Close all gaps": compact the lane from 0.
    @discardableResult
    func closeAllGaps(trackId: String) -> Bool {
        guard let t = tracks.first(where: { $0.id == trackId }) else { return false }
        return withHistory("Close all gaps") { shift(TimelineGaps.compaction(t.clips)) }
    }

    /// Clipboard payload: the clips (with their track) as they were when copied.
    struct ClipboardItem: Equatable { public var trackId: String; public var clip: NativeProjectClip }

    func copyClips(_ ids: Set<String>) -> [ClipboardItem] {
        document.sequence.tracks.flatMap { t in t.clips.filter { ids.contains($0.id) }.map { ClipboardItem(trackId: t.id, clip: $0) } }
    }

    /// Paste at `time` (earliest copied clip lands there, relative offsets kept) on each clip's source track.
    /// Fresh ids; one undo step (restoreDocument). Returns the new clip ids.
    @discardableResult
    func paste(_ items: [ClipboardItem], at time: Double) -> [String] {
        guard let first = items.map(\.clip.startFrame).min() else { return [] }
        var doc = document
        let base = (time * fps).rounded()
        var newIds: [String] = []
        let existing = Set(doc.sequence.tracks.flatMap(\.clips).map(\.id))
        for item in items {
            guard let ti = doc.sequence.tracks.firstIndex(where: { $0.id == item.trackId }), doc.sequence.tracks[ti].locked != true else { continue }
            var c = item.clip
            var n = 1; var id = "\(c.id)-copy"
            while existing.contains(id) || newIds.contains(id) { n += 1; id = "\(item.clip.id)-copy\(n)" }
            c.id = id
            c.startFrame = base + (item.clip.startFrame - first)
            doc.sequence.tracks[ti].clips.append(c)
            doc.sequence.tracks[ti].clips.sort { $0.startFrame < $1.startFrame }
            newIds.append(id)
        }
        guard !newIds.isEmpty, withHistory("Paste", { apply(.restoreDocument(doc)) }) else { return [] }
        return newIds
    }
}
