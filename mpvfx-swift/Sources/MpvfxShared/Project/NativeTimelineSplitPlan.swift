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
// Split plans: cutting a clip in two at the playhead.
import Foundation

/// A nested/expanded row reports master time for a source-local clip; the planner rejects it.
public struct NativeTimelineSplitElement: Equatable, Sendable {
    public var reference: NativeSelectedElementReference
    public var expandedParentStart: Double?; public var expandedHostKey: String?; public var parentCompositionId: String?
    public init(_ reference: NativeSelectedElementReference, expandedParentStart: Double? = nil, expandedHostKey: String? = nil, parentCompositionId: String? = nil) {
        self.reference = reference; self.expandedParentStart = expandedParentStart; self.expandedHostKey = expandedHostKey; self.parentCompositionId = parentCompositionId
    }
}
public struct NativeTimelineSplitRequest: Equatable, Sendable {
    public var element: NativeTimelineSplitElement; public var requestedSplitSeconds: Double; public var rightBinding: NativeClipDomBinding?
    public init(element: NativeTimelineSplitElement, requestedSplitSeconds: Double, rightBinding: NativeClipDomBinding? = nil) {
        self.element = element; self.requestedSplitSeconds = requestedSplitSeconds; self.rightBinding = rightBinding
    }
}
public struct NativeTimelinePlannedSplit: Equatable {
    public var address: NativeProjectClipAddress; public var sourceFile: String?; public var leftBinding: NativeClipDomBinding?
    public var rightBinding: NativeClipDomBinding?; public var splitFrame: Double
    public var compatibilitySplitSeconds: Double; public var compatibilitySplitTime: String
}
public enum NativeTimelineSplitPlanFailureCode: String, Sendable {
    case emptySplitSet = "empty-split-set", invalidSplitTime = "invalid-split-time", ambiguousLocalTime = "ambiguous-local-time"
    case missingSelectionId = "missing-selection-id", clipNotFound = "clip-not-found", ambiguousClip = "ambiguous-clip"
    case duplicateClip = "duplicate-clip", unboundClip = "unbound-clip", bindingSourceMismatch = "binding-source-mismatch"
    case rightBindingSourceMismatch = "right-binding-source-mismatch", nativeCommandRejected = "native-command-rejected"
}
public struct NativeTimelineSplitPlanFailure: Error, Equatable {
    public var code: NativeTimelineSplitPlanFailureCode; public var message: String
    public var splitIndex: Int?; public var nativeCode: NativeProjectClipFailureCode?
}
public struct NativeTimelineSplitPlan: Equatable {
    public var document: NativeProjectDocument; public var splits: [NativeTimelinePlannedSplit]; public var sourceFiles: [String]
}
public typealias NativeTimelineSplitPlanResult = Result<NativeTimelineSplitPlan, NativeTimelineSplitPlanFailure>

private func isLocalTimeAmbiguous(_ e: NativeTimelineSplitElement) -> Bool {
    e.expandedParentStart != nil || !(e.expandedHostKey ?? "").isEmpty || !(e.parentCompositionId ?? "").isEmpty
}

/// Plan a single or batch split against one immutable native snapshot; the project frame is canonical.
public func planNativeTimelineSplits(_ document: NativeProjectDocument, splits: [NativeTimelineSplitRequest], engine: KeyframeEngine) throws -> NativeTimelineSplitPlanResult {
    func fail(_ c: NativeTimelineSplitPlanFailureCode, _ m: String, _ i: Int? = nil, _ n: NativeProjectClipFailureCode? = nil) -> NativeTimelineSplitPlanResult {
        .failure(.init(code: c, message: m, splitIndex: i, nativeCode: n))
    }
    if splits.isEmpty { return fail(.emptySplitSet, "A native timeline split requires at least one clip") }
    var planned: [NativeTimelinePlannedSplit] = []
    var addressed = Set<NativeProjectClipAddress>()
    for (i, split) in splits.enumerated() {
        if !split.requestedSplitSeconds.isFinite || split.requestedSplitSeconds < 0 {
            return fail(.invalidSplitTime, "Native split time must be finite and non-negative", i)
        }
        if isLocalTimeAmbiguous(split.element) {
            return fail(.ambiguousLocalTime, "Expanded or nested compatibility rows cannot define a native project split boundary", i)
        }
        let located: NativeLocatedClip
        switch resolveNativeClipSelection(document, split.element.reference) {
        case .failure(let f):
            switch f.code {
            case .missingSelectionId: return fail(.missingSelectionId, f.message, i)
            case .ambiguousClip: return fail(.ambiguousClip, f.message, i)
            default: return fail(.clipNotFound, f.message, i)
            }
        case .success(let l): located = l
        }
        let leftBinding = located.clip.binding
        if let lb = leftBinding, let s = split.element.reference.sourceFile, !s.isEmpty, s != lb.sourceFile {
            return fail(.bindingSourceMismatch, "Selected source does not exactly match native binding \(lb.sourceFile)", i)
        }
        if let lb = leftBinding, split.rightBinding?.sourceFile != lb.sourceFile {
            return fail(.rightBindingSourceMismatch, "The compatibility split must create its right clip in the same source file", i)
        }
        let address = NativeProjectClipAddress(sequenceId: document.sequence.id, trackId: located.trackId, clipId: located.clip.id)
        if addressed.contains(address) { return fail(.duplicateClip, "Native clip \(located.clip.id) is targeted more than once by the same split operation", i) }
        addressed.insert(address)
        let splitFrame: Double
        do { splitFrame = try projectFrameFromSeconds(split.requestedSplitSeconds, frameRate: document.frameRate) }
        catch { return fail(.invalidSplitTime, errorMessage(error) ?? "Invalid native split time", i) }
        if !isSafeInteger(splitFrame) { return fail(.invalidSplitTime, "Native split time must resolve to a safe project frame", i) }
        let seconds = (splitFrame * document.frameRate.denominator) / document.frameRate.numerator
        planned.append(.init(address: address, sourceFile: leftBinding?.sourceFile, leftBinding: leftBinding, rightBinding: split.rightBinding,
                             splitFrame: splitFrame, compatibilitySplitSeconds: seconds, compatibilitySplitTime: jsNumberString(seconds)))
    }
    var current = document
    for (i, split) in planned.enumerated() {
        let command = try applyNativeProjectClipCommand(current, .split(address: split.address, splitFrame: split.splitFrame, rightBinding: split.rightBinding), engine: engine)
        if let f = command.failure { return fail(.nativeCommandRejected, f.message, i, f.code) }
        current = command.document
    }
    var seen = Set<String>(); var files: [String] = []
    for p in planned { if let s = p.sourceFile, seen.insert(s).inserted { files.append(s) } }
    return .success(.init(document: current, splits: planned, sourceFiles: files.sorted(by: jsCodeUnitLess)))
}
