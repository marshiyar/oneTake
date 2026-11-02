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

/// Cut to beats (⇧⌘B): the selected clips laid end to end from the first one's start, each cut on a beat mark of the
/// music clip under them (#291). The plan is plain data so it can be tested and shown before anything changes.
public struct TimelineBeatCutPlan: Equatable, Sendable {
    /// One selected clip as laid out: its new start and length, in whole frames.
    public struct Item: Equatable, Sendable {
        public var clipId: String
        public var name: String
        public var startFrame: Double
        public var durationFrames: Double
        /// False when no beat fell inside the clip, so it keeps its length and its cut is off the grid.
        public var onBeat: Bool
    }
    /// The music clip whose beats the cuts follow.
    public var musicClipId: String
    public var items: [Item]
    /// Names of the clips left at their length because the next beat was further away than the clip is long.
    public var keptLength: [String] { items.filter { !$0.onBeat }.map(\.name) }
}

/// Why the command cannot run, in words for the user.
public struct TimelineBeatCutRefusal: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public extension TimelineEditor {
    /// What ⇧⌘B would do to `clipIds`, or the reason it cannot. The selected clips must sit on one unlocked track, a clip
    /// with beat marks (not itself selected) must lie under them, and the new layout must not run into another clip.
    func planBeatCut(clipIds: Set<String>) -> Result<TimelineBeatCutPlan, TimelineBeatCutRefusal> {
        let tracks = document.sequence.tracks
        var selected: [(Int, NativeProjectClip)] = []
        for (index, track) in tracks.enumerated() { selected += track.clips.filter { clipIds.contains($0.id) }.map { (index, $0) } }
        guard let first = selected.map({ $0.1 }).min(by: { $0.startFrame < $1.startFrame }) else {
            return .failure(.init("Select the clips to cut to the beat"))
        }
        guard Set(selected.map { $0.0 }).count == 1, let trackIndex = selected.first?.0 else {
            return .failure(.init("Select clips on one track to cut them to the beat"))
        }
        guard tracks[trackIndex].locked != true else { return .failure(.init("Track is locked")) }
        let ordered = selected.map { $0.1 }.sorted { ($0.startFrame, $0.id) < ($1.startFrame, $1.id) }
        let spanEnd = ordered.map { $0.startFrame + $0.durationFrames }.max() ?? first.startFrame
        guard let music = beatCutMusic(excluding: clipIds, from: first.startFrame, to: spanEnd) else {
            return .failure(.init("No music clip with beat marks under the selected clips"))
        }
        let beats = Array(Set(music.visibleBeatFrames.map { $0.timeline.rounded() })).sorted()
        var cursor = first.startFrame
        var items: [TimelineBeatCutPlan.Item] = []
        for clip in ordered {
            let natural = cursor + clip.durationFrames
            // The last beat inside the clip: the cut is trimmed back to it, never pushed past the clip's own media.
            let end = beats.last { $0 > cursor && $0 <= natural }
            items.append(.init(clipId: clip.id, name: beatCutName(clip), startFrame: cursor,
                               durationFrames: end.map { $0 - cursor } ?? clip.durationFrames, onBeat: end != nil))
            cursor = end ?? natural
        }
        // The laid-out clips may not run into a clip that was not selected.
        let placed = items.map { ($0.startFrame, $0.startFrame + $0.durationFrames) }
        for other in tracks[trackIndex].clips where !clipIds.contains(other.id) {
            let (s, e) = (other.startFrame, other.startFrame + other.durationFrames)
            if placed.contains(where: { $0.0 < e && s < $0.1 }) {
                return .failure(.init("A clip between the selected clips is in the way"))
            }
        }
        return .success(.init(musicClipId: music.id, items: items))
    }

    /// Why ⇧⌘B is unavailable for `clipIds`, nil when it can run.
    func beatCutRefusal(clipIds: Set<String>) -> String? {
        if case .failure(let refusal) = planBeatCut(clipIds: clipIds) { return refusal.message }
        return nil
    }

    /// Lays the selected clips end to end with their cuts on the beats, as one undo step. Clips are trimmed at their out
    /// points, never extended; a clip no beat falls inside keeps its length and the notice names it. Returns the plan
    /// that was applied; nil when it is refused or nothing would change, with `lastFailure` saying why.
    @discardableResult
    func cutToBeats(clipIds: Set<String>) -> TimelineBeatCutPlan? {
        let plan: TimelineBeatCutPlan
        switch planBeatCut(clipIds: clipIds) {
        case .failure(let refusal): lastFailure = .init(code: .invalidTrim, message: refusal.message); return nil
        case .success(let p): plan = p
        }
        var trims: [NativeProjectClipCommand] = [], moves: [NativeProjectClipMove] = []
        for item in plan.items {
            guard let a = address(clipId: item.clipId), let (_, current) = self.clip(item.clipId) else { return nil }
            if item.durationFrames != current.durationFrames {
                trims.append(.trimOut(address: a, endFrameExclusive: current.startFrame + item.durationFrames))
            }
            if item.startFrame != current.startFrame {
                moves.append(.init(address: a, destination: .init(trackId: a.trackId, startFrame: item.startFrame)))
            }
        }
        guard !trims.isEmpty || !moves.isEmpty else {
            lastFailure = .init(code: .invalidTrim, message: "The clips already cut on the beats"); return nil
        }
        let done = transaction("Cut to beats") { step, _ in
            guard trims.allSatisfy({ step($0) }) else { return false }
            return moves.isEmpty || step(moves.count == 1 ? .move(address: moves[0].address, destination: moves[0].destination) : .moveMany(moves))
        }
        guard done else { return nil }
        let kept = plan.keptLength
        if !kept.isEmpty {
            let names = kept.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            let message = kept.count == 1 ? "\(names) is shorter than the next beat and keeps its length"
                                          : "\(names) are shorter than the next beat and keep their length"
            lastNotice = message
            onNotice?(message)
        }
        return plan
    }

    /// The clip with beat marks the cuts follow: an unselected audio clip with marks inside the span, the one with the
    /// most marks there (the earliest on a tie).
    private func beatCutMusic(excluding selected: Set<String>, from start: Double, to end: Double) -> NativeProjectClip? {
        let audio = Set(document.assets.filter { $0.kind == .audio }.map(\.id))
        var best: (clip: NativeProjectClip, marks: Int)?
        for track in document.sequence.tracks {
            for clip in track.clips where audio.contains(clip.assetId) && !selected.contains(clip.id) {
                let marks = clip.visibleBeatFrames.filter { $0.timeline > start && $0.timeline <= end }.count
                guard marks > 0 else { continue }
                if best == nil || marks > best!.marks || (marks == best!.marks && clip.startFrame < best!.clip.startFrame) { best = (clip, marks) }
            }
        }
        return best?.clip
    }

    private func beatCutName(_ clip: NativeProjectClip) -> String {
        clip.name ?? document.assets.first { $0.id == clip.assetId }?.name ?? clip.id
    }
}
