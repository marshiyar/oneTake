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
import Foundation

/// One atomic document plan, validated before it is returned. The editor stores one restore-document inverse for
/// the entire result, including multi-clip apply/detach. Words and unrelated clip fields are never changed.
public func planNativeTextStyle(
    _ document: NativeProjectDocument, _ command: NativeTextStyleCommand,
    engine: KeyframeEngine? = nil
) throws -> NativeProjectDocument {
    let next: NativeProjectDocument
    switch command {
    case .save(let clipId, let styleId, let name):
        next = try planSave(document, clipId: clipId, styleId: styleId, name: name)
    case .apply(let styleId, let clipIds):
        next = try planApply(document, styleId: styleId, clipIds: clipIds)
    case .update(let styleId, let clipId):
        next = try planUpdate(document, styleId: styleId, clipId: clipId)
    case .detach(let clipIds):
        next = try planDetach(document, clipIds: clipIds)
    }
    return try parseNativeProjectDocument(next, engine: engine)
}

private func sourceText(_ document: NativeProjectDocument, clipId: String) throws -> NativeClipText {
    guard let clip = document.sequence.tracks.flatMap(\.clips).first(where: { $0.id == clipId }),
        let text = resolvedText(clip, document.textStyles ?? [])
    else { throw NativeTextStyleError.missingClip }
    return text
}

private func planSave(
    _ document: NativeProjectDocument, clipId: String, styleId: String,
    name: String
) throws -> NativeProjectDocument {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeTextStyleError.invalidName }
    guard !(document.textStyles ?? []).contains(where: { $0.id == styleId }) else {
        throw NativeTextStyleError.duplicateStyle
    }
    var next = document
    let style = NativeTextStyle(id: styleId, name: name, text: try sourceText(document, clipId: clipId))
    next.textStyles = (next.textStyles ?? []) + [style]
    return next
}

private func planApply(
    _ document: NativeProjectDocument, styleId: String,
    clipIds: [String]
) throws -> NativeProjectDocument {
    guard let style = document.textStyles?.first(where: { $0.id == styleId }) else {
        throw NativeTextStyleError.missingStyle
    }
    guard style.isSupported else { throw NativeTextStyleError.unsupportedStyle }
    var next = document
    try editTextStyleClips(&next, clipIds) { clip in clip.textStyle = .init(styleId: styleId) }
    return next
}

private func planUpdate(
    _ document: NativeProjectDocument, styleId: String,
    clipId: String
) throws -> NativeProjectDocument {
    guard let index = document.textStyles?.firstIndex(where: { $0.id == styleId }) else {
        throw NativeTextStyleError.missingStyle
    }
    guard document.textStyles?[index].isSupported == true else { throw NativeTextStyleError.unsupportedStyle }
    var next = document
    var text = try sourceText(document, clipId: clipId)
    text.content = ""
    next.textStyles?[index].text = text
    return next
}

private func planDetach(_ document: NativeProjectDocument, clipIds: [String]) throws -> NativeProjectDocument {
    var next = document
    let styles = next.textStyles ?? []
    try editTextStyleClips(&next, clipIds) { clip in
        guard let text = resolvedText(clip, styles) else { throw NativeTextStyleError.unsupportedStyle }
        clip.text = text
        clip.textStyle = nil
    }
    return next
}

private func editTextStyleClips(
    _ document: inout NativeProjectDocument, _ clipIds: [String],
    _ body: (inout NativeProjectClip) throws -> Void
) throws {
    let wanted = Set(clipIds)
    var found = Set<String>()
    for t in document.sequence.tracks.indices {
        for c in document.sequence.tracks[t].clips.indices
        where wanted.contains(document.sequence.tracks[t].clips[c].id) {
            guard document.sequence.tracks[t].locked != true else { throw NativeTextStyleError.lockedTrack }
            guard document.sequence.tracks[t].clips[c].text != nil else { throw NativeTextStyleError.missingClip }
            found.insert(document.sequence.tracks[t].clips[c].id)
            try body(&document.sequence.tracks[t].clips[c])
        }
    }
    guard found == wanted else { throw NativeTextStyleError.missingClip }
}
