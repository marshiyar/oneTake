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
// Clip delete plans: which clips a timeline delete removes.
import Foundation

public struct NativeTimelineDeleteTarget: Equatable {
    public var reference: NativeSelectedElementReference
    public var structuralRole: String?
    public init(_ reference: NativeSelectedElementReference, structuralRole: String? = nil) { self.reference = reference; self.structuralRole = structuralRole }
}

public struct NativeTimelineDeletePlannedTarget: Equatable {
    public var address: NativeProjectClipAddress; public var sourceFile: String?; public var binding: NativeClipDomBinding?
}

public enum NativeTimelineDeletePlanFailureCode: String {
    case emptyTargetSet = "empty-target-set", protectedRoot = "protected-root", missingSelectionId = "missing-selection-id"
    case clipNotFound = "clip-not-found", ambiguousClip = "ambiguous-clip", duplicateClip = "duplicate-clip"
    case bindingSourceMismatch = "binding-source-mismatch", nativeCommandRejected = "native-command-rejected"
}
public struct NativeTimelineDeletePlanFailure: Error, Equatable {
    public var code: NativeTimelineDeletePlanFailureCode; public var message: String; public var targetIndex: Int?
}
public struct NativeTimelineDeletePlan: Equatable {
    public var document: NativeProjectDocument; public var deletions: [NativeTimelineDeletePlannedTarget]; public var sourceFiles: [String]
}
public typealias NativeTimelineDeletePlanResult = Result<NativeTimelineDeletePlan, NativeTimelineDeletePlanFailure>

// JS /\[\s*data-composition-id(?:\s*[=\]])/i
private let compositionSelector = try! NSRegularExpression(pattern: #"\[\s*data-composition-id(?:\s*[=\]])"#, options: [.caseInsensitive])

func isCompositionRootTarget(_ t: NativeTimelineDeleteTarget) -> Bool {
    if t.structuralRole == "composition-root" { return true }
    if case .some(.some) = t.reference.attributes?["data-composition-id"] { return true }   // `!= null`
    guard let s = t.reference.selector else { return false }
    return compositionSelector.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// Validate a whole delete selection against one snapshot, then remove every clip in one native command.
public func planNativeTimelineDelete(_ document: NativeProjectDocument, targets: [NativeTimelineDeleteTarget], engine: KeyframeEngine) throws -> NativeTimelineDeletePlanResult {
    func fail(_ c: NativeTimelineDeletePlanFailureCode, _ m: String, _ i: Int? = nil) -> NativeTimelineDeletePlanResult { .failure(.init(code: c, message: m, targetIndex: i)) }
    if targets.isEmpty { return fail(.emptyTargetSet, "A native timeline delete requires at least one target") }
    var deletions: [NativeTimelineDeletePlannedTarget] = []
    var addressed = Set<NativeProjectClipAddress>()
    for (i, target) in targets.enumerated() {
        if isCompositionRootTarget(target) { return fail(.protectedRoot, "The composition root is structural and cannot be deleted", i) }
        let located: NativeLocatedClip
        switch resolveNativeClipSelection(document, target.reference) {
        case .failure(let f):
            switch f.code {
            case .missingSelectionId: return fail(.missingSelectionId, f.message, i)
            case .ambiguousClip: return fail(.ambiguousClip, f.message, i)
            default: return fail(.clipNotFound, f.message, i)
            }
        case .success(let l): located = l
        }
        let clip = located.clip
        if let b = clip.binding, let s = target.reference.sourceFile, !s.isEmpty, s != b.sourceFile {
            return fail(.bindingSourceMismatch, "Selected source \(s) does not match native binding \(b.sourceFile)", i)
        }
        let address = NativeProjectClipAddress(sequenceId: document.sequence.id, trackId: located.trackId, clipId: clip.id)
        if addressed.contains(address) { return fail(.duplicateClip, "Native clip \(clip.id) is targeted more than once by the same delete", i) }
        addressed.insert(address)
        deletions.append(.init(address: address, sourceFile: clip.binding?.sourceFile, binding: clip.binding))
    }
    let command = try applyNativeProjectClipCommand(document, .deleteMany(deletions.map(\.address)), engine: engine)
    if let f = command.failure { return fail(.nativeCommandRejected, f.message) }
    var seen = Set<String>(); var files: [String] = []
    for d in deletions { if let s = d.sourceFile, seen.insert(s).inserted { files.append(s) } }
    return .success(.init(document: command.document, deletions: deletions, sourceFiles: files.sorted(by: jsCodeUnitLess)))
}
