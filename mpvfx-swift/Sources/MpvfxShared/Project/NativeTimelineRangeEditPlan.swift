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
// Range edit plans: a clip's new start and duration for a timeline trim or move.
import Foundation

public enum NativeTimelineRangeEditKind: String { case trimIn = "trim-in", trimOut = "trim-out" }

public struct NativeTimelineCompatibilityRange: Equatable {
    /// Exact native-frame-derived decimals used only by the transitional HTML mirror.
    public var start: String; public var duration: String; public var sourceOffset: String
}
public enum NativeTimelineRangeEditPlanFailureCode: String {
    case invalidRange = "invalid-range", noChange = "no-change", unsupportedRangeChange = "unsupported-range-change"
    case missingSelectionId = "missing-selection-id", clipNotFound = "clip-not-found", ambiguousClip = "ambiguous-clip"
    case bindingSourceMismatch = "binding-source-mismatch", nativeCommandRejected = "native-command-rejected"
}
public struct NativeTimelineRangeEditPlanFailure: Error, Equatable {
    public var code: NativeTimelineRangeEditPlanFailureCode; public var message: String; public var nativeCode: NativeProjectClipFailureCode?
}
public struct NativeTimelineRangeEditPlan: Equatable {
    public var kind: NativeTimelineRangeEditKind; public var document: NativeProjectDocument; public var address: NativeProjectClipAddress
    public var sourceFile: String?; public var startFrame: Double; public var durationFrames: Double; public var endFrameExclusive: Double
    public var sourceInFrame: Double; public var sourceInFraction: NativePlaybackRate?; public var compatibility: NativeTimelineCompatibilityRange
}
public typealias NativeTimelineRangeEditPlanResult = Result<NativeTimelineRangeEditPlan, NativeTimelineRangeEditPlanFailure>

func compatibilitySeconds(_ frame: Double, _ r: RationalFrameRate) -> String { jsNumberString((frame * r.denominator) / r.numerator) }

/// Plan one native-canonical range edit from the start/duration the resize surface emits; exactly one boundary may move.
public func planNativeTimelineRangeEdit(_ document: NativeProjectDocument, element: NativeSelectedElementReference,
                                        requestedStartSeconds: Double, requestedDurationSeconds: Double,
                                        engine: KeyframeEngine) throws -> NativeTimelineRangeEditPlanResult {
    func fail(_ c: NativeTimelineRangeEditPlanFailureCode, _ m: String, _ n: NativeProjectClipFailureCode? = nil) -> NativeTimelineRangeEditPlanResult {
        .failure(.init(code: c, message: m, nativeCode: n))
    }
    if !requestedStartSeconds.isFinite || requestedStartSeconds < 0 || !requestedDurationSeconds.isFinite || requestedDurationSeconds <= 0 {
        return fail(.invalidRange, "Native timeline range must have a finite start and positive duration")
    }
    // Rounding cannot fail; nothing to map.
    let r = document.frameRate
    let startFrame = jsMathRound(requestedStartSeconds * r.numerator / r.denominator)
    let durationFrames = jsMathRound((requestedStartSeconds + requestedDurationSeconds) * r.numerator / r.denominator) - startFrame
    let endFrameExclusive = startFrame + durationFrames
    if durationFrames <= 0 || !isSafeInteger(startFrame) || !isSafeInteger(durationFrames) || !isSafeInteger(endFrameExclusive) {
        return fail(.invalidRange, "Native timeline range must resolve to safe integral frames")
    }
    let located: NativeLocatedClip
    switch resolveNativeClipSelection(document, element) {
    case .failure(let f):
        switch f.code {
        case .missingSelectionId: return fail(.missingSelectionId, f.message)
        case .ambiguousClip: return fail(.ambiguousClip, f.message)
        default: return fail(.clipNotFound, f.message)
        }
    case .success(let l): located = l
    }
    let clip = located.clip
    let binding = clip.binding
    if let b = binding, let s = element.sourceFile, !s.isEmpty, b.sourceFile != s {
        return fail(.bindingSourceMismatch, "Native clip \(clip.id) has no exact compatibility binding")
    }
    let startChanged = startFrame != clip.startFrame
    let endChanged = endFrameExclusive != clip.startFrame + clip.durationFrames
    if !startChanged && !endChanged { return fail(.noChange, "Native timeline range is unchanged") }
    if startChanged == endChanged { return fail(.unsupportedRangeChange, "A native timeline range edit must move exactly one clip boundary") }
    let kind: NativeTimelineRangeEditKind = startChanged ? .trimIn : .trimOut
    let address = NativeProjectClipAddress(sequenceId: document.sequence.id, trackId: located.trackId, clipId: clip.id)
    let command = try applyNativeProjectClipCommand(document, kind == .trimIn ? .trimIn(address: address, startFrame: startFrame)
                                                                            : .trimOut(address: address, endFrameExclusive: endFrameExclusive), engine: engine)
    if let f = command.failure { return fail(.nativeCommandRejected, f.message, f.code) }
    guard let u = command.document.sequence.tracks.first(where: { $0.id == address.trackId })?.clips.first(where: { $0.id == address.clipId }) else {
        return fail(.nativeCommandRejected, "Native clip \(clip.id) disappeared during range edit")
    }
    return .success(.init(kind: kind, document: command.document, address: address, sourceFile: binding?.sourceFile,
        startFrame: u.startFrame, durationFrames: u.durationFrames, endFrameExclusive: u.startFrame + u.durationFrames,
        sourceInFrame: u.sourceInFrame, sourceInFraction: u.sourceInFraction,
        compatibility: .init(start: compatibilitySeconds(u.startFrame, r), duration: compatibilitySeconds(u.durationFrames, r),
            sourceOffset: compatibilitySeconds(sourceFrameValue(.init(sourceInFrame: u.sourceInFrame, sourceInFraction: u.sourceInFraction)), r))))
}
