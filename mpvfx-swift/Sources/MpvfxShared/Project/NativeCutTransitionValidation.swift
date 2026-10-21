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
// Validation of `track.transitions` (NativeProjectDocumentValidation). Every bad value is a typed issue; nothing is
// clamped. Entries from a newer version of the editor (`v` other than 1, or a kind this editor does not know) are not
// checked beyond being objects with a whole-number `v`: they are kept unchanged and drawn as hard cuts.
import Foundation

/// A clip's place on its track, as the validator reads it from the raw document.
private struct TransitionClipSpan { let start: Double; let duration: Double }

/// What one track's transitions are checked against.
private struct TransitionTrackContext {
    let path: String
    let clips: [String: TransitionClipSpan]
    /// Sides of cuts already taken by a transition ("out:<clip>", "in:<clip>").
    var cuts = Set<String>()
}

/// Clips of a raw track whose id, start and duration are readable (others already have their own issues).
private func transitionClipSpans(_ rawClips: NativeJSONValue?) -> [String: TransitionClipSpan] {
    var spans: [String: TransitionClipSpan] = [:]
    for clip in rawClips?.arrayValue ?? [] {
        guard let id = clip["id"]?.stringValue, isNonNegativeInteger(clip["startFrame"]), isPositiveInteger(clip["durationFrames"]),
              let start = clip["startFrame"]?.numberValue, let duration = clip["durationFrames"]?.numberValue else { continue }
        spans[id] = TransitionClipSpan(start: start, duration: duration)
    }
    return spans
}

/// Checks `track.transitions`; `ids` collects transition ids across the document (they are unique project-wide).
func validateNativeTrackTransitions(_ track: NativeJSONValue, _ trackPath: String, _ ids: inout Set<String>, _ issues: inout Issues) {
    guard let raw = track["transitions"] else { return }
    guard let list = raw.arrayValue else {
        return pushIssue(&issues, .invalidTrack, "\(trackPath).transitions", "Transitions must be an array")
    }
    var context = TransitionTrackContext(path: trackPath, clips: transitionClipSpans(track["clips"]))
    for (index, entry) in list.enumerated() {
        let path = "\(trackPath).transitions[\(index)]"
        guard isKnownTransitionEntry(entry, path, &issues) else { continue }
        requireId(entry["id"], "\(path).id", &issues)
        collectDuplicateId(&ids, entry["id"], "\(path).id", &issues)
        let clips = validateTransitionClips(entry, path, &context, &issues)
        validateTransitionLength(entry, path, clips, &issues)
        validateTransitionStyle(entry, path, &issues)
    }
}

/// True for an entry this editor validates and draws; false (with an issue when it is malformed) otherwise.
private func isKnownTransitionEntry(_ entry: NativeJSONValue, _ path: String, _ issues: inout Issues) -> Bool {
    guard entry.isRecord else {
        pushIssue(&issues, .invalidTransition, path, "Transition must be an object"); return false
    }
    guard isPositiveInteger(entry["v"]) else {
        pushIssue(&issues, .invalidTransition, "\(path).v", "Transition version v must be a positive whole number"); return false
    }
    guard entry["v"] == .number(Double(NativeCutTransition.version)) else { return false }
    guard let kind = entry["kind"]?.stringValue, !kind.isEmpty else {
        pushIssue(&issues, .invalidTransition, "\(path).kind", "Transition kind must be a non-empty string"); return false
    }
    return NativeCutTransitionKind(rawValue: kind) != nil
}

/// The two clips of the cut: both on this track, touching, and the cut not already transitioned.
private func validateTransitionClips(_ entry: NativeJSONValue, _ path: String, _ context: inout TransitionTrackContext,
                                     _ issues: inout Issues) -> [(String, TransitionClipSpan)] {
    var found: [(String, TransitionClipSpan)] = []
    for key in ["fromClipId", "toClipId"] {
        guard let id = entry[key]?.stringValue, !id.isEmpty else {
            pushIssue(&issues, .missingReference, "\(path).\(key)", "Transition \(key) must name a clip"); continue
        }
        guard let span = context.clips[id] else {
            pushIssue(&issues, .missingReference, "\(path).\(key)", "Clip \(id) is not on track \(context.path)"); continue
        }
        found.append((id, span))
    }
    guard found.count == 2 else { return found }
    let (from, to) = (found[0], found[1])
    if from.1.start + from.1.duration != to.1.start {
        pushIssue(&issues, .transitionClipsNotAdjacent, path,
                  "Clips \(from.0) and \(to.0) do not touch: a transition needs the second clip to start where the first ends")
    }
    let outKey = "out:\(from.0)", inKey = "in:\(to.0)"
    if context.cuts.contains(outKey) || context.cuts.contains(inKey) {
        pushIssue(&issues, .duplicateTransition, path, "The cut between \(from.0) and \(to.0) already has a transition")
    }
    context.cuts.insert(outKey); context.cuts.insert(inKey)
    return found
}

/// A positive whole number of frames, no longer than either clip.
private func validateTransitionLength(_ entry: NativeJSONValue, _ path: String, _ clips: [(String, TransitionClipSpan)],
                                      _ issues: inout Issues) {
    guard isPositiveInteger(entry["durationFrames"]), let length = entry["durationFrames"]?.numberValue else {
        return pushIssue(&issues, .invalidTransition, "\(path).durationFrames", "Transition durationFrames must be a finite positive whole number")
    }
    for (id, span) in clips where length > span.duration {
        pushIssue(&issues, .invalidTransition, "\(path).durationFrames",
                  "Transition of \(jsNumberString(length)) frames is longer than clip \(id) (\(jsNumberString(span.duration)) frames)")
    }
}

/// Alignment from the list, colour with the same hex rules as `clip.style`.
private func validateTransitionStyle(_ entry: NativeJSONValue, _ path: String, _ issues: inout Issues) {
    if let alignment = entry["alignment"], alignment.stringValue.flatMap(NativeCutTransitionAlignment.init(rawValue:)) == nil {
        pushIssue(&issues, .invalidTransition, "\(path).alignment", "Transition alignment must be centre, endsAtCut or startsAtCut")
    }
    if let color = entry["color"], color.stringValue.map(isNativeHexColor) != true {
        pushIssue(&issues, .invalidTransition, "\(path).color", "Transition color must be #RGB, #RRGGBB or #RRGGBBAA")
    }
}
