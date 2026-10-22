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

/// Track operations on the native document: add, remove, reorder, mute, solo, hide, lock.
/// Every op is one undo step (restoreDocument inverse).
public extension TimelineEditor {
    func isTrackLocked(_ trackId: String) -> Bool {
        document.sequence.tracks.first { $0.id == trackId }?.locked == true
    }

    func isClipLocked(_ clipId: String) -> Bool {
        address(clipId: clipId).map { isTrackLocked($0.trackId) } ?? false
    }

    /// Track ids in display order.
    var displayTrackIds: [String] { tracks.map(\.id) }

    /// Add an empty track at display position `index` (nil = bottom). Returns the new track id.
    @discardableResult
    func addTrack(kind: NativeProjectTrackKind, at index: Int? = nil) -> String? {
        var d = document
        var order = displayTrackIds
        let id = Self.appendTrack(&d, kind: kind, order: &order, at: index)
        return commit(d, "Add track") ? id : nil
    }

    /// Remove a track and every clip on it. Refused for a locked track.
    @discardableResult
    func removeTrack(_ trackId: String) -> Bool {
        guard let t = document.sequence.tracks.first(where: { $0.id == trackId }), t.locked != true else { return false }
        let order = displayTrackIds.filter { $0 != trackId }
        return transaction("Remove track") { step, scratch in
            let addrs = t.clips.map { NativeProjectClipAddress(sequenceId: sequenceId, trackId: trackId, clipId: $0.id) }
            if !addrs.isEmpty && !step(addrs.count == 1 ? .delete(address: addrs[0]) : .deleteMany(addrs)) { return false }
            var d = scratch()
            d.sequence.tracks.removeAll { $0.id == trackId }
            Self.renumberDisplay(&d, order)
            return step(.restoreDocument(d))
        }
    }

    /// Move a track to display position `index` (clamped).
    @discardableResult
    func moveTrack(_ trackId: String, to index: Int) -> Bool {
        var order = displayTrackIds
        guard let from = order.firstIndex(of: trackId) else { return false }
        order.remove(at: from)
        let to = max(0, min(order.count, index))
        guard to != from else { return false }
        order.insert(trackId, at: to)
        var d = document
        Self.renumberDisplay(&d, order)
        return commit(d, "Reorder tracks")
    }

    /// Hide or show a track. Hidden tracks are omitted from the timeline's stage elements.
    @discardableResult
    func setTrackHidden(_ trackId: String, _ hidden: Bool) -> Bool {
        updateTrack(trackId, hidden ? "Hide track" : "Show track") { $0.hidden = hidden ? true : nil }
    }

    /// Lock or unlock a track. Locking is the one edit a locked track still accepts.
    @discardableResult
    func setTrackLocked(_ trackId: String, _ locked: Bool) -> Bool {
        guard let i = document.sequence.tracks.firstIndex(where: { $0.id == trackId }) else { return false }
        var d = document
        d.sequence.tracks[i].locked = locked ? true : nil
        return commit(d, locked ? "Lock track" : "Unlock track")
    }

    /// Mute or unmute every clip on a track (the clip mute the audio mix already honours).
    @discardableResult
    func setTrackMuted(_ trackId: String, _ muted: Bool) -> Bool {
        let detached = Set(document.sequence.tracks.flatMap(\.clips).compactMap(\.audioDetachedFrom))
        // A video whose sound is detached stays muted.
        return updateTrack(trackId, muted ? "Mute track" : "Unmute track") { t in for i in t.clips.indices where muted || !detached.contains(t.clips[i].id) { t.clips[i].muted = muted } }
    }

    /// Set a persisted mixer fader and pan as one undoable edit.
    @discardableResult
    func setTrackMixer(_ trackId: String, gainDB: Double, pan: Double) -> Bool {
        guard gainDB.isFinite, (-60...12).contains(gainDB), pan.isFinite, (-1...1).contains(pan),
              document.sequence.tracks.contains(where: { $0.id == trackId && $0.kind == .audio }) else { return false }
        return updateTrack(trackId, "Adjust track mixer") {
            $0.mixerGainDB = gainDB == 0 ? nil : gainDB
            $0.mixerPan = pan == 0 ? nil : pan
        }
    }

    /// Solo or unsolo an audio track: while any audio track is soloed only soloed tracks are heard (DocumentAudioGraph).
    /// Solo changes what is monitored, not the clips, so a locked track accepts it too, as it accepts unlocking.
    /// Refused for video and mixed tracks, which have no solo button.
    @discardableResult
    func setTrackSoloed(_ trackId: String, _ soloed: Bool) -> Bool {
        guard let i = document.sequence.tracks.firstIndex(where: { $0.id == trackId && $0.kind == .audio }) else { return false }
        var d = document
        d.sequence.tracks[i].soloed = soloed ? true : nil
        return commit(d, soloed ? "Solo track" : "Unsolo track")
    }

    /// A track counts as muted when it has clips and all of them are muted.
    func isTrackMuted(_ trackId: String) -> Bool {
        guard let t = document.sequence.tracks.first(where: { $0.id == trackId }), !t.clips.isEmpty else { return false }
        return t.clips.allSatisfy(\.muted)
    }

    internal func updateTrack(_ trackId: String, _ label: String, _ change: (inout NativeProjectTrack) -> Void) -> Bool {
        guard let i = document.sequence.tracks.firstIndex(where: { $0.id == trackId }), document.sequence.tracks[i].locked != true else { return false }
        var d = document
        change(&d.sequence.tracks[i])
        return commit(d, label)
    }

    /// Validate and commit a whole-document edit as one undo step.
    internal func commit(_ d: NativeProjectDocument, _ label: String) -> Bool {
        guard d != document else { return false }
        // Transitions follow the clips the edit moved, trimmed or removed, in the same step.
        let fitted = reconcileNativeCutTransitions(d)
        return withHistory(label) { apply(.restoreDocument(fitted)) }
    }

    /// Adds an empty track of `kind` to `d` at display position `index` of `order` (nil = bottom) and renumbers the
    /// lanes to `order`. Returns the new track id.
    internal static func appendTrack(_ d: inout NativeProjectDocument, kind: NativeProjectTrackKind, order: inout [String], at index: Int?) -> String {
        let existing = Set(d.sequence.tracks.map(\.id))
        var n = d.sequence.tracks.filter { $0.kind == kind }.count + 1
        while existing.contains("track:\(kind.rawValue)\(n)") { n += 1 }
        let id = "track:\(kind.rawValue)\(n)"
        let authored = (d.sequence.tracks.enumerated().filter { $0.element.kind == kind }
            .map { ($0.element.lane ?? Self.indexLane($0.offset)).authoredTrack }.max() ?? 0) + 1
        d.sequence.tracks.append(NativeProjectTrack(id: id, kind: kind, lane: .init(authoredTrack: authored, displayTrack: 0), clips: []))
        order.insert(id, at: max(0, min(order.count, index ?? order.count)))
        renumberDisplay(&d, order)
        return id
    }

    /// The lane the parser assumes for a track without one.
    internal static func indexLane(_ i: Int) -> NativeProjectTrackLane { .init(authoredTrack: Double(i), displayTrack: Double(i)) }

    /// Rewrite lane.displayTrack as 0..<n following `order`.
    internal static func renumberDisplay(_ d: inout NativeProjectDocument, _ order: [String]) {
        for (i, t) in d.sequence.tracks.enumerated() {
            guard let pos = order.firstIndex(of: t.id) else { continue }
            let lane = t.lane ?? indexLane(i)
            d.sequence.tracks[i].lane = NativeProjectTrackLane(authoredTrack: lane.authoredTrack, displayTrack: Double(pos), spread: lane.spread)
        }
    }

    /// Whether a clip command touches a locked track (as source or destination).
    internal func touchesLockedTrack(_ command: NativeProjectClipCommand) -> Bool {
        let locked = Set(document.sequence.tracks.filter { $0.locked == true }.map(\.id))
        guard !locked.isEmpty else { return false }
        switch command {
        case .restoreDocument: return false
        case let .move(a, dest): return locked.contains(a.trackId) || locked.contains(dest.trackId)
        case .moveMany(let list): return list.contains { locked.contains($0.address.trackId) || locked.contains($0.destination.trackId) }
        case let .trimIn(a, _), let .trimOut(a, _), let .delete(a): return locked.contains(a.trackId)
        case let .split(a, _, _): return locked.contains(a.trackId)
        case .deleteMany(let list): return list.contains { locked.contains($0.trackId) }
        case let .slip(a, _): return locked.contains(a.trackId)
        case .roll(let roll): return locked.contains(roll.outgoing.trackId) || locked.contains(roll.incoming.trackId)
        }
    }
}
