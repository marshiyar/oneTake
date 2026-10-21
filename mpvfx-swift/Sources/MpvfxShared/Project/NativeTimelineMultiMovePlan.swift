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
// Multi-clip move plans: one timeline drag of several selected clips.
import Foundation

public struct NativeTimelineMultiMoveChange: Equatable {
    public var element: NativeSelectedElementReference; public var requestedStartSeconds: Double
    /// Authored compatibility lane. nil retains the clip's native track.
    public var destinationAuthoredTrack: Double?
    public init(element: NativeSelectedElementReference, requestedStartSeconds: Double, destinationAuthoredTrack: Double? = nil) {
        self.element = element; self.requestedStartSeconds = requestedStartSeconds; self.destinationAuthoredTrack = destinationAuthoredTrack
    }
}
public struct NativeTimelineMultiMovePlannedMove: Equatable {
    public var address: NativeProjectClipAddress; public var sourceFile: String?; public var binding: NativeClipDomBinding?
    public var startFrame: Double; public var compatibilityStartSeconds: Double; public var destination: NativeTimelineLaneDestination
}
public enum NativeTimelineMultiMovePlanFailureCode: String, Sendable {
    case emptyChangeSet = "empty-change-set", invalidStart = "invalid-start", missingSelectionId = "missing-selection-id"
    case clipNotFound = "clip-not-found", ambiguousClip = "ambiguous-clip", duplicateClip = "duplicate-clip", unboundClip = "unbound-clip"
    case bindingSourceMismatch = "binding-source-mismatch", unmappedLane = "unmapped-lane", incompatibleLane = "incompatible-lane"
    case nativeCommandRejected = "native-command-rejected"
}
public struct NativeTimelineMultiMovePlanFailure: Error, Equatable {
    public var code: NativeTimelineMultiMovePlanFailureCode; public var message: String; public var changeIndex: Int?
}
public struct NativeTimelineMultiMovePlan: Equatable {
    public var document: NativeProjectDocument; public var moves: [NativeTimelineMultiMovePlannedMove]; public var sourceFiles: [String]
}
public typealias NativeTimelineMultiMovePlanResult = Result<NativeTimelineMultiMovePlan, NativeTimelineMultiMovePlanFailure>

/// Plan a group gesture against one immutable snapshot; frames and explicit lanes are canonical.
public func planNativeTimelineMultiMove(_ document: NativeProjectDocument, changes: [NativeTimelineMultiMoveChange],
                                        engine: KeyframeEngine) throws -> NativeTimelineMultiMovePlanResult {
    func fail(_ c: NativeTimelineMultiMovePlanFailureCode, _ m: String, _ i: Int? = nil) -> NativeTimelineMultiMovePlanResult {
        .failure(.init(code: c, message: m, changeIndex: i))
    }
    if changes.isEmpty { return fail(.emptyChangeSet, "A native multi-clip move requires at least one change") }
    var planned: [NativeTimelineMultiMovePlannedMove] = []
    var nativeMoves: [NativeProjectClipMove] = []
    var addressed = Set<NativeProjectClipAddress>()
    var working = document
    for (i, change) in changes.enumerated() {
        if !change.requestedStartSeconds.isFinite || change.requestedStartSeconds < 0 {
            return fail(.invalidStart, "Native timeline starts must be finite non-negative times", i)
        }
        let located: NativeLocatedClip
        switch resolveNativeClipSelection(document, change.element) {
        case .failure(let f):
            switch f.code {
            case .missingSelectionId: return fail(.missingSelectionId, f.message, i)
            case .ambiguousClip: return fail(.ambiguousClip, f.message, i)
            default: return fail(.clipNotFound, f.message, i)
            }
        case .success(let l): located = l
        }
        let clip = located.clip
        guard let sourceTrack = document.sequence.tracks.first(where: { $0.id == located.trackId }) else {
            return fail(.clipNotFound, "Native source track \(located.trackId) does not exist", i)
        }
        if let b = clip.binding, let s = change.element.sourceFile, !s.isEmpty, s != b.sourceFile {
            return fail(.bindingSourceMismatch, "Selected source \(s) does not match native binding \(b.sourceFile)", i)
        }
        guard let sourceLane = sourceTrack.lane else {
            return fail(.unmappedLane, "Native source track \(sourceTrack.id) has no explicit lane mapping", i)
        }
        let authoredTrack = change.destinationAuthoredTrack ?? sourceLane.authoredTrack
        if !isSafeInteger(authoredTrack) || authoredTrack < 0 { return fail(.unmappedLane, "Choose a non-negative whole-number track", i) }
        var destinationTrack: NativeProjectTrack
        if let found = working.sequence.tracks.first(where: { $0.lane?.authoredTrack == authoredTrack }), found.lane != nil {
            destinationTrack = found
        } else {
            // Empty timeline lanes are valid drop targets; create their mapping in the same immutable transaction.
            let baseId = "native-track:\(jsNumberString(authoredTrack)):\(sourceTrack.kind.rawValue)"
            var id = baseId; var suffix = 1
            while working.sequence.tracks.contains(where: { $0.id == id }) { id = "\(baseId):\(suffix)"; suffix += 1 }
            let displayTaken = working.sequence.tracks.contains { $0.lane?.displayTrack == authoredTrack }
            let display = displayTaken ? ([-1.0] + working.sequence.tracks.map { $0.lane?.displayTrack ?? -1 }).max()! + 1 : authoredTrack
            destinationTrack = NativeProjectTrack(id: id, kind: sourceTrack.kind, lane: .init(authoredTrack: authoredTrack, displayTrack: display), clips: [])
            working.sequence.tracks.append(destinationTrack)
        }
        let address = NativeProjectClipAddress(sequenceId: document.sequence.id, trackId: located.trackId, clipId: clip.id)
        if addressed.contains(address) { return fail(.duplicateClip, "Native clip \(clip.id) is targeted more than once by the same gesture", i) }
        addressed.insert(address)
        let startFrame = try projectFrameFromSeconds(change.requestedStartSeconds, frameRate: document.frameRate)
        let lane = destinationTrack.lane!
        let destination = NativeTimelineLaneDestination(trackId: destinationTrack.id, authoredTrack: lane.authoredTrack, displayTrack: lane.displayTrack)
        planned.append(.init(address: address, sourceFile: clip.binding?.sourceFile, binding: clip.binding, startFrame: startFrame,
                             compatibilityStartSeconds: (startFrame * document.frameRate.denominator) / document.frameRate.numerator, destination: destination))
        nativeMoves.append(.init(address: address, destination: .init(trackId: destination.trackId, startFrame: startFrame)))
    }
    let command = try applyNativeProjectClipCommand(working, .moveMany(nativeMoves), engine: engine)
    if let f = command.failure { return fail(.nativeCommandRejected, f.message) }
    var seen = Set<String>(); var files: [String] = []
    for p in planned { if let s = p.sourceFile, seen.insert(s).inserted { files.append(s) } }
    return .success(.init(document: command.document, moves: planned, sourceFiles: files.sorted(by: jsCodeUnitLess)))
}
