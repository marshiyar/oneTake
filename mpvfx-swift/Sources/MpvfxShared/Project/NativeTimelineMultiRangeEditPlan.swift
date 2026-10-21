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
// Multi-clip range edit plans: one trim or move of several selected clips.
import Foundation

public struct NativeTimelineMultiRangeEditChange: Equatable, Sendable {
    public var element: NativeSelectedElementReference; public var requestedStartSeconds: Double; public var requestedDurationSeconds: Double
    public init(element: NativeSelectedElementReference, requestedStartSeconds: Double, requestedDurationSeconds: Double) {
        self.element = element; self.requestedStartSeconds = requestedStartSeconds; self.requestedDurationSeconds = requestedDurationSeconds
    }
}
public struct NativeTimelineMultiRangePlannedEdit: Equatable {
    public var address: NativeProjectClipAddress; public var sourceFile: String?; public var binding: NativeClipDomBinding?
    public var kind: NativeTimelineRangeEditKind; public var startFrame: Double; public var durationFrames: Double; public var endFrameExclusive: Double
    public var sourceInFrame: Double; public var sourceInFraction: NativePlaybackRate?; public var compatibility: NativeTimelineCompatibilityRange
}
/// NativeTimelineRangeEditPlanFailureCode | "empty-change-set" | "duplicate-clip" | "binding-source-mismatch".
public enum NativeTimelineMultiRangeEditPlanFailureCode: String, Sendable {
    case invalidRange = "invalid-range", noChange = "no-change", unsupportedRangeChange = "unsupported-range-change"
    case missingSelectionId = "missing-selection-id", clipNotFound = "clip-not-found", ambiguousClip = "ambiguous-clip"
    case bindingSourceMismatch = "binding-source-mismatch", nativeCommandRejected = "native-command-rejected"
    case emptyChangeSet = "empty-change-set", duplicateClip = "duplicate-clip"
    init(_ c: NativeTimelineRangeEditPlanFailureCode) { self.init(rawValue: c.rawValue)! }
}
public struct NativeTimelineMultiRangeEditPlanFailure: Error, Equatable {
    public var code: NativeTimelineMultiRangeEditPlanFailureCode; public var message: String; public var changeIndex: Int?
}
public struct NativeTimelineMultiRangeEditPlan: Equatable {
    public var document: NativeProjectDocument; public var edits: [NativeTimelineMultiRangePlannedEdit]; public var sourceFiles: [String]
}
public typealias NativeTimelineMultiRangeEditPlanResult = Result<NativeTimelineMultiRangeEditPlan, NativeTimelineMultiRangeEditPlanFailure>

/// Plan a whole multi-selection trim against one snapshot: preflight every member, then apply the trims in order.
public func planNativeTimelineMultiRangeEdit(_ document: NativeProjectDocument, changes: [NativeTimelineMultiRangeEditChange],
                                             engine: KeyframeEngine) throws -> NativeTimelineMultiRangeEditPlanResult {
    func fail(_ c: NativeTimelineMultiRangeEditPlanFailureCode, _ m: String, _ i: Int? = nil) -> NativeTimelineMultiRangeEditPlanResult {
        .failure(.init(code: c, message: m, changeIndex: i))
    }
    if changes.isEmpty { return fail(.emptyChangeSet, "A native multi-clip range edit requires at least one change") }
    var addressed = Set<NativeProjectClipAddress>()
    var preflight: [(change: NativeTimelineMultiRangeEditChange, sourceFile: String?, binding: NativeClipDomBinding?)] = []
    for (i, change) in changes.enumerated() {
        let candidate: NativeTimelineRangeEditPlan
        switch try planNativeTimelineRangeEdit(document, element: change.element, requestedStartSeconds: change.requestedStartSeconds,
                                               requestedDurationSeconds: change.requestedDurationSeconds, engine: engine) {
        case .failure(let f): return fail(.init(f.code), f.message, i)
        case .success(let c): candidate = c
        }
        if addressed.contains(candidate.address) {
            return fail(.duplicateClip, "Native clip \(candidate.address.clipId) is targeted more than once by the same range edit", i)
        }
        addressed.insert(candidate.address)
        let binding = document.sequence.tracks.first { $0.id == candidate.address.trackId }?.clips.first { $0.id == candidate.address.clipId }?.binding
        if let b = binding, b.sourceFile != candidate.sourceFile {
            return fail(.bindingSourceMismatch, "Resolved source \(candidate.sourceFile ?? "null") does not match native binding \(b.sourceFile)", i)
        }
        preflight.append((change, candidate.sourceFile, binding))
    }
    var current = document
    var edits: [NativeTimelineMultiRangePlannedEdit] = []
    for (i, item) in preflight.enumerated() {
        let r: NativeTimelineRangeEditPlan
        switch try planNativeTimelineRangeEdit(current, element: item.change.element, requestedStartSeconds: item.change.requestedStartSeconds,
                                               requestedDurationSeconds: item.change.requestedDurationSeconds, engine: engine) {
        case .failure(let f): return fail(.init(f.code), f.message, i)
        case .success(let v): r = v
        }
        current = r.document
        edits.append(.init(address: r.address, sourceFile: item.sourceFile, binding: item.binding, kind: r.kind, startFrame: r.startFrame,
                           durationFrames: r.durationFrames, endFrameExclusive: r.endFrameExclusive, sourceInFrame: r.sourceInFrame,
                           sourceInFraction: r.sourceInFraction, compatibility: r.compatibility))
    }
    var seen = Set<String>(); var files: [String] = []
    for e in edits { if let s = e.sourceFile, seen.insert(s).inserted { files.append(s) } }
    return .success(.init(document: current, edits: edits, sourceFiles: files.sorted(by: jsCodeUnitLess)))
}
