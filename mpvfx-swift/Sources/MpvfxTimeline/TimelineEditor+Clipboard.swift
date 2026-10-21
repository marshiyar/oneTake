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
    /// Copies only a visual clip's authored color grade. Unlike the clip clipboard this never carries geometry,
    /// timing, or media, and therefore can safely be applied to clips which play another asset.
    func copyGrade(_ clipId: String) -> TimelineGradeClipboard? {
        guard let clip = clip(clipId)?.clip,
              let kind = document.assets.first(where: { $0.id == clip.assetId })?.kind,
              kind == .video || kind == .image,
              let effect = clip.effects.first(where: { $0.effectId == "color-grading" }) else { return nil }
        let mapped = TimelineClipboard.mapLuts(clip) { TimelineClipboard.absolute($0, in: projectDirectory) }
        return TimelineGradeClipboard(projectDirectory: projectDirectory?.standardizedFileURL.path,
                                      effect: mapped.effects.first { $0.effectId == "color-grading" } ?? effect)
    }

    /// External LUT files needed by a grade paste. The host imports these before the document is changed.
    func filesToImport(_ board: TimelineGradeClipboard) -> [String] {
        guard let source = board.lutSource else { return [] }
        let absolute = TimelineClipboard.absolute(source, in: projectDirectory)
        return HostPath.isAbsolute(absolute) && TimelineClipboard.relative(absolute, in: projectDirectory) == absolute ? [absolute] : []
    }

    /// Replaces the color grade on all selected visual clips in one undo step. Audio clips are deliberately skipped.
    @discardableResult
    func pasteGrade(_ board: TimelineGradeClipboard, onto ids: Set<String>) -> TimelineGradePasteResult? {
        let selected = document.sequence.tracks.flatMap { track in track.clips.filter { ids.contains($0.id) }.map { (track, $0) } }
        let kinds = Dictionary(document.assets.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let visual = selected.filter { kinds[$0.1.assetId] == .video || kinds[$0.1.assetId] == .image }
        let skipped = selected.count - visual.count
        guard !visual.isEmpty else {
            lastFailure = .init(code: .incompatibleDestination, message: "Select at least one video or image clip to paste a grade")
            return nil
        }
        guard !visual.contains(where: { $0.0.locked == true }) else {
            lastFailure = .init(code: .documentMismatch, message: "Track is locked")
            return nil
        }
        var d = document
        let targetIds = Set(visual.map { $0.1.id })
        for ti in d.sequence.tracks.indices {
            for ci in d.sequence.tracks[ti].clips.indices where targetIds.contains(d.sequence.tracks[ti].clips[ci].id) {
                var effect = board.effect
                effect = TimelineGradeClipboard.mapLut(effect) {
                    TimelineClipboard.relative(TimelineClipboard.absolute($0, in: projectDirectory), in: projectDirectory)
                }
                let existing = d.sequence.tracks[ti].clips[ci].effects.firstIndex { $0.effectId == "color-grading" }
                if let existing { effect.id = d.sequence.tracks[ti].clips[ci].effects[existing].id; d.sequence.tracks[ti].clips[ci].effects[existing] = effect }
                else { d.sequence.tracks[ti].clips[ci].effects.append(effect) }
            }
        }
        guard withHistory("Paste grade", { apply(.restoreDocument(d)) }) else { return nil }
        lastFailure = nil
        return TimelineGradePasteResult(pasted: visual.count, skippedAudio: skipped)
    }

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

    /// Copies the clips `ids` (effects, keyframes, audio FX and all) with the assets they play. Nil when none exist.
    func copyClips(_ ids: Set<String>) -> TimelineClipboard? {
        let order = displayTrackIds
        var items: [TimelineClipboard.Item] = []
        for t in document.sequence.tracks {
            for c in t.clips where ids.contains(c.id) {
                let clip = TimelineClipboard.mapLuts(c) { TimelineClipboard.absolute($0, in: projectDirectory) }
                items.append(.init(trackId: t.id, trackKind: t.kind, trackRow: order.firstIndex(of: t.id) ?? 0, clip: clip))
            }
        }
        if items.isEmpty { return nil }
        let used = Set(items.map(\.clip.assetId))
        let assets = document.assets.filter { used.contains($0.id) }.map { a -> NativeProjectAsset in
            var a = a; a.source = a.source.map { TimelineClipboard.absolute($0, in: projectDirectory) }; return a
        }
        return TimelineClipboard(projectId: document.id, projectDirectory: projectDirectory?.standardizedFileURL.path,
                                 frameRate: document.frameRate, items: items, assets: assets)
    }

    /// The files a paste of `board` would point at from outside this project: media it would add as new assets and
    /// the LUTs of its color grades, as absolute paths. A host copies them in first (TimelineController.importForPaste)
    /// and pastes `board.rebased(...)`, because export only reads media inside the project.
    func filesToImport(_ board: TimelineClipboard) -> [String] {
        var out: [String] = []
        func add(_ src: String) {
            let abs = TimelineClipboard.absolute(src, in: projectDirectory)
            if HostPath.isAbsolute(abs), TimelineClipboard.relative(abs, in: projectDirectory) == abs, !out.contains(abs) { out.append(abs) }
        }
        for a in board.assets where reusedAsset(a) == nil { a.source.map(add) }
        for item in board.items { _ = TimelineClipboard.mapLuts(item.clip) { add($0); return $0 } }
        return out
    }

    /// This project's asset a copied asset maps to: the same id playing the same file, else any asset of its kind
    /// playing that file. Ids alone are not enough: a copied project folder keeps its document and asset ids.
    internal func reusedAsset(_ a: NativeProjectAsset) -> String? {
        let src = a.source.map { TimelineClipboard.absolute($0, in: projectDirectory) }
        func same(_ b: NativeProjectAsset) -> Bool { b.kind == a.kind && b.source.map { TimelineClipboard.absolute($0, in: projectDirectory) } == src }
        if let b = document.assets.first(where: { $0.id == a.id }), same(b) { return b.id }
        guard src != nil else { return nil }
        return document.assets.first(where: same)?.id
    }

    /// Pastes at `time` (the earliest copied clip lands there, relative offsets kept); one undo step ("Paste").
    ///
    /// Tracks: with `onto` nil and the clips copied from this project, each clip goes back to the track it came from.
    /// Otherwise the topmost copied track lands on `onto` (nil: the first track of its kind) and the others keep their
    /// row distance from it; a row of the wrong kind or past the last track moves the clips to the next track of their
    /// kind below it, and a new track at the bottom when there is none. A locked destination refuses the paste.
    ///
    /// Media: an asset of this project playing the same file is reused, otherwise the copied asset is added (its
    /// source as an absolute path). Clips get fresh ids and no preview binding; an audio group this project lacks is
    /// dropped, and a detached-audio link follows its video only when the video is pasted with it. Clips copied at
    /// another frame rate are refused. Returns the new clip ids (empty on refusal, with `lastFailure` set).
    @discardableResult
    func paste(_ board: TimelineClipboard, at time: Double, onto anchor: String? = nil) -> [String] {
        func refuse(_ message: String) -> [String] { lastFailure = .init(code: .documentMismatch, message: message); return [] }
        guard let first = board.items.map(\.clip.startFrame).min() else { return [] }
        guard board.frameRate.numerator * document.frameRate.denominator == document.frameRate.numerator * board.frameRate.denominator else {
            return refuse("These clips were copied from a project at another frame rate and cannot be pasted here")
        }
        var d = document
        var order = displayTrackIds
        // A copied project folder keeps its document id, so the folder decides too.
        let sameProject = board.projectId == d.id && board.projectDirectory == projectDirectory?.standardizedFileURL.path

        // Assets: one of this project's playing the same file, else a new asset (project-relative when the file is
        // inside this project, e.g. after importForPaste copied it in).
        var assetIds: [String: String] = [:]
        for a in board.assets {
            if let same = reusedAsset(a) { assetIds[a.id] = same; continue }
            var added = a
            added.id = TimelineClipboard.freshId(a.id, taken: Set(d.assets.map(\.id)))
            added.source = a.source.map { TimelineClipboard.relative(TimelineClipboard.absolute($0, in: projectDirectory), in: projectDirectory) }
            d.assets.append(added)
            assetIds[a.id] = added.id
        }

        // Tracks: source track id -> destination track id.
        let sourceRows = Dictionary(board.items.map { ($0.trackId, ($0.trackRow, $0.trackKind)) }, uniquingKeysWith: { a, _ in a })
        let sourceTracks = sourceRows.sorted { $0.value.0 < $1.value.0 }
        var destination: [String: String] = [:]
        // A mixed track takes clips of any kind, as clip insert and move allow.
        func accepts(_ id: String, _ kind: NativeProjectTrackKind) -> Bool {
            d.sequence.tracks.first { $0.id == id }.map { $0.kind == kind || $0.kind == .mixed } ?? false
        }
        if anchor == nil && sameProject && sourceTracks.allSatisfy({ s in accepts(s.key, s.value.1) }) {
            for s in sourceTracks { destination[s.key] = s.key }
        } else {
            let top = sourceTracks[0]
            let locked = { (id: String) in d.sequence.tracks.first { $0.id == id }?.locked == true }
            let anchorRow: Int
            if let anchor {
                guard let row = order.firstIndex(of: anchor) else { return refuse("Track \(anchor) was not found") }
                if locked(anchor) { return refuse("Track is locked") }   // pasting onto a locked track, never around it
                anchorRow = row
            } else {
                anchorRow = order.firstIndex { accepts($0, top.value.1) } ?? order.count
            }
            var used = Set<String>()
            for s in sourceTracks {
                let want = s.value.1
                let row = anchorRow + (s.value.0 - top.value.0)
                if let id = order.indices.filter({ $0 >= row }).map({ order[$0] }).first(where: { accepts($0, want) && !used.contains($0) }) {
                    destination[s.key] = id
                } else {
                    destination[s.key] = Self.appendTrack(&d, kind: want, order: &order, at: nil)
                }
                used.insert(destination[s.key]!)
            }
        }
        if destination.values.contains(where: { id in d.sequence.tracks.contains { $0.id == id && $0.locked == true } }) {
            return refuse("Track is locked")
        }

        // Clips: fresh ids first, so detached-audio links can follow their pasted video.
        let base = (time * fps).rounded()
        var taken = Set(d.sequence.tracks.flatMap(\.clips).map(\.id))
        var newIds: [String: String] = [:]
        for item in board.items {
            let id = TimelineClipboard.freshId(item.clip.id, taken: taken)
            taken.insert(id); newIds[item.clip.id] = id
        }
        let groups = Set((d.sequence.audioGroups ?? []).map(\.id))
        for item in board.items {
            let ti = d.sequence.tracks.firstIndex { $0.id == destination[item.trackId] }!
            var c = item.clip
            c.id = newIds[item.clip.id]!
            c.startFrame = base + (item.clip.startFrame - first)
            c.assetId = assetIds[item.clip.assetId]!
            c.binding = nil
            c = TimelineClipboard.mapLuts(c) { TimelineClipboard.relative(TimelineClipboard.absolute($0, in: projectDirectory), in: projectDirectory) }
            if let g = c.audioGroupId, !groups.contains(g) { c.audioGroupId = nil }
            c.audioDetachedFrom = c.audioDetachedFrom.flatMap { newIds[$0] }
            d.sequence.tracks[ti].clips.append(c)
            d.sequence.tracks[ti].clips.sort { $0.startFrame < $1.startFrame }
        }
        guard withHistory("Paste", { apply(.restoreDocument(d)) }) else { return [] }
        return board.items.map { newIds[$0.clip.id]! }
    }
}

public struct TimelineGradePasteResult: Equatable, Sendable {
    public let pasted: Int
    public let skippedAudio: Int
    public var message: String {
        "Grade pasted on \(pasted) clip\(pasted == 1 ? "" : "s")" +
        (skippedAudio == 0 ? "" : ", \(skippedAudio) audio clip\(skippedAudio == 1 ? "" : "s") skipped")
    }
}

/// The in-process grade clipboard. LUT paths are made absolute when copied, just like the clip clipboard.
public struct TimelineGradeClipboard: Equatable, Sendable {
    public var projectDirectory: String?
    public var effect: NativeClipEffect

    public var lutSource: String? {
        guard let lut = effect.parameters?["lut"] else { return nil }
        if case .string(let source) = lut { return source }
        if case .object(let object) = lut, case .string(let source)? = object["src"] { return source }
        return nil
    }

    static func mapLut(_ effect: NativeClipEffect, _ transform: (String) -> String) -> NativeClipEffect {
        var effect = effect
        guard var parameters = effect.parameters else { return effect }
        func mapped(_ source: String) -> String { source.contains(":") && !HostPath.isAbsolute(source) ? source : transform(source) }
        switch parameters["lut"] {
        case .string(let source)?: parameters["lut"] = .string(mapped(source))
        case .object(var lut)?:
            if case .string(let source)? = lut["src"] { lut["src"] = .string(mapped(source)); parameters["lut"] = .object(lut) }
        default: break
        }
        effect.parameters = parameters
        return effect
    }

    public func rebased(_ imported: [String: String]) -> TimelineGradeClipboard {
        var copy = self
        copy.effect = Self.mapLut(effect) { imported[$0] ?? $0 }
        return copy
    }
}

/// What ⌘C / ⌘X keep: the clips as they were when copied, with their tracks' kinds and rows and the assets they play
/// (sources made absolute), so a paste works on other tracks and in another project.
public struct TimelineClipboard: Equatable {
    public struct Item: Equatable {
        public var trackId: String, trackKind: NativeProjectTrackKind
        /// The track's display row in the copied-from project.
        public var trackRow: Int
        public var clip: NativeProjectClip
    }
    public var projectId: String
    /// The copied-from project's folder (standardized path); nil when it had none.
    public var projectDirectory: String?
    public var frameRate: RationalFrameRate
    public var items: [Item]
    public var assets: [NativeProjectAsset]

    /// `source` as an absolute path: relative sources resolve against `dir`; without one they stay as written.
    static func absolute(_ source: String, in dir: URL?) -> String {
        guard let dir, !HostPath.isAbsolute(source) else { return source }
        return dir.appendingPathComponent(source).path
    }

    /// `path` relative to `dir` when it lies inside it, else unchanged.
    static func relative(_ path: String, in dir: URL?) -> String {
        guard let dir, HostPath.isAbsolute(path) else { return path }
        let root = HostPath.slashes(dir.standardizedFileURL.path), p = HostPath.slashes(path)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return p.hasPrefix(prefix) && p.count > prefix.count ? String(p.dropFirst(prefix.count)) : path
    }

    /// The clip with `transform` applied to the `lut.src` of each color grade (a project-relative or absolute path;
    /// URLs are left alone).
    static func mapLuts(_ clip: NativeProjectClip, _ transform: (String) -> String) -> NativeProjectClip {
        var clip = clip
        for i in clip.effects.indices where clip.effects[i].effectId == "color-grading" {   // ColorGrading.effectId
            guard var params = clip.effects[i].parameters else { continue }
            func mapped(_ s: String) -> String { s.contains(":") && !HostPath.isAbsolute(s) ? s : transform(s) }
            switch params["lut"] {
            case .string(let s)?: params["lut"] = .string(mapped(s))
            case .object(var l)?:
                if case .string(let s)? = l["src"] { l["src"] = .string(mapped(s)); params["lut"] = .object(l) }
            default: continue
            }
            clip.effects[i].parameters = params
        }
        return clip
    }

    /// The board with the files `imported` maps (absolute path -> its copy in the destination, relative or absolute)
    /// swapped in for its media and LUT sources.
    public func rebased(_ imported: [String: String]) -> TimelineClipboard {
        var b = self
        for i in b.assets.indices { if let s = b.assets[i].source, let to = imported[s] { b.assets[i].source = to } }
        for i in b.items.indices { b.items[i].clip = Self.mapLuts(b.items[i].clip) { imported[$0] ?? $0 } }
        return b
    }

    /// `<id>-copy`, then `<id>-copy2`, ... until it is not in `taken`.
    static func freshId(_ id: String, taken: Set<String>) -> String {
        var n = 1, out = "\(id)-copy"
        while taken.contains(out) { n += 1; out = "\(id)-copy\(n)" }
        return out
    }
}
