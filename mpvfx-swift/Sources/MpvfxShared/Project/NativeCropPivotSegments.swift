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
// Crop-pivot segments: which rotation intervals a crop gesture's pivot applies to.
import Foundation

private let rotationParameterId = "transform.rotation"

/// Attach the pivot only to rotation intervals touched by this gesture.
/// Returns the input unchanged (same value) when nothing applies.
public func markNativeCropPivotIntervals(_ document: NativeProjectDocument, clipId: String, localFrame: Double, offsetFraction: Vec2Value) -> NativeProjectDocument {
    var changed = false
    var doc = document
    for t in doc.sequence.tracks.indices {
        for c in doc.sequence.tracks[t].clips.indices where doc.sequence.tracks[t].clips[c].id == clipId {
            let clip = doc.sequence.tracks[t].clips[c]
            let keys = clip.parameterTracks.first { $0.parameterId == rotationParameterId }?.keyframes ?? []
            guard let index = keys.firstIndex(where: { $0.frame == localFrame }) else { continue }
            var pairs: [(NativeKeyframe, NativeKeyframe)] = []
            if index > 0 { pairs.append((keys[index - 1], keys[index])) }
            if index + 1 < keys.count { pairs.append((keys[index], keys[index + 1])) }
            if pairs.isEmpty { continue }
            let additions = pairs.map { NativeCropPivotSegment(startRotationKeyId: $0.0.id, endRotationKeyId: $0.1.id, offsetFraction: offsetFraction, reference: nil) }
            let replaced = Set(additions.map { [$0.startRotationKeyId, $0.endRotationKeyId] })
            var frameById: [String: Double] = [:]
            for k in keys { frameById[k.id] = k.frame }   // JS Map: last wins
            let affectedStart = pairs[0].0.frame, affectedEnd = pairs[pairs.count - 1].1.frame
            changed = true
            let kept = (clip.cropPivotSegments ?? []).filter { s in
                if replaced.contains([s.startRotationKeyId, s.endRotationKeyId]) { return false }
                guard let oldStart = frameById[s.startRotationKeyId], let oldEnd = frameById[s.endRotationKeyId] else { return true }
                return oldEnd <= affectedStart || oldStart >= affectedEnd
            }
            doc.sequence.tracks[t].clips[c].cropPivotSegments = kept + additions
        }
    }
    return changed ? doc : document
}

/// A deleted or reordered rotation key cannot leave a dormant marker.
public func validNativeCropPivotSegments(_ segments: [NativeCropPivotSegment]?, tracks: [NativeParameterTrack]) -> [NativeCropPivotSegment]? {
    guard let segments else { return nil }
    var frameById: [String: Double] = [:]
    for k in tracks.first(where: { $0.parameterId == rotationParameterId })?.keyframes ?? [] { frameById[k.id] = k.frame }
    return segments.filter { s in
        guard let start = frameById[s.startRotationKeyId], let end = frameById[s.endRotationKeyId] else { return false }
        return end > start
    }
}

private let geometryParameterIds: Set<String> = [
    "transform.position", "transform.position.x", "transform.position.y",
    "transform.rotation", "transform.scale", "transform.scaleX", "transform.scaleY",
    "layout.width", "layout.height",
]

/// Editing geometry after a slice makes its original interpolation snapshot obsolete.
/// The geometry tracks are compared as decoded values (Equatable).
public func currentNativeCropPivotReferences(_ segments: [NativeCropPivotSegment]?, before: [NativeParameterTrack], after: [NativeParameterTrack]) -> [NativeCropPivotSegment]? {
    guard let segments else { return nil }
    let old = before.filter { geometryParameterIds.contains($0.parameterId) }
    let new = after.filter { geometryParameterIds.contains($0.parameterId) }
    if old == new { return segments }
    return segments.map { var s = $0; s.reference = nil; return s }
}

/// Engine slice creates new boundary keys at a trim/split; relink to them in the rebased frame.
public func rebaseNativeCropPivotSegments(_ clip: NativeProjectClip, rebasedTracks: [NativeParameterTrack], fromFrame: Double, untilFrameExclusive: Double) -> [NativeCropPivotSegment]? {
    guard let segments = clip.cropPivotSegments else { return nil }
    guard let before = clip.parameterTracks.first(where: { $0.parameterId == rotationParameterId }),
          let after = rebasedTracks.first(where: { $0.parameterId == rotationParameterId }) else { return [] }
    var original: [String: Double] = [:]
    for k in before.keyframes { original[k.id] = k.frame }
    var result: [NativeCropPivotSegment] = []
    var seen = Set<[String]>()
    for s in segments {
        guard let oldStart = original[s.startRotationKeyId], let oldEnd = original[s.endRotationKeyId], oldEnd > oldStart else { continue }
        let firstFrame = max(oldStart, fromFrame) - fromFrame
        let lastFrame = min(oldEnd, untilFrameExclusive - 1) - fromFrame
        if lastFrame <= firstFrame { continue }
        guard let first = after.keyframes.first(where: { $0.frame == firstFrame }),
              let last = after.keyframes.first(where: { $0.frame == lastFrame }) else { continue }
        let pair = [first.id, last.id]
        if seen.contains(pair) { continue }
        seen.insert(pair)
        let reference: NativeCropPivotSegment.Reference
        if var r = s.reference { r.frameOffset += fromFrame; reference = r }
        else {
            reference = .init(frameOffset: fromFrame, durationFrames: clip.durationFrames, startRotationKeyId: s.startRotationKeyId,
                              endRotationKeyId: s.endRotationKeyId, parameterTracks: clip.parameterTracks, staticParameters: clip.staticParameters)
        }
        result.append(.init(startRotationKeyId: first.id, endRotationKeyId: last.id, offsetFraction: s.offsetFraction, reference: reference))
    }
    return result
}

/// Clipboard paste regenerates key IDs. Empty mapped IDs are dropped (JS truthiness).
public func remapNativeCropPivotKeyIds(_ segments: [NativeCropPivotSegment]?, keyIdMap: [String: String]) -> [NativeCropPivotSegment]? {
    segments?.compactMap { s in
        guard let a = keyIdMap[s.startRotationKeyId], !a.isEmpty, let b = keyIdMap[s.endRotationKeyId], !b.isEmpty else { return nil }
        return .init(startRotationKeyId: a, endRotationKeyId: b, offsetFraction: s.offsetFraction, reference: s.reference)
    }
}
