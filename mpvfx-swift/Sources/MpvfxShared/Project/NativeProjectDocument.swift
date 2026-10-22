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
// The native project document: parser, lane lookup and canonical serializer.
// Parse = validate the untyped input, insert the stored defaults, then decode into the Codable model.
// Unknown keys: records copied whole (frameRate, canvas, assets, lane, sourceInFraction, offsetFraction, crop-pivot
// reference, effects and effect.parameters) carry them in input order via NativeSpreadKeys / NativeJSONObject;
// parameter tracks keep unknown keys at every level (NativeParameterTrack / NativeKeyframe spreads). Records rebuilt field by field
// (document, sequence, audio groups, tracks, clips, binding, segments, playbackRate, static values) drop them.
import Foundation

public func parseNativeProjectDocument(_ input: NativeJSONValue, engine: KeyframeEngine? = nil) throws -> NativeProjectDocument {
    let issues = validateNativeProjectDocument(input, engine: engine)
    if !issues.isEmpty { throw NativeProjectDocumentValidationError(issues: issues) }
    var doc = input
    doc["schemaVersion"] = .number(Double(NATIVE_PROJECT_DOCUMENT_SCHEMA_VERSION))
    // One-time migration: "ffmpeg" (a legacy value written by older versions) and a missing field both mean the
    // native timeline.
    doc["mediaEngine"] = .string(NativeMediaEngine.native.rawValue)
    var sequence = doc["sequence"]!
    if var groups = sequence["audioGroups"]?.arrayValue {
        for i in groups.indices {
            if groups[i]["volume"] == nil { groups[i]["volume"] = .number(1) }
            if groups[i]["muted"] == nil { groups[i]["muted"] = .bool(false) }
        }
        sequence["audioGroups"] = .array(groups)
    }
    var tracks = sequence["tracks"]!.arrayValue!
    for t in tracks.indices {
        if tracks[t]["lane"] == nil { tracks[t]["lane"] = try NativeJSONValue.from(defaultTrackLane(t)) }
        var clips = tracks[t]["clips"]!.arrayValue!
        for c in clips.indices {
            // playbackRate is rebuilt as { numerator, denominator }, dropping any other keys.
            let rate = clips[c]["playbackRate"]
            clips[c]["playbackRate"] = .object([
                "numerator": rate?["numerator"] ?? .number(DEFAULT_NATIVE_PLAYBACK_RATE.numerator),
                "denominator": rate?["denominator"] ?? .number(DEFAULT_NATIVE_PLAYBACK_RATE.denominator),
            ])
            if clips[c]["muted"] == nil { clips[c]["muted"] = .bool(false) }
            // No staticParameters default: untouched clips decode to nil (not an empty map), so a clone
            // round-trip preserves "untouched" and replaceMedia can clear authored sizes back to nil.
        }
        tracks[t]["clips"] = .array(clips)
    }
    sequence["tracks"] = .array(tracks)
    doc["sequence"] = sequence
    return try doc.decode(NativeProjectDocument.self)
}

/// Typed convenience: re-validates an in-memory document exactly like the untyped path.
public func parseNativeProjectDocument(_ document: NativeProjectDocument, engine: KeyframeEngine? = nil) throws -> NativeProjectDocument {
    try parseNativeProjectDocument(try NativeJSONValue.from(document), engine: engine)
}

public struct NativeProjectTrackLaneQuery: Equatable {
    public var kind: NativeProjectTrackKind; public var authoredTrack: Double?; public var displayTrack: Double?
    public init(kind: NativeProjectTrackKind, authoredTrack: Double? = nil, displayTrack: Double? = nil) {
        self.kind = kind; self.authoredTrack = authoredTrack; self.displayTrack = displayTrack
    }
}

/// Resolve a track from explicit lane metadata, falling back to the index lane like the parser. IDs are never inspected.
public func findNativeProjectTrackByLane(_ document: NativeProjectDocument, _ query: NativeProjectTrackLaneQuery) -> NativeProjectTrack? {
    let matches = document.sequence.tracks.enumerated().filter { index, track in
        guard track.kind == query.kind else { return false }
        let lane = track.lane ?? defaultTrackLane(index)
        return (query.authoredTrack == nil || lane.authoredTrack == query.authoredTrack) &&
            (query.displayTrack == nil || lane.displayTrack == query.displayTrack)
    }
    return matches.count == 1 ? matches[0].element : nil
}

/// Validate, then write stable JSON: ordered arrays, keys sorted by UTF-16 code unit, 2-space indent, trailing newline.
public func serializeNativeProjectDocument(_ input: NativeJSONValue, engine: KeyframeEngine? = nil) throws -> String {
    jsJSONStringify(canonicalizeNativeJSON(try NativeJSONValue.from(parseNativeProjectDocument(input, engine: engine))), indent: 2) + "\n"
}

/// `canonicalize`: `Object.fromEntries(Object.keys(v).sort()...)`. `.sort()` orders by UTF-16 code unit, then
/// `fromEntries` (like every JS object) puts array-index keys first in ascending order; NativeOrderedMap does the same.
func canonicalizeNativeJSON(_ v: NativeJSONValue) -> NativeJSONValue {
    switch v {
    case .array(let a): return .array(a.map(canonicalizeNativeJSON))
    case .object(let o):
        var r = NativeJSONObject()
        for k in o.keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) { r[k] = canonicalizeNativeJSON(o[k]!) }
        return .object(r)
    default: return v
    }
}
public func serializeNativeProjectDocument(_ document: NativeProjectDocument, engine: KeyframeEngine? = nil) throws -> String {
    try serializeNativeProjectDocument(try NativeJSONValue.from(document), engine: engine)
}
