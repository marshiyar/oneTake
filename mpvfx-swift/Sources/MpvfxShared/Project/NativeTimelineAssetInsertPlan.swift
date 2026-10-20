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
// Asset insert plans: where a dropped or inserted asset lands on the timeline.
import Foundation

public struct NativeTimelineAssetInsertion: Equatable {
    public var assetPath: String; public var assetName: String?
    /// The media asset kinds an insert accepts; `.element` stands in for any other kind and is rejected as unsupported.
    public var kind: NativeProjectAssetKind
    public var sourceFile: String
    /// The exact identity returned by the compatibility insertion adapter.
    public var binding: NativeClipDomBinding
    public var requestedStartSeconds: Double; public var requestedDurationSeconds: Double; public var sourceDurationSeconds: Double
    public var requestedTrack: Double
    public init(assetPath: String, assetName: String? = nil, kind: NativeProjectAssetKind, sourceFile: String, binding: NativeClipDomBinding,
                requestedStartSeconds: Double, requestedDurationSeconds: Double, sourceDurationSeconds: Double, requestedTrack: Double) {
        self.assetPath = assetPath; self.assetName = assetName; self.kind = kind; self.sourceFile = sourceFile; self.binding = binding
        self.requestedStartSeconds = requestedStartSeconds; self.requestedDurationSeconds = requestedDurationSeconds
        self.sourceDurationSeconds = sourceDurationSeconds; self.requestedTrack = requestedTrack
    }
}
public enum NativeTimelineAssetInsertPlanFailureCode: String, Sendable {
    case emptyInsertionSet = "empty-insertion-set", unsupportedKind = "unsupported-kind", invalidAssetPath = "invalid-asset-path"
    case invalidSourceFile = "invalid-source-file", invalidTime = "invalid-time", invalidDuration = "invalid-duration"
    case sourceOutOfBounds = "source-out-of-bounds", invalidTrack = "invalid-track", incompatibleLane = "incompatible-lane"
    case invalidBinding = "invalid-binding", bindingSourceMismatch = "binding-source-mismatch", bindingCollision = "binding-collision"
    case identityCollision = "identity-collision"
}
public struct NativeTimelineAssetInsertPlanFailure: Error, Equatable {
    public var code: NativeTimelineAssetInsertPlanFailureCode; public var message: String; public var insertionIndex: Int?
}
public struct NativeTimelineAssetInsertionTiming: Equatable {
    public var startFrame: Double; public var durationFrames: Double; public var sourceDurationFrames: Double
    public var compatibilityStartSeconds: Double; public var compatibilityDurationSeconds: Double
}
public typealias NativeTimelineAssetInsertionTimingResult = Result<NativeTimelineAssetInsertionTiming, NativeTimelineAssetInsertPlanFailure>
public struct NativeTimelineAssetPlannedInsertion: Equatable {
    public var insertionIndex: Int; public var assetId: String; public var clipId: String; public var trackId: String
    public var startFrame: Double; public var durationFrames: Double; public var sourceDurationFrames: Double
    public var compatibilityStartSeconds: Double; public var compatibilityDurationSeconds: Double; public var binding: NativeClipDomBinding
}
public struct NativeTimelineAssetInsertPlan: Equatable { public var document: NativeProjectDocument; public var insertions: [NativeTimelineAssetPlannedInsertion] }
public typealias NativeTimelineAssetInsertPlanResult = Result<NativeTimelineAssetInsertPlan, NativeTimelineAssetInsertPlanFailure>

private func assetFail<T>(_ c: NativeTimelineAssetInsertPlanFailureCode, _ m: String, _ i: Int? = nil) -> Result<T, NativeTimelineAssetInsertPlanFailure> {
    .failure(.init(code: c, message: m, insertionIndex: i))
}
private func stableIdPart(_ v: String) -> String { "\(v.utf16.count):\(v)" }   // JS length counts UTF-16 code units
private func stableTrackId(_ track: Double, _ kind: NativeProjectTrackKind) -> String { "native-track:\(jsNumberString(track)):\(kind.rawValue)" }
private func nonEmptyText(_ v: String?) -> Bool { v.map { !jsTrimmedIsEmpty($0) } ?? false }
private func bindingIdentity(_ b: NativeClipDomBinding) -> String {
    ["file:\(stableIdPart(b.sourceFile))",
     nonEmptyText0(b.hfId) ? "hf:\(stableIdPart(b.hfId!))" : "",
     nonEmptyText0(b.domId) ? "dom:\(stableIdPart(b.domId!))" : "",
     nonEmptyText0(b.selector) ? "selector:\(stableIdPart(b.selector!))" : "",
     nonEmptyText0(b.selector) ? "index:\(jsNumberString(b.selectorIndex ?? 0))" : ""].filter { !$0.isEmpty }.joined(separator: "|")
}
/// JS truthiness of an optional string (non-empty, whitespace counts).
private func nonEmptyText0(_ v: String?) -> Bool { !(v ?? "").isEmpty }
private func stableClipId(_ b: NativeClipDomBinding) -> String { "native-clip:\(bindingIdentity(b))" }
private func sourceName(_ s: String) -> String {
    let last = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    return last.isEmpty ? s : last
}
private func safeFrame(_ v: Double) -> Bool { isSafeInteger(v) && v >= 0 }
private func trackKindFor(_ k: NativeProjectAssetKind) -> NativeProjectTrackKind { k == .audio ? .audio : .video }
private func bindingKeys(_ b: NativeClipDomBinding) -> [String] {
    var keys: [String] = []
    if nonEmptyText0(b.domId) { keys.append("\(b.sourceFile)\u{0}domId\u{0}\(b.domId!)") }
    if nonEmptyText0(b.hfId) { keys.append("\(b.sourceFile)\u{0}hfId\u{0}\(b.hfId!)") }
    if nonEmptyText0(b.selector) { keys.append("\(b.sourceFile)\u{0}selector\u{0}\(b.selector!)\u{0}\(jsNumberString(b.selectorIndex ?? 0))") }
    return keys
}
private func validBinding(_ b: NativeClipDomBinding) -> Bool {
    if !nonEmptyText(b.sourceFile) { return false }
    let ids = [b.domId, b.hfId, b.selector].compactMap { $0 }
    if ids.isEmpty || ids.contains(where: { !nonEmptyText($0) }) { return false }
    if let i = b.selectorIndex {
        if !nonEmptyText(b.selector) { return false }
        if !isSafeInteger(i) || i < 0 { return false }
    }
    return true
}

/// Resolve editor seconds once to the integer project timebase; compatibility seconds derive back from the frames.
public func quantizeNativeTimelineAssetInsertion(_ document: NativeProjectDocument, requestedStartSeconds: Double, requestedDurationSeconds: Double,
                                                 sourceDurationSeconds: Double) throws -> NativeTimelineAssetInsertionTimingResult {
    if !requestedStartSeconds.isFinite || requestedStartSeconds < 0 { return assetFail(.invalidTime, "Asset start must be a finite non-negative time") }
    if !requestedDurationSeconds.isFinite || requestedDurationSeconds <= 0 { return assetFail(.invalidDuration, "Asset duration must be a finite positive time") }
    if !sourceDurationSeconds.isFinite || sourceDurationSeconds <= 0 { return assetFail(.invalidDuration, "Source duration must be a finite positive time") }
    let r = document.frameRate
    let start = try projectFrameFromSeconds(requestedStartSeconds, frameRate: r)
    let duration = try projectFrameFromSeconds(requestedDurationSeconds, frameRate: r)
    let source = try projectFrameFromSeconds(sourceDurationSeconds, frameRate: r)
    if !safeFrame(start) { return assetFail(.invalidTime, "Asset start exceeds the exact project frame range") }
    if !safeFrame(duration) || duration <= 0 { return assetFail(.invalidDuration, "Asset duration must span at least one project frame") }
    if !safeFrame(source) || source <= 0 { return assetFail(.invalidDuration, "Source duration must span at least one project frame") }
    if duration > source { return assetFail(.sourceOutOfBounds, "Asset timeline duration exceeds its source duration") }
    return .success(.init(startFrame: start, durationFrames: duration, sourceDurationFrames: source,
                          compatibilityStartSeconds: (start * r.denominator) / r.numerator, compatibilityDurationSeconds: (duration * r.denominator) / r.numerator))
}
public func quantizeNativeTimelineAssetInsertion(_ document: NativeProjectDocument, _ i: NativeTimelineAssetInsertion) throws -> NativeTimelineAssetInsertionTimingResult {
    try quantizeNativeTimelineAssetInsertion(document, requestedStartSeconds: i.requestedStartSeconds, requestedDurationSeconds: i.requestedDurationSeconds,
                                             sourceDurationSeconds: i.sourceDurationSeconds)
}

private struct Candidate { var planned: NativeTimelineAssetPlannedInsertion; var input: NativeTimelineAssetInsertion; var trackKind: NativeProjectTrackKind; var canonicalSource: String }

/// Plan a single native revision for one or many inserted assets.
public func planNativeTimelineAssetInsertions(_ document: NativeProjectDocument, insertions: [NativeTimelineAssetInsertion],
                                              engine: KeyframeEngine) throws -> NativeTimelineAssetInsertPlanResult {
    if insertions.isEmpty { return assetFail(.emptyInsertionSet, "A native asset insertion requires at least one asset") }
    var occupiedBindingKeys = Set(document.sequence.tracks.flatMap { $0.clips.flatMap { $0.binding.map(bindingKeys) ?? [] } })
    var occupiedClipIds = Set(document.sequence.tracks.flatMap { $0.clips.map(\.id) })
    var candidates: [Candidate] = []
    for (i, ins) in insertions.enumerated() {
        if ins.kind != .video && ins.kind != .audio && ins.kind != .image {
            return assetFail(.unsupportedKind, "Only video, audio, and image assets can be inserted", i)
        }
        guard nonEmptyText(ins.assetPath), let canonical = nativeMediaSource(ins.assetPath, projectId: document.id), !canonical.isEmpty else {
            return assetFail(.invalidAssetPath, "Asset source must name a file within this project", i)
        }
        if !nonEmptyText(ins.sourceFile) { return assetFail(.invalidSourceFile, "Compatibility source file must be non-empty", i) }
        if !isSafeInteger(ins.requestedTrack) || ins.requestedTrack < 0 { return assetFail(.invalidTrack, "Requested track must be a non-negative integer", i) }
        if !validBinding(ins.binding) { return assetFail(.invalidBinding, "Compatibility insertion did not return an exact binding", i) }
        if ins.binding.sourceFile != ins.sourceFile { return assetFail(.bindingSourceMismatch, "Compatibility binding source does not match its insertion source", i) }
        for key in bindingKeys(ins.binding) {
            if occupiedBindingKeys.contains(key) { return assetFail(.bindingCollision, "Compatibility binding is already owned by another clip", i) }
            occupiedBindingKeys.insert(key)
        }
        let clipId = stableClipId(ins.binding)
        if occupiedClipIds.contains(clipId) { return assetFail(.identityCollision, "Deterministic clip ID \(clipId) already exists", i) }
        occupiedClipIds.insert(clipId)
        let timing: NativeTimelineAssetInsertionTiming
        switch try quantizeNativeTimelineAssetInsertion(document, ins) {
        case .failure(let f): return assetFail(f.code, f.message, i)
        case .success(let t): timing = t
        }
        let trackKind = trackKindFor(ins.kind)
        let laneOwner = document.sequence.tracks.first { $0.lane?.authoredTrack == ins.requestedTrack || $0.lane?.displayTrack == ins.requestedTrack }
        let newLaneKinds = Set(insertions.filter { $0.requestedTrack == ins.requestedTrack }.map { trackKindFor($0.kind) })
        let trackId = laneOwner?.id ?? stableTrackId(ins.requestedTrack, newLaneKinds.count > 1 ? .mixed : trackKind)
        if laneOwner == nil && document.sequence.tracks.contains(where: { $0.id == trackId }) {
            return assetFail(.identityCollision, "Deterministic track ID \(trackId) already exists", i)
        }
        let matching = document.assets.filter { a in a.kind == ins.kind && a.source != nil && nativeMediaSource(a.source!, projectId: document.id) == canonical }
        if matching.count > 1 { return assetFail(.identityCollision, "Multiple assets own the source \(canonical)", i) }
        let existing = matching.first
        let assetId = existing?.id ?? nativeMediaAssetId(ins.kind, canonicalSource: canonical)
        if existing == nil && document.assets.contains(where: { $0.id == assetId }) {
            return assetFail(.identityCollision, "Asset ID \(assetId) is already owned by another or unknown source", i)
        }
        candidates.append(.init(planned: .init(insertionIndex: i, assetId: assetId, clipId: clipId, trackId: trackId, startFrame: timing.startFrame,
            durationFrames: timing.durationFrames, sourceDurationFrames: timing.sourceDurationFrames, compatibilityStartSeconds: timing.compatibilityStartSeconds,
            compatibilityDurationSeconds: timing.compatibilityDurationSeconds, binding: ins.binding), input: ins, trackKind: trackKind, canonicalSource: canonical))
    }
    func diff(_ a: Double, _ b: Double) -> Int { a < b ? -1 : a > b ? 1 : 0 }
    let ordered = jsStableSorted(candidates) { l, r in
        let t = jsLocaleCompare(l.planned.trackId, r.planned.trackId); if t != 0 { return t }
        let s = diff(l.planned.startFrame, r.planned.startFrame); if s != 0 { return s }
        return jsLocaleCompare(l.planned.clipId, r.planned.clipId)
    }
    var assets = document.assets
    var newAssetIds = Set<String>()
    for c in ordered {
        if let idx = assets.firstIndex(where: { $0.id == c.planned.assetId }) {
            if assets[idx].durationFrames < c.planned.sourceDurationFrames { assets[idx].durationFrames = c.planned.sourceDurationFrames }
        } else {
            assets.append(NativeProjectAsset(id: c.planned.assetId, kind: c.input.kind,
                name: nonEmptyText(c.input.assetName) ? c.input.assetName! : sourceName(c.canonicalSource),
                source: c.canonicalSource, durationFrames: c.planned.sourceDurationFrames))
            newAssetIds.insert(c.planned.assetId)
        }
    }
    let existingAssets = assets.filter { !newAssetIds.contains($0.id) }
    let newAssets = jsStableSorted(assets.filter { newAssetIds.contains($0.id) }) { l, r in
        let k = jsLocaleCompare(l.kind.rawValue, r.kind.rawValue); return k != 0 ? k : jsLocaleCompare(l.id, r.id)
    }
    var tracks = document.sequence.tracks
    var newTrackIds = Set<String>()
    for c in ordered {
        var idx = tracks.firstIndex { $0.id == c.planned.trackId }
        if idx == nil {
            tracks.append(NativeProjectTrack(id: c.planned.trackId, kind: c.trackKind,
                lane: .init(authoredTrack: c.input.requestedTrack, displayTrack: c.input.requestedTrack), clips: []))
            newTrackIds.insert(c.planned.trackId); idx = tracks.count - 1
        }
        let t = idx!
        if tracks[t].kind != c.trackKind { tracks[t].kind = .mixed }
        tracks[t].clips.append(NativeProjectClip(id: c.planned.clipId, assetId: c.planned.assetId, binding: c.planned.binding,
            startFrame: c.planned.startFrame, durationFrames: c.planned.durationFrames, sourceInFrame: 0,
            playbackRate: .init(numerator: 1, denominator: 1), muted: false, staticParameters: [:], effects: [], parameterTracks: []))
        tracks[t].clips = jsStableSorted(tracks[t].clips) { l, r in let s = diff(l.startFrame, r.startFrame); return s != 0 ? s : jsLocaleCompare(l.id, r.id) }
    }
    let existingTracks = tracks.filter { !newTrackIds.contains($0.id) }
    let newTracks = jsStableSorted(tracks.filter { newTrackIds.contains($0.id) }) { l, r in
        let a = diff(l.lane?.authoredTrack ?? 0, r.lane?.authoredTrack ?? 0); if a != 0 { return a }
        let k = jsLocaleCompare(l.kind.rawValue, r.kind.rawValue); return k != 0 ? k : jsLocaleCompare(l.id, r.id)
    }
    var next = document
    next.assets = existingAssets + newAssets
    next.sequence.tracks = existingTracks + newTracks
    return .success(.init(document: try parseNativeProjectDocument(next, engine: engine), insertions: candidates.map(\.planned)))
}
