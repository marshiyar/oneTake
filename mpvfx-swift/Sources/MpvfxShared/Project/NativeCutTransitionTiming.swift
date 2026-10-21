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
// Cut transitions resolved against their clips: the frames each one covers, the media it borrows from each clip's
// handles, and how the two sides mix at a frame. Preview and export draw from these spans
// (`PreviewComposition`), and live playback and the export mix crossfade the sound with them (`DocumentAudioGraph`),
// so picture and sound agree everywhere.
import Foundation

/// Unused media beyond a clip's in and out points, in timeline frames at the clip's speed. Stills, text and other
/// element clips have unlimited handles.
public struct NativeClipHandles: Equatable, Sendable {
    public var before: Double, after: Double
    public init(before: Double, after: Double) { self.before = before; self.after = after }
    public static let unlimited = NativeClipHandles(before: .infinity, after: .infinity)
}

/// The handles of `clip` given its asset (nil asset: none).
public func nativeClipHandles(_ clip: NativeProjectClip, asset: NativeProjectAsset?) -> NativeClipHandles {
    guard let asset else { return NativeClipHandles(before: 0, after: 0) }
    guard nativeAssetConsumesSourceFrames(asset.kind) else { return .unlimited }
    let rate = clip.playbackRate.map { $0.denominator != 0 && $0.numerator > 0 ? $0.numerator / $0.denominator : 1 } ?? 1
    let sourceIn = sourceFrameValue(NativeSourcePosition(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction))
    let sourceOut = sourceIn + clip.durationFrames * rate
    // A rounding error below a millionth of a frame is not a frame of media.
    let before = (sourceIn / rate + 1e-6).rounded(.down)
    let after = ((asset.durationFrames - sourceOut) / rate + 1e-6).rounded(.down)
    return NativeClipHandles(before: max(0, before), after: max(0, after))
}

/// One clip of a cut and the handles it has.
public struct NativeTransitionSide {
    public var clip: NativeProjectClip, handles: NativeClipHandles
    public init(_ clip: NativeProjectClip, asset: NativeProjectAsset?) { self.clip = clip; handles = nativeClipHandles(clip, asset: asset) }
}

/// The timeline frames [start, end) a transition of `length` frames covers around the cut at `cut`.
public func nativeCutTransitionRange(cut: Double, length: Double, alignment: NativeCutTransitionAlignment) -> (start: Double, end: Double) {
    switch alignment {
    case .centre:
        let before = (length / 2).rounded(.down)
        return (cut - before, cut - before + length)
    case .endsAtCut: return (cut - length, cut)
    case .startsAtCut: return (cut, cut + length)
    }
}

/// The longest transition the two clips allow: no longer than either clip, and for a dissolve no more media than
/// their handles hold on the side the alignment borrows from. A dip borrows nothing.
public func nativeMaxTransitionLength(kind: NativeCutTransitionKind, alignment: NativeCutTransitionAlignment,
                                      from: NativeTransitionSide, to: NativeTransitionSide) -> Double {
    let byClips = min(from.clip.durationFrames, to.clip.durationFrames)
    let fromHandles = from.handles, toHandles = to.handles
    guard kind == .dissolve else { return byClips }
    // The incoming clip shows media before its in point; the outgoing one, after its out point.
    let byHandles: Double
    switch alignment {
    case .centre: byHandles = min(2 * toHandles.before + 1, 2 * fromHandles.after)
    case .endsAtCut: byHandles = toHandles.before
    case .startsAtCut: byHandles = fromHandles.after
    }
    return max(0, min(byClips, byHandles))
}

/// How one side of a transition is drawn at a frame: its opacity is multiplied by `opacity`, and `colorAmount`
/// of the dip colour is laid over its picture.
public struct NativeTransitionMix: Equatable, Sendable {
    public var opacity: Double, colorAmount: Double
    public init(opacity: Double = 1, colorAmount: Double = 0) { self.opacity = opacity; self.colorAmount = colorAmount }
    public static let none = NativeTransitionMix()
}

/// A transition resolved against its clips.
public struct NativeCutTransitionSpan: Equatable, Sendable {
    public var id: String, fromClipId: String, toClipId: String
    public var kind: NativeCutTransitionKind
    /// The dip colour (`#RRGGBB` or `#RRGGBBAA`; black by default).
    public var color: String
    /// Timeline frames [startFrame, endFrame) the transition covers, and the cut inside them.
    public var startFrame: Double, cutFrame: Double, endFrame: Double

    /// Frames the outgoing clip is drawn past its out point (a dissolve's overlap after the cut).
    public var outgoingTail: Double { kind == .dissolve ? endFrame - cutFrame : 0 }
    /// Frames the incoming clip is drawn before its in point (a dissolve's overlap before the cut).
    public var incomingLead: Double { kind == .dissolve ? cutFrame - startFrame : 0 }

    /// Progress of `frame` through [from, to): 0 at `from`, 1 at `to`, linear in frame time.
    static func progress(_ frame: Double, from: Double, to: Double) -> Double {
        guard to > from else { return 1 }
        return min(1, max(0, (frame - from) / (to - from)))
    }

    /// The outgoing clip: a dissolve keeps it at full opacity under the incoming one; a dip lays the colour over
    /// it from none at the start to all of it at the cut.
    public func outgoingMix(atFrame frame: Double) -> NativeTransitionMix {
        guard kind == .dip, cutFrame > startFrame else { return .none }
        return NativeTransitionMix(colorAmount: Self.progress(frame, from: startFrame, to: cutFrame))
    }

    /// The incoming clip: a dissolve fades it up from 0 at the start to 1 at the end; a dip lifts the colour off it
    /// from all of it at the cut to none at the end.
    public func incomingMix(atFrame frame: Double) -> NativeTransitionMix {
        switch kind {
        case .dissolve: return NativeTransitionMix(opacity: Self.progress(frame, from: startFrame, to: endFrame))
        case .dip:
            guard endFrame > cutFrame else { return .none }
            return NativeTransitionMix(colorAmount: 1 - Self.progress(frame, from: cutFrame, to: endFrame))
        }
    }

    /// Gain on the outgoing clip's sound at `frame` (fractional): an equal-power fade out over the dissolve, or
    /// over the dip's first part (up to the cut).
    public func outgoingGain(atFrame frame: Double) -> Double {
        let end = kind == .dissolve ? endFrame : cutFrame
        guard end > startFrame else { return 1 }
        return cos(Self.progress(frame, from: startFrame, to: end) * .pi / 2)
    }

    /// Gain on the incoming clip's sound at `frame`: an equal-power fade in over the dissolve, or over the dip's
    /// second part (from the cut).
    public func incomingGain(atFrame frame: Double) -> Double {
        let start = kind == .dissolve ? startFrame : cutFrame
        guard endFrame > start else { return 1 }
        return sin(Self.progress(frame, from: start, to: endFrame) * .pi / 2)
    }
}

/// The transitions a clip takes part in: `incoming` where it is the clip after the cut, `outgoing` where it is
/// the clip before it.
public struct NativeClipTransitions: Equatable, Sendable {
    public var incoming: NativeCutTransitionSpan?
    public var outgoing: NativeCutTransitionSpan?
    public init(incoming: NativeCutTransitionSpan? = nil, outgoing: NativeCutTransitionSpan? = nil) {
        self.incoming = incoming; self.outgoing = outgoing
    }
    /// Frames drawn before the clip's start (handle media).
    public var lead: Double { incoming?.incomingLead ?? 0 }
    /// Frames drawn after the clip's end (handle media).
    public var tail: Double { outgoing?.outgoingTail ?? 0 }
}

/// Every transition preview and export draw, by clip id. A transition is drawn when its entry is known
/// (`NativeCutTransition.isKnown`), its track and both clips are shown, the clips touch, and its length fits both
/// clips and (for a dissolve) their handles; any other entry is a hard cut.
public func nativeCutTransitionSpans(_ document: NativeProjectDocument) -> [String: NativeClipTransitions] {
    let assets = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var out: [String: NativeClipTransitions] = [:]
    for track in document.sequence.tracks where track.hidden != true {
        let clips = Dictionary(track.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for entry in track.cutTransitions {
            guard let span = resolveNativeCutTransition(entry, clips: clips, assets: assets) else { continue }
            out[span.fromClipId, default: NativeClipTransitions()].outgoing = span
            out[span.toClipId, default: NativeClipTransitions()].incoming = span
        }
    }
    return out
}

/// The span of one entry, or nil when it is drawn as a hard cut.
func resolveNativeCutTransition(_ entry: NativeCutTransition, clips: [String: NativeProjectClip],
                                assets: [String: NativeProjectAsset]) -> NativeCutTransitionSpan? {
    guard entry.isKnown, let kind = entry.kind, let alignment = entry.alignment, let id = entry.id,
          let from = entry.fromClipId.flatMap({ clips[$0] }), let to = entry.toClipId.flatMap({ clips[$0] }),
          from.hidden != true, to.hidden != true, let length = entry.durationFrames, length >= 1,
          from.startFrame + from.durationFrames == to.startFrame else { return nil }
    let limit = nativeMaxTransitionLength(kind: kind, alignment: alignment, from: NativeTransitionSide(from, asset: assets[from.assetId]),
                                          to: NativeTransitionSide(to, asset: assets[to.assetId]))
    guard length <= limit else { return nil }
    let range = nativeCutTransitionRange(cut: to.startFrame, length: length, alignment: alignment)
    return NativeCutTransitionSpan(id: id, fromClipId: from.id, toClipId: to.id, kind: kind,
                                   color: entry.color ?? NativeCutTransition.defaultDipColor,
                                   startFrame: range.start, cutFrame: to.startFrame, endFrame: range.end)
}
