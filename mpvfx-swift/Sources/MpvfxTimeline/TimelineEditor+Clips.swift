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

/// Clip-level edits beyond move/trim/split: hide, insert, keyframe commands, silence removal.
public extension TimelineEditor {
    // MARK: Hide (timeline eye toggle, toggleTimelineElementHidden)

    /// Hide or show clips in one undo step. Locked tracks are skipped.
    @discardableResult
    func setClipsHidden(_ ids: Set<String>, _ hidden: Bool) -> Bool {
        var d = document
        for ti in d.sequence.tracks.indices where d.sequence.tracks[ti].locked != true {
            for ci in d.sequence.tracks[ti].clips.indices where ids.contains(d.sequence.tracks[ti].clips[ci].id) {
                d.sequence.tracks[ti].clips[ci].hidden = hidden ? true : nil
            }
        }
        return commit(d, hidden ? "Hide clip" : "Show clip")
    }

    func isClipHidden(_ id: String) -> Bool { clip(id)?.clip.hidden == true }

    // MARK: Insert (asset drop / add at playhead)

    /// Add a media asset to the project if no asset with the same source exists. Returns its id.
    @discardableResult
    func addAsset(kind: NativeProjectAssetKind, name: String, source: String?, durationFrames: Double,
                  naturalSize: NativeMediaNaturalSize? = nil) -> String? {
        if let s = source, let existing = document.assets.first(where: { $0.source == s && $0.kind == kind }) { return existing.id }
        guard durationFrames > 0, durationFrames.isFinite else { return nil }
        var d = document
        let ids = Set(d.assets.map(\.id))
        var n = d.assets.count + 1
        while ids.contains("asset:\(n)") { n += 1 }
        let id = "asset:\(n)"
        var asset = NativeProjectAsset(id: id, kind: kind, name: name, source: source, durationFrames: durationFrames.rounded())
        if kind == .video || kind == .image { asset.naturalSize = naturalSize }   // cached for the clip's default box
        d.assets.append(asset)
        return commit(d, "Import media") ? id : nil
    }

    /// Place an asset on the timeline at `time` seconds (frame-quantized). With no `trackId` the clip
    /// goes on the first compatible, unlocked lane (display order) that is free for its span, else on a
    /// new lane (video on top, audio at the bottom). `configure` fills in the new clip (a text layer's words) before
    /// it is committed. Returns the new clip id.
    @discardableResult
    func insertClip(assetId: String, at time: Double, trackId: String? = nil, durationFrames: Double? = nil,
                    configure: ((inout NativeProjectClip) -> Void)? = nil) -> String? {
        guard let asset = document.assets.first(where: { $0.id == assetId }) else { return nil }
        let start = max(0, (time * fps).rounded())
        let dur = max(1, (durationFrames ?? asset.durationFrames).rounded())
        let wantKind: NativeProjectTrackKind = asset.kind == .audio ? .audio : .video
        func compatible(_ t: NativeProjectTrack) -> Bool { t.locked != true && (t.kind == wantKind || t.kind == .mixed) }
        func free(_ t: NativeProjectTrack) -> Bool { !t.clips.contains { $0.startFrame < start + dur && start < $0.startFrame + $0.durationFrames } }
        var d = document
        let existing = Set(d.sequence.tracks.flatMap(\.clips).map(\.id))
        var n = existing.count + 1
        while existing.contains("clip:\(n)") { n += 1 }
        let clipId = "clip:\(n)"
        var fresh = NativeProjectClip.fresh(id: clipId, assetId: assetId, startFrame: start, durationFrames: dur)
        configure?(&fresh)
        let order = displayTrackIds
        var target = trackId
        if let t = target {
            guard let tr = d.sequence.tracks.first(where: { $0.id == t }), tr.locked != true else { return nil }
        } else {
            target = order.compactMap { id in d.sequence.tracks.first { $0.id == id } }.first { compatible($0) && free($0) }?.id
        }
        return withHistory("Insert clip") { () -> String? in
            if target == nil {
                // New lane in the same undo step as the clip.
                let created = transaction("Insert clip", { step, scratch in
                    var s = scratch()
                    let tid = Self.freshTrackId(s, wantKind)
                    let authored = (s.sequence.tracks.enumerated().filter { $0.element.kind == wantKind }
                        .map { ($0.element.lane ?? Self.indexLane($0.offset)).authoredTrack }.max() ?? 0) + 1
                    s.sequence.tracks.append(NativeProjectTrack(id: tid, kind: wantKind, lane: .init(authoredTrack: authored, displayTrack: 0),
                                                                clips: [fresh]))
                    Self.renumberDisplay(&s, wantKind == .audio ? order + [tid] : [tid] + order)
                    return step(.restoreDocument(s))
                })
                return created ? clipId : nil
            }
            guard let ti = d.sequence.tracks.firstIndex(where: { $0.id == target }) else { return nil }
            d.sequence.tracks[ti].clips.append(fresh)
            d.sequence.tracks[ti].clips.sort { $0.startFrame < $1.startFrame }
            if d.sequence.tracks[ti].kind != wantKind && d.sequence.tracks[ti].kind != .mixed { d.sequence.tracks[ti].kind = .mixed }
            return commit(d, "Insert clip") ? clipId : nil
        }
    }

    internal static func freshTrackId(_ d: NativeProjectDocument, _ kind: NativeProjectTrackKind) -> String {
        let existing = Set(d.sequence.tracks.map(\.id))
        var n = d.sequence.tracks.filter { $0.kind == kind }.count + 1
        while existing.contains("track:\(kind.rawValue)\(n)") { n += 1 }
        return "track:\(kind.rawValue)\(n)"
    }

    // MARK: Keyframes (inspector / lanes)

    /// Apply any native keyframe command (add, move, delete, retime, interpolation...) as one undo step.
    @discardableResult
    func applyKeyframe(_ command: NativeProjectKeyframeCommand, label: String = "Edit keyframes") -> Bool {
        let targets: [NativeProjectAtomicKeyframeCommand]
        switch command { case .atomic(let c): targets = [c]; case .batch(let l): targets = l; case .restoreDocument: targets = [] }
        if targets.contains(where: { isTrackLocked($0.address.trackId) }) {
            lastPropertyFailure = .init(code: .documentMismatch, message: "Track is locked"); return false
        }
        let before = document
        do {
            let r = try applyNativeProjectKeyframeCommand(document, command, engine: engine)
            guard case .success(let doc, _) = r else {
                if case .failure(_, let f) = r { lastPropertyFailure = f }
                return false
            }
            guard doc != before else { return false }
            withHistory(label) { replaceDocument(doc, inverse: .restoreDocument(before)) }
            lastPropertyFailure = nil
            return true
        } catch {
            lastPropertyFailure = .init(code: .documentMismatch, message: "\(error)"); return false
        }
    }

    // MARK: Remove silence (silence detection, then one cut transaction)

    /// Cut the silent spans (in source seconds, as detected on the clip's media) out of a clip and
    /// butt the kept pieces together from the clip's start. One undo step. Returns the removed seconds
    /// (0 when nothing was silent or the edit was refused).
    @discardableResult
    func removeSilence(clipId: String, sourceSilences: [SilenceRange]) -> Double {
        guard let a = address(clipId: clipId), !isTrackLocked(a.trackId), let (_, c) = clip(clipId) else { return 0 }
        let rate = c.playbackRate.map { $0.denominator != 0 ? $0.numerator / $0.denominator : 1 } ?? 1
        let f = fps
        let clipStart = c.startFrame / f, sourceStart = c.sourceInFrame / f
        // Native clips snap each silence edge to the frame grid in timeline time (useRemoveSilence).
        let snapped = sourceSilences.map { r in
            SilenceRange(start: sourceStart + (((clipStart + (r.start - sourceStart) / rate) * f).rounded() / f - clipStart) * rate,
                         end: sourceStart + (((clipStart + (r.end - sourceStart) / rate) * f).rounded() / f - clipStart) * rate)
        }
        let plan = TimelineSilencePlan(start: clipStart, duration: c.durationFrames / f, sourceStart: sourceStart, rate: rate, silences: snapped)
        guard !plan.removed.isEmpty else { return 0 }
        let ok = transaction("Remove silence") { step, scratch in
            var pieceIds: Set<String> = [clipId]
            for frame in Set(plan.cutTimes.map { ($0 * f).rounded() }).sorted(by: >) {
                let before = Set(scratch().sequence.tracks.flatMap(\.clips).map(\.id))
                guard step(.split(address: a, splitFrame: frame)) else { return false }
                pieceIds.formUnion(Set(scratch().sequence.tracks.flatMap(\.clips).map(\.id)).subtracting(before))
            }
            let all = scratch().sequence.tracks.first { $0.id == a.trackId }?.clips ?? []
            var pieces: [(remove: Bool, clip: NativeProjectClip)] = []
            for seg in plan.segments {
                let s = (seg.start * f).rounded(), e = (seg.end * f).rounded()
                let m = all.filter { pieceIds.contains($0.id) && $0.startFrame == s && $0.durationFrames == e - s }
                guard m.count == 1 else { return false }
                pieces.append((seg.remove, m[0]))
            }
            let removed = pieces.filter(\.remove).map { NativeProjectClipAddress(sequenceId: sequenceId, trackId: a.trackId, clipId: $0.clip.id) }
            guard !removed.isEmpty, step(removed.count == 1 ? .delete(address: removed[0]) : .deleteMany(removed)) else { return false }
            var next = c.startFrame
            let moves: [NativeProjectClipMove] = pieces.filter { !$0.remove }.compactMap { p in
                defer { next += p.clip.durationFrames }
                return next == p.clip.startFrame ? nil : .init(address: .init(sequenceId: sequenceId, trackId: a.trackId, clipId: p.clip.id),
                                                                destination: .init(trackId: a.trackId, startFrame: next))
            }
            return moves.isEmpty || step(moves.count == 1 ? .move(address: moves[0].address, destination: moves[0].destination) : .moveMany(moves))
        }
        return ok ? plan.removedSeconds : 0
    }
}

/// planSilenceRemoval: map source-time silences onto a clip (timeline seconds) and divide it into keep/remove pieces.
public struct TimelineSilencePlan: Equatable {
    public struct Segment: Equatable { public var start: Double, end: Double, remove: Bool }
    public private(set) var cutTimes: [Double] = []
    public private(set) var removed: [SilenceRange] = []
    public private(set) var segments: [Segment] = []
    public var removedSeconds: Double { removed.reduce(0) { $0 + $1.end - $1.start } }
    static let epsilon = 1e-6

    public init(start clipStart: Double, duration: Double, sourceStart: Double, rate: Double, silences: [SilenceRange]) {
        let dur = max(0, duration), clipEnd = clipStart + dur
        let srcStart = max(0, sourceStart), r = rate.isFinite && rate > 0 ? rate : 1
        let srcEnd = srcStart + dur * r
        let ordered = silences.filter { $0.start.isFinite && $0.end.isFinite }
            .map { SilenceRange(start: max(srcStart, $0.start), end: min(srcEnd, $0.end)) }
            .filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        for s in ordered {
            let m = SilenceRange(start: clipStart + (s.start - srcStart) / r, end: clipStart + (s.end - srcStart) / r)
            if let last = removed.last, m.start <= last.end + Self.epsilon { removed[removed.count - 1].end = max(last.end, m.end) }
            else { removed.append(m) }
        }
        var cuts = Set<Double>(); var cursor = clipStart
        for s in removed {
            if s.start > cursor + Self.epsilon {
                segments.append(.init(start: cursor, end: s.start, remove: false))
                if s.start < clipEnd - Self.epsilon { cuts.insert(s.start) }
            }
            segments.append(.init(start: s.start, end: s.end, remove: true))
            if s.start > clipStart + Self.epsilon { cuts.insert(s.start) }
            if s.end < clipEnd - Self.epsilon { cuts.insert(s.end) }
            cursor = max(cursor, s.end)
        }
        if cursor < clipEnd - Self.epsilon { segments.append(.init(start: cursor, end: clipEnd, remove: false)) }
        cutTimes = cuts.sorted()
    }
}
