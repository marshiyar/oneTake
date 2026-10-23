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

public enum TimelineClipKind: String, Sendable { case video, audio, image, element }

/// One undoable edit: the command that reverts it plus the label shown as "Undo <label>".
public struct TimelineHistoryEntry: Equatable {
    public var inverse: NativeProjectClipCommand
    public var label: String
    public var coalesceKey: String?
    public var time: Double
}

/// Document-backed timeline state: the NativeProjectDocument is the source of truth, edits go
/// through applyNativeProjectClipCommand (MpvfxShared), each success pushes its inverse for undo.
public final class TimelineEditor {
    public private(set) var document: NativeProjectDocument
    /// Undo history: labelled entries, consecutive edits sharing a coalesce key
    /// within `coalesceWindow` fold into one entry, at most `maxHistoryEntries` kept.
    public internal(set) var undoStack: [TimelineHistoryEntry] = []
    public internal(set) var redoStack: [TimelineHistoryEntry] = []
    public var maxHistoryEntries = 100
    public var coalesceWindow = 0.3
    /// Clock for coalescing (seconds); injectable for tests.
    public var now: () -> Double = { Date().timeIntervalSince1970 }
    var pendingLabel: String?
    var pendingCoalesceKey: String?
    var pendingCoalesceWindow: Double?
    public internal(set) var lastFailure: NativeProjectClipFailure?
    public internal(set) var lastPropertyFailure: NativeProjectKeyframeFailure?
    public let engine: KeyframeEngine?
    public var onChange: (() -> Void)?
    /// What the last clip edit did to cut transitions ("Removed the transition between …"), nil when it changed none;
    /// `onNotice` hands it to the host's toast.
    public internal(set) var lastNotice: String?
    public var onNotice: ((String) -> Void)?
    /// The undo/redo stacks changed (an edit, undo, redo, a reload); hosts persist them (usePersistentEditHistory).
    public var onHistoryChange: (() -> Void)?
    /// A media file's natural pixel size (default: the size cached on the asset); sizes untouched clips
    /// (nativeClipNaturalLayout). Hosts add sizes they probed for assets that have none cached.
    public var naturalSize: (NativeProjectAsset) -> NativeMediaNaturalSize? = { $0.naturalSize }
    /// The folder relative asset sources resolve against (the open project's); copied clips carry their media as
    /// absolute paths from it, so they paste into another project.
    public var projectDirectory: URL?

    public init(document: NativeProjectDocument, engine: KeyframeEngine? = nil) { self.document = document; self.engine = engine }

    public convenience init(json: String, engine: KeyframeEngine? = nil) throws {
        self.init(document: try parseNativeProjectDocument(try NativeJSONValue.parse(json), engine: engine), engine: engine)
    }

    public var fps: Double { document.frameRate.numerator / max(document.frameRate.denominator, 1e-9) }
    public var sequenceId: String { document.sequence.id }

    /// Tracks in display order (lane.displayTrack, then document order).
    public var tracks: [TimelineTrackModel] {
        let assets = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let f = fps
        return document.sequence.tracks.enumerated()
            .sorted { ($0.element.lane?.displayTrack ?? Double($0.offset), $0.offset) < ($1.element.lane?.displayTrack ?? Double($1.offset), $1.offset) }
            .enumerated().map { display, entry in
                let t = entry.element
                var track = TimelineTrackModel(id: t.id, name: Self.trackName(t, displayNumber: display + 1, assets: assets), kind: t.kind.rawValue, clips: t.clips.map { c in
                    let a = assets[c.assetId]
                    var m = TimelineClipModel(id: c.id, name: c.name ?? a?.name ?? c.assetId, start: c.startFrame / f, duration: c.durationFrames / f,
                                              kind: TimelineClipKind(rawValue: a?.kind.rawValue ?? "element") ?? .element,
                                              keyframes: c.parameterTracks.flatMap { $0.keyframes.map { $0.frame / f } }.sorted(),
                                              effectCount: c.effects.count)
                    m.lanes = Self.lanes(c, fps: f)
                    m.channels = c.parameterTracks.filter { !$0.keyframes.isEmpty }.map {
                        TimelineKeyframeChannel(parameterId: $0.parameterId, group: Self.propertyGroup($0.parameterId).group, frames: $0.keyframes.map(\.frame).sorted(),
                                                eases: Dictionary($0.keyframes.map { ($0.frame, TimelineKeyframeEase($0.outgoing)) }, uniquingKeysWith: { a, _ in a }))
                    }
                    m.effects = c.effects.filter(\.enabled).map { TimelineEffectModel(id: "native:\($0.id)", label: Self.titleCase($0.effectId)) }
                    m.beatTimes = c.visibleBeatFrames.map { $0.timeline / f }
                    m.muted = c.muted
                    m.assetId = c.assetId
                    if let srcFrames = a?.durationFrames, srcFrames > 0 {
                        let rate = c.playbackRate.map { $0.denominator != 0 ? $0.numerator / $0.denominator : 1 } ?? 1
                        m.sourceStartFraction = c.sourceInFrame / srcFrames
                        m.sourceEndFraction = (c.sourceInFrame + c.durationFrames * rate) / srcFrames
                    }
                    m.hidden = c.hidden == true
                    m.audioDetachedFrom = c.audioDetachedFrom
                    m.fxCount = Self.enabledFxNodeCount(c.audioFxChain)
                    let detached = document.sequence.tracks.contains { $0.clips.contains { $0.audioDetachedFrom == c.id } }
                    // The timeline's audio state also accepts a preview `binding` (a DOM binding older documents can carry);
                    // clips inserted here have none, so only the media source is required.
                    m.canDetachAudio = a?.kind == .video && !(a?.source ?? "").isEmpty && !detached
                    m.canMute = !detached
                    return m
                })
                // A track belongs to the group of its first clip carrying one (resolveGroupMembership).
                track.groupId = t.clips.first { $0.audioGroupId?.isEmpty == false }?.audioGroupId
                track.hidden = t.hidden == true
                track.locked = t.locked == true
                track.soloed = t.soloed == true
                track.muted = !t.clips.isEmpty && t.clips.allSatisfy(\.muted)
                return track
            }
    }

    /// Audio groups in first-member order (useTimelineTrackDerivations).
    var groups: [TimelineGroupModel] {
        var order: [String] = []; var members: [String: [String]] = [:]
        for t in tracks { if let g = t.groupId { if members[g] == nil { order.append(g) }; members[g, default: []].append(t.id) } }
        let labels = Dictionary((document.sequence.audioGroups ?? []).map { ($0.id, $0.label ?? $0.id) }, uniquingKeysWith: { a, _ in a })
        let fx = Dictionary((document.sequence.audioGroups ?? []).map { ($0.id, Self.enabledFxNodeCount($0.fxChain)) }, uniquingKeysWith: { a, _ in a })
        return order.map { TimelineGroupModel(id: $0, label: labels[$0] ?? $0, memberTrackIds: members[$0] ?? [], fxCount: fx[$0] ?? 0) }
    }

    /// titleCase: separators to spaces, word starts upper-cased.
    static func titleCase(_ v: String) -> String {
        var out = ""; var atWord = true
        for ch in v {
            let c: Character = (ch == "-" || ch == "_") ? " " : ch
            let isWordChar = c.isLetter || c.isNumber || c == "_"
            out.append(atWord && isWordChar ? Character(c.uppercased()) : c)
            atWord = !isWordChar
        }
        return out.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    /// Native parameter -> timeline property group (one lane per group, in first-seen order): TimelineKeyframeCatalog.
    static func propertyGroup(_ parameterId: String) -> (group: String, label: String) {
        let p = TimelineKeyframeCatalog.property(parameterId)
        return (p.group, p.label)
    }

    static func lanes(_ c: NativeProjectClip, fps: Double) -> [TimelineLaneModel] {
        var out: [TimelineLaneModel] = []
        for t in c.parameterTracks where !t.keyframes.isEmpty {
            let g = TimelineKeyframeCatalog.property(t.parameterId)
            let times = t.keyframes.map { $0.frame / fps }
            if let i = out.firstIndex(where: { $0.group == g.group }) {
                out[i].keyframes = Array(Set(out[i].keyframes + times)).sorted()
            } else { out.append(TimelineLaneModel(group: g.group, label: g.label, keyframes: times.sorted(), kind: g.kind)) }
        }
        return out
    }

    /// TimelineLanes trackLabel: the first clip's label, else "Track N" (1-based display position).
    static func trackName(_ t: NativeProjectTrack, displayNumber: Int, assets: [String: NativeProjectAsset]) -> String {
        if t.id.hasPrefix("track:voice:") { return "Voice" }
        if let c = t.clips.first { return assets[c.assetId]?.name ?? c.assetId }
        return "Track \(displayNumber)"
    }

    /// enabledAudioFxNodes(parseAudioFxChain(raw)).length, parsed lightly: nodes whose `enabled` isn't false.
    /// A missing or unreadable chain counts as empty (parseFxChainOrEmpty).
    /// Memoised by chain text: `tracks` is rebuilt on every stage sync and timeline draw (each playback tick), and
    /// parsing every clip's FX chain JSON each time cost the UI thread more than a frame once chains grew.
    public static func enabledFxNodeCount(_ raw: String?) -> Int {
        guard let raw, !raw.isEmpty else { return 0 }
        fxCountLock.lock()
        if let n = fxCountCache[raw] { fxCountLock.unlock(); return n }
        fxCountLock.unlock()
        let n = parseEnabledFxNodeCount(raw)
        fxCountLock.lock()
        if fxCountCache.count >= 512 { fxCountCache.removeAll(keepingCapacity: true) }
        fxCountCache[raw] = n
        fxCountLock.unlock()
        return n
    }
    private static let fxCountLock = NSLock()
    nonisolated(unsafe) private static var fxCountCache: [String: Int] = [:]

    static func parseEnabledFxNodeCount(_ raw: String) -> Int {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = obj["nodes"] as? [Any] else { return 0 }
        return nodes.reduce(0) { n, node in
            guard let d = node as? [String: Any] else { return n }
            return (d["enabled"] as? Bool) == false ? n : n + 1
        }
    }

    /// Navigable end in seconds: authored composition (or last clip) and every saved marker.
    /// Markers remain reachable after trimming/deleting clips, without rewriting the authored render duration.
    public var duration: Double {
        let contentEnd = document.sequence.durationFrames.flatMap { $0 > 0 ? $0 : nil }
            ?? document.sequence.tracks.flatMap(\.clips).map { $0.startFrame + $0.durationFrames }.max() ?? 0
        let markerEnd = document.sequence.markers?.map(\.time).filter { $0.isFinite && $0 >= 0 }.max() ?? 0
        return max(contentEnd / fps, markerEnd)
    }

    public func address(clipId: String) -> NativeProjectClipAddress? {
        for t in document.sequence.tracks where t.clips.contains(where: { $0.id == clipId }) {
            return NativeProjectClipAddress(sequenceId: sequenceId, trackId: t.id, clipId: clipId)
        }
        return nil
    }

    @discardableResult
    public func apply(_ command: NativeProjectClipCommand) -> Bool {
        if touchesLockedTrack(command) {
            lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "Track is locked"); return false
        }
        let before = document
        do {
            let r = try applyNativeProjectClipCommand(document, command, engine: engine)
            guard case .success(let doc, let inverse) = r else { lastFailure = r.failure; return false }
            // The composition follows its last clip in both directions; undo restores both.
            if let extended = Self.extendingDuration(doc) { document = extended; pushHistory(.restoreDocument(before), defaultLabel: Self.label(for: command)) }
            else { document = doc; pushHistory(inverse, defaultLabel: Self.label(for: command)) }
            reportTransitionChanges(from: before)
            lastFailure = nil
            onChange?(); return true
        } catch { lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "\(error)"); return false }
    }

    /// Commit a document produced outside the clip commands, with its undo inverse.
    public func replaceDocument(_ doc: NativeProjectDocument, inverse: NativeProjectClipCommand) {
        let before = document
        if let resized = Self.extendingDuration(doc) { document = resized; pushHistory(.restoreDocument(before), defaultLabel: "Edit") }
        else { document = doc; pushHistory(inverse, defaultLabel: "Edit") }
        onChange?()
    }

    /// Run `body` so every history entry it records carries `label` (an enclosing call's label wins) (and folds with neighbours
    /// sharing `coalesceKey`, e.g. a slider drag in an inspector field). An interaction with its own unique key can
    /// supply an infinite coalesce window to span a physical key hold; the override ends with this call.
    /// Returns body's result.
    @discardableResult
    public func withHistory<T>(_ label: String, coalesceKey: String? = nil,
                               coalesceWindow: Double? = nil, _ body: () -> T) -> T {
        let saved = (pendingLabel, pendingCoalesceKey, pendingCoalesceWindow)
        // The outermost caller names the entry (an inspector's "Set volume" wraps the op's own label).
        pendingLabel = pendingLabel ?? label; pendingCoalesceKey = pendingCoalesceKey ?? coalesceKey
        pendingCoalesceWindow = pendingCoalesceWindow ?? coalesceWindow
        defer { (pendingLabel, pendingCoalesceKey, pendingCoalesceWindow) = saved }
        return body()
    }

    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    func pushHistory(_ inverse: NativeProjectClipCommand, defaultLabel: String) {
        let t = now()
        if let key = pendingCoalesceKey, let last = undoStack.last, last.coalesceKey == key, t - last.time <= (pendingCoalesceWindow ?? coalesceWindow) {
            // Keep the older inverse: undo returns to the state before the first folded edit.
            undoStack[undoStack.count - 1].time = t
        } else {
            undoStack.append(TimelineHistoryEntry(inverse: inverse, label: pendingLabel ?? defaultLabel, coalesceKey: pendingCoalesceKey, time: t))
            if undoStack.count > maxHistoryEntries { undoStack.removeFirst(undoStack.count - maxHistoryEntries) }
        }
        redoStack.removeAll()
        onHistoryChange?()
    }

    /// The document with sequence.durationFrames set to its last clip end, or nil when unchanged, inferred or empty.
    static func extendingDuration(_ d: NativeProjectDocument) -> NativeProjectDocument? {
        let clips = d.sequence.tracks.flatMap(\.clips)
        guard d.sequence.durationFrames != nil, !clips.isEmpty else { return nil }
        let end = clips.map { $0.startFrame + $0.durationFrames }.max() ?? 0
        guard end != d.sequence.durationFrames else { return nil }
        var out = d; out.sequence.durationFrames = end; return out
    }

    static func label(for command: NativeProjectClipCommand) -> String {
        switch command {
        case .move: "Move clip"
        case .moveMany: "Move clips"
        case .trimIn, .trimOut: "Trim clip"
        case .split: "Split clip"
        case .delete: "Delete clip"
        case .deleteMany: "Delete clips"
        case .slip: "Slip clip"
        case .roll: "Roll edit"
        case .restoreDocument: "Edit"
        }
    }

    /// Replace the document as loaded from disk (an external edit, a media rename): no undo entry, history cleared.
    public func loadDocument(_ doc: NativeProjectDocument) {
        document = doc; undoStack.removeAll(); redoStack.removeAll(); lastFailure = nil; onChange?(); onHistoryChange?()
    }

    @discardableResult public func undo() -> Bool { swapHistory(from: \.undoStack, to: \.redoStack) }
    @discardableResult public func redo() -> Bool { swapHistory(from: \.redoStack, to: \.undoStack) }

    private func swapHistory(from: ReferenceWritableKeyPath<TimelineEditor, [TimelineHistoryEntry]>,
                             to: ReferenceWritableKeyPath<TimelineEditor, [TimelineHistoryEntry]>) -> Bool {
        guard var entry = self[keyPath: from].popLast() else { return false }
        guard let r = try? applyNativeProjectClipCommand(document, entry.inverse, engine: engine), case .success(let doc, let inverse) = r else {
            self[keyPath: from].append(entry); return false
        }
        entry.inverse = inverse; entry.coalesceKey = nil   // a redone/undone entry never folds again
        document = doc; self[keyPath: to].append(entry); onChange?(); onHistoryChange?(); return true
    }
}

public extension TimelineEditor {
    var timelineGroups: [TimelineGroupModel] { groups }

    /// Built-in sample project used when no project file is given (MPVFX_PROJECT).
    static let demoJSON = #"""
    {"schemaVersion":1,"id":"project:demo","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#111111"},
     "assets":[{"id":"asset:a","kind":"video","name":"clip_001.mp4","durationFrames":600},
               {"id":"asset:b","kind":"video","name":"clip_002.mp4","durationFrames":600},
               {"id":"asset:logo","kind":"image","name":"logo.png","durationFrames":900},
               {"id":"asset:music","kind":"audio","name":"music.wav","durationFrames":900}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[
      {"id":"track:v2","kind":"video","lane":{"authoredTrack":2,"displayTrack":0},"clips":[
       {"id":"clip:logo","assetId":"asset:logo","startFrame":15,"durationFrames":90,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
      {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":1},"clips":[
       {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"clip:b","assetId":"asset:b","startFrame":195,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
      {"id":"track:a1","kind":"audio","lane":{"authoredTrack":3,"displayTrack":2},"clips":[
       {"id":"clip:music","assetId":"asset:music","startFrame":0,"durationFrames":330,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """#

    /// Stage elements for the clips active at `time` (placeholder layout: video/image full frame).
    func activeElements(at time: Double) -> [(id: String, name: String, kind: TimelineClipKind)] {
        // Bottom display track draws first; upper tracks composite on top.
        tracks.reversed().filter { !$0.hidden }.flatMap { $0.clips.filter { !$0.hidden && $0.start <= time && time < $0.end && $0.kind != .audio } }
            .map { ($0.id, $0.name, $0.kind) }
    }
}
