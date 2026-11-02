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
// Nested sequences: the root `sequences` list, a clip's `sequenceId`, their validation and the notice for sequences
// written by a newer version of the editor.
import Foundation

/// The size of a nested sequence's own picture, in pixels.
public struct NativeNestedSequenceSize: Codable, Equatable, Sendable {
    public var width: Double; public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// A small timeline stored once beside the main sequence (`document.sequences`); clips refer to it by `sequenceId`, so
/// several clips can share one. Version 1 (`"v": 1`) holds `id`, `name`, `tracks`, `size` and `fps`. A sequence written
/// with another version stays in the document exactly as written (`raw`), is not drawn, and the editor says so once
/// when the project opens (`NativeProjectDocument.undrawnContentNotices`).
public struct NativeNestedSequence: Codable, Equatable, Sendable {
    /// The version this editor reads and writes.
    public static let currentVersion = 1

    public var v: Int
    public var id: String
    public var name: String
    public var tracks: [NativeProjectTrack]
    public var size: NativeNestedSequenceSize
    /// Must equal the project frame rate (other rates inside a nest are refused for now).
    public var fps: RationalFrameRate
    /// Keys this version does not know, kept in input order.
    public var spread = NativeSpreadKeys()
    /// The whole object as written, for a version this editor does not read; nil for version 1.
    public var raw: NativeJSONValue?

    static let known = ["v", "id", "name", "tracks", "size", "fps"]

    public init(id: String, name: String, tracks: [NativeProjectTrack], size: NativeNestedSequenceSize, fps: RationalFrameRate) {
        v = Self.currentVersion; self.id = id; self.name = name; self.tracks = tracks; self.size = size; self.fps = fps
    }

    /// A sequence this editor can read and draw.
    public var isSupported: Bool { raw == nil && v == Self.currentVersion }

    /// The length of the sequence's content: the end of its last clip, in frames.
    public var contentFrames: Double {
        tracks.flatMap(\.clips).map { $0.startFrame + $0.durationFrames }.max() ?? 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        v = try c.req(Int.self, "v")
        guard v == Self.currentVersion else {
            let whole = try NativeJSONValue(from: decoder)
            raw = whole
            id = whole["id"]?.stringValue ?? ""; name = whole["name"]?.stringValue ?? ""
            tracks = []; size = .init(width: 0, height: 0); fps = RationalFrameRate(numerator: 0, denominator: 1)
            return
        }
        id = try c.req(String.self, "id"); name = try c.req(String.self, "name"); tracks = try c.req([NativeProjectTrack].self, "tracks")
        size = try c.req(NativeNestedSequenceSize.self, "size"); fps = try c.req(RationalFrameRate.self, "fps")
        spread = try decodeSpread(decoder, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        if let raw { try raw.encode(to: encoder); return }
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k {
            case "v": try c.put(v, k); case "id": try c.put(id, k); case "name": try c.put(name, k)
            case "tracks": try c.put(tracks, k); case "size": try c.put(size, k); default: try c.put(fps, k)
            }
        }
    }
}

public extension NativeProjectDocument {
    /// The nested sequence with this id (any version).
    func nestedSequence(id: String) -> NativeNestedSequence? { sequences?.first { $0.id == id } }

    /// How many clips of the main sequence and of nested sequences show the sequence `id`.
    func nestedClipCount(sequenceId id: String) -> Int {
        let mine = sequence.tracks.flatMap(\.clips)
        let inner = (sequences ?? []).flatMap { $0.tracks.flatMap(\.clips) }
        return (mine + inner).filter { $0.sequenceId == id }.count
    }

    /// A clip that shows a nested sequence: nothing draws it yet (picture and sound of nested clips arrive with the
    /// preview and export slice), so preview and export leave it out while the document keeps it.
    func isUndrawnNestedClip(_ clip: NativeProjectClip) -> Bool { clip.sequenceId != nil }

    /// The notice for nested sequences written by a newer version of the editor (kept, not drawn); nil when there is none.
    var unsupportedSequencesNotice: String? {
        let n = (sequences ?? []).filter { !$0.isSupported }.count
        guard n > 0 else { return nil }
        return n == 1
            ? "1 nested sequence from a newer version of the editor is kept in the project but not drawn in preview or export."
            : "\(n) nested sequences from a newer version of the editor are kept in the project but not drawn in preview or export."
    }
}

/// Gives the tracks of every nested sequence the stored defaults the main sequence gets on open (lane, playback rate,
/// muted), so they decode like main tracks. Sequences of another version are left untouched.
func normalizeNativeNestedSequences(_ doc: NativeJSONValue) throws -> NativeJSONValue {
    guard var list = doc["sequences"]?.arrayValue else { return doc }
    for s in list.indices where list[s]["v"] == .number(1) {
        guard var tracks = list[s]["tracks"]?.arrayValue else { continue }
        for t in tracks.indices {
            if tracks[t]["lane"] == nil { tracks[t]["lane"] = try NativeJSONValue.from(defaultTrackLane(t)) }
            guard var clips = tracks[t]["clips"]?.arrayValue else { continue }
            for c in clips.indices {
                let rate = clips[c]["playbackRate"]
                clips[c]["playbackRate"] = .object([
                    "numerator": rate?["numerator"] ?? .number(DEFAULT_NATIVE_PLAYBACK_RATE.numerator),
                    "denominator": rate?["denominator"] ?? .number(DEFAULT_NATIVE_PLAYBACK_RATE.denominator),
                ])
                if clips[c]["muted"] == nil { clips[c]["muted"] = .bool(false) }
            }
            tracks[t]["clips"] = .array(clips)
        }
        list[s]["tracks"] = .array(tracks)
    }
    var out = doc
    out["sequences"] = .array(list)
    return out
}

/// Every bad value of `sequences` and of clips' `sequenceId` as a typed issue. A nested sequence's tracks are checked
/// with the same rules as the main sequence (against the project's assets), by validating them as a one-sequence
/// document and moving the issue paths under `sequences[i]`.
func validateNativeNestedSequences(_ input: NativeJSONValue, engine: KeyframeEngine?, _ issues: inout Issues) {
    var known = Set<String>(), clipIds = Set<String>()
    var edges: [String: Set<String>] = [:], supportedIndex: [String: Int] = [:], order: [String] = []
    for track in input["sequence"]?["tracks"]?.arrayValue ?? [] {
        for clip in track["clips"]?.arrayValue ?? [] { if let id = clip["id"]?.stringValue { clipIds.insert(id) } }
    }
    let assets = Dictionary((input["assets"]?.arrayValue ?? []).compactMap { a in a["id"]?.stringValue.map { ($0, a) } },
                            uniquingKeysWith: { first, _ in first })
    let list = input["sequences"]
    var sequences: [NativeJSONValue] = []
    if let list {
        guard let array = list.arrayValue else {
            pushIssue(&issues, .invalidSequence, "sequences", "Sequences must be an array"); return
        }
        sequences = array
        var ids = Set<String>()
        if let main = input["sequence"]?["id"]?.stringValue { ids.insert(main) }
        for (i, s) in sequences.enumerated() {
            let path = "sequences[\(i)]"
            guard s.isRecord else { pushIssue(&issues, .invalidSequence, path, "Sequence must be an object"); continue }
            requireId(s["id"], "\(path).id", &issues)
            collectDuplicateId(&ids, s["id"], "\(path).id", &issues)
            if let id = s["id"]?.stringValue, isNonEmptyString(s["id"]) { known.insert(id) }
        }
    }
    for (i, s) in sequences.enumerated() where s.isRecord {
        let path = "sequences[\(i)]"
        guard isPositiveInteger(s["v"]), let v = s["v"]?.numberValue else {
            pushIssue(&issues, .invalidSequence, "\(path).v", "Sequence version v must be a positive whole number"); continue
        }
        guard v == Double(NativeNestedSequence.currentVersion) else { continue }   // kept as written, not read
        if let id = s["id"]?.stringValue, isNonEmptyString(s["id"]) { order.append(id); supportedIndex[id] = i; edges[id] = [] }
        if !isNonEmptyString(s["name"]) { pushIssue(&issues, .invalidSequence, "\(path).name", "Sequence name must be a non-empty string") }
        if !(s["size"]?.isRecord == true && isPositiveInteger(s["size"]?["width"]) && isPositiveInteger(s["size"]?["height"])) {
            pushIssue(&issues, .invalidSequence, "\(path).size", "Sequence size needs a positive whole width and height")
        }
        var fps: NativeJSONValue?
        if let rate = validateFrameRate(s["fps"], "\(path).fps", &issues) {
            fps = s["fps"]
            if let project = input["frameRate"],
               project["numerator"]?.numberValue != rate.numerator || project["denominator"]?.numberValue != rate.denominator {
                pushIssue(&issues, .sequenceFrameRateMismatch, "\(path).fps", "A nested sequence must run at the project frame rate")
            }
        }
        guard let tracks = s["tracks"]?.arrayValue else {
            pushIssue(&issues, .invalidSequence, "\(path).tracks", "Sequence tracks must be an array"); continue
        }
        var synthetic = input
        synthetic["sequences"] = nil; synthetic["frameRate"] = fps ?? input["frameRate"]
        synthetic["sequence"] = .object(["id": .string("nested"), "name": .string("nested"), "tracks": .array(tracks)])
        for issue in validateNativeProjectDocument(synthetic, engine: engine) where issue.path.hasPrefix("sequence.tracks") {
            var moved = issue; moved.path = path + issue.path.dropFirst("sequence".count)
            issues.append(moved)
        }
        for (t, track) in tracks.enumerated() {
            for (c, clip) in (track["clips"]?.arrayValue ?? []).enumerated() {
                if let id = clip["id"]?.stringValue, !clipIds.insert(id).inserted {
                    pushIssue(&issues, .duplicateId, "\(path).tracks[\(t)].clips[\(c)].id", "Duplicate stable ID \(id)")
                }
            }
        }
    }

    func checkReferences(_ tracks: [NativeJSONValue], _ base: String, _ owner: String?) {
        for (t, track) in tracks.enumerated() {
            for (c, clip) in (track["clips"]?.arrayValue ?? []).enumerated() {
                guard let raw = clip["sequenceId"] else { continue }
                let path = "\(base)[\(t)].clips[\(c)]"
                guard let target = raw.stringValue, isNonEmptyString(raw) else {
                    pushIssue(&issues, .invalidClip, "\(path).sequenceId", "Clip sequenceId must be a non-empty string"); continue
                }
                if let owner { edges[owner, default: []].insert(target) }
                if !known.contains(target) { pushIssue(&issues, .missingReference, "\(path).sequenceId", "Missing nested sequence \(target)") }
                let asset = clip["assetId"]?.stringValue.flatMap { assets[$0] }
                if let asset, asset["kind"]?.stringValue != "element" || clip["text"] != nil || clip["shape"] != nil || clip["generator"] != nil {
                    pushIssue(&issues, .invalidClip, "\(path).sequenceId", "A nested clip needs an element asset and no text, shape or generator")
                }
            }
        }
    }
    checkReferences(input["sequence"]?["tracks"]?.arrayValue ?? [], "sequence.tracks", nil)
    for id in order {
        guard let i = supportedIndex[id] else { continue }
        checkReferences(sequences[i]["tracks"]?.arrayValue ?? [], "sequences[\(i)].tracks", id)
    }
    // A sequence that can reach itself through the clips it holds.
    for id in order {
        var seen = Set<String>(), stack = Array(edges[id] ?? [])
        while let next = stack.popLast() { if seen.insert(next).inserted { stack += Array(edges[next] ?? []) } }
        if seen.contains(id) {
            pushIssue(&issues, .sequenceCycle, "sequences[\(supportedIndex[id]!)]", "Sequence \(id) contains itself")
        }
    }
}
