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
// Clip move plans: a clip's new start frame and track for a timeline drag.
import Foundation

public struct NativeTimelineMoveElement: Equatable {
    public var reference: NativeSelectedElementReference
    public var currentTrack: Double
    public init(reference: NativeSelectedElementReference, currentTrack: Double) { self.reference = reference; self.currentTrack = currentTrack }
}

public struct NativeTimelineClipMovePlanInput {
    public var document: NativeProjectDocument; public var element: NativeTimelineMoveElement
    public var requestedStartSeconds: Double; public var requestedTrack: Double
    public init(document: NativeProjectDocument, element: NativeTimelineMoveElement, requestedStartSeconds: Double, requestedTrack: Double) {
        self.document = document; self.element = element; self.requestedStartSeconds = requestedStartSeconds; self.requestedTrack = requestedTrack
    }
}

public enum NativeTimelineClipMovePlanFailureCode: String {
    case unsupportedLaneChange = "unsupported-lane-change", invalidStart = "invalid-start", clipNotFound = "clip-not-found"
    case ambiguousClip = "ambiguous-clip", missingSelectionId = "missing-selection-id", nativeCommandRejected = "native-command-rejected"
}

public struct NativeTimelineLaneDestination: Equatable { public var trackId: String; public var authoredTrack: Double; public var displayTrack: Double }

public struct NativeTimelineClipMovePlan: Equatable {
    public var document: NativeProjectDocument; public var address: NativeProjectClipAddress
    public var sourceFile: String?   // `string | null`
    public var startFrame: Double; public var compatibilityStartSeconds: Double
    public var destination: NativeTimelineLaneDestination
}
public typealias NativeTimelineClipMovePlanResult = Result<NativeTimelineClipMovePlan, NativeTimelinePlanFailureError<NativeTimelineClipMovePlanFailureCode>>
public struct NativeTimelinePlanFailureError<Code: Equatable>: Error, Equatable { public var code: Code; public var message: String }

extension Result {
    public var ok: Bool { if case .success = self { return true }; return false }
    public var value: Success? { if case .success(let v) = self { return v }; return nil }
    public var error: Failure? { if case .failure(let f) = self { return f }; return nil }
}

/// Plan one clip move with native integer frames and explicit lane metadata as the sole authorities.
public func planNativeTimelineClipMove(_ input: NativeTimelineClipMovePlanInput, engine: KeyframeEngine) throws -> NativeTimelineClipMovePlanResult {
    func fail(_ c: NativeTimelineClipMovePlanFailureCode, _ m: String) -> NativeTimelineClipMovePlanResult { .failure(.init(code: c, message: m)) }
    if !input.requestedStartSeconds.isFinite || input.requestedStartSeconds < 0 {
        return fail(.invalidStart, "Native timeline start must be a finite non-negative time")
    }
    let located: NativeLocatedClip
    switch resolveNativeClipSelection(input.document, input.element.reference) {
    case .failure(let f):
        switch f.code {
        case .clipNotFound: return fail(.clipNotFound, f.message)
        case .ambiguousClip: return fail(.ambiguousClip, f.message)
        case .missingSelectionId: return fail(.missingSelectionId, f.message)
        default: return fail(.clipNotFound, f.message)
        }
    case .success(let l): located = l
    }
    let tracks = input.document.sequence.tracks
    guard let sourceTrack = tracks.first(where: { $0.id == located.trackId }), sourceTrack.lane != nil else {
        return fail(.unsupportedLaneChange, "The selected clip has no explicit authored/display native lane mapping")
    }
    let destinationTrack = input.requestedTrack == input.element.currentTrack ? sourceTrack
        : tracks.first { $0.lane?.authoredTrack == input.requestedTrack }
    guard let destinationTrack, let destinationLane = destinationTrack.lane else {
        return fail(.unsupportedLaneChange, "Authored lane \(jsNumberString(input.requestedTrack)) has no mapped compatible native track")
    }
    let sourceFile = (located.clip.binding?.sourceFile).flatMap { $0.isEmpty ? nil : $0 }   // an empty source file counts as none
    let rawSourceFile = located.clip.binding?.sourceFile
    if let sourceFile, let selected = input.element.reference.sourceFile, !selected.isEmpty, selected != sourceFile {
        return fail(.clipNotFound, "Selected source disagrees with the native binding")
    }
    let startFrame = try projectFrameFromSeconds(input.requestedStartSeconds, frameRate: input.document.frameRate)
    let address = NativeProjectClipAddress(sequenceId: input.document.sequence.id, trackId: located.trackId, clipId: located.clip.id)
    let command = try applyNativeProjectClipCommand(input.document, .move(address: address, destination: .init(trackId: destinationTrack.id, startFrame: startFrame)), engine: engine)
    if let f = command.failure { return fail(.nativeCommandRejected, f.message) }
    return .success(.init(document: command.document, address: address, sourceFile: rawSourceFile, startFrame: startFrame,
        compatibilityStartSeconds: (startFrame * input.document.frameRate.denominator) / input.document.frameRate.numerator,
        destination: .init(trackId: destinationTrack.id, authoredTrack: destinationLane.authoredTrack, displayTrack: destinationLane.displayTrack)))
}
