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

public enum NativeTextStyleCommand: Equatable, Sendable {
    case save(clipId: String, styleId: String, name: String)
    case apply(styleId: String, clipIds: [String])
    case update(styleId: String, fromClipId: String)
    case detach(clipIds: [String])
}

public enum NativeTextStyleError: Error, Equatable {
    case missingClip, missingStyle, duplicateStyle, lockedTrack, unsupportedStyle, invalidName
}

/// One atomic document plan, validated before it is returned. The editor stores one restore-document inverse for
/// the entire result, including multi-clip apply/detach. Words and unrelated clip fields are never changed.
public func planNativeTextStyle(_ document: NativeProjectDocument, _ command: NativeTextStyleCommand,
                                engine: KeyframeEngine? = nil) throws -> NativeProjectDocument {
    var next = document
    func sourceText(_ id: String) throws -> NativeClipText {
        guard let clip = document.sequence.tracks.flatMap(\.clips).first(where: { $0.id == id }),
              let text = resolvedText(clip, document.textStyles ?? []) else { throw NativeTextStyleError.missingClip }
        return text
    }
    switch command {
    case .save(let clipId, let styleId, let name):
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeTextStyleError.invalidName }
        guard !(next.textStyles ?? []).contains(where: { $0.id == styleId }) else { throw NativeTextStyleError.duplicateStyle }
        next.textStyles = (next.textStyles ?? []) + [NativeTextStyle(id: styleId, name: name, text: try sourceText(clipId))]
    case .update(let styleId, let clipId):
        guard let index = next.textStyles?.firstIndex(where: { $0.id == styleId }) else { throw NativeTextStyleError.missingStyle }
        guard next.textStyles?[index].isSupported == true else { throw NativeTextStyleError.unsupportedStyle }
        var text = try sourceText(clipId); text.content = ""
        next.textStyles?[index].text = text
    case .apply(let styleId, let clipIds):
        guard let style = next.textStyles?.first(where: { $0.id == styleId }) else { throw NativeTextStyleError.missingStyle }
        guard style.isSupported else { throw NativeTextStyleError.unsupportedStyle }
        try editTextStyleClips(&next, clipIds) { clip in clip.textStyle = .init(styleId: styleId) }
    case .detach(let clipIds):
        let styles = next.textStyles ?? []
        try editTextStyleClips(&next, clipIds) { clip in
            guard let text = resolvedText(clip, styles) else { throw NativeTextStyleError.unsupportedStyle }
            clip.text = text; clip.textStyle = nil
        }
    }
    return try parseNativeProjectDocument(next, engine: engine)
}

private func editTextStyleClips(_ document: inout NativeProjectDocument, _ clipIds: [String],
                                 _ body: (inout NativeProjectClip) throws -> Void) throws {
    let wanted = Set(clipIds)
    var found = Set<String>()
    for t in document.sequence.tracks.indices {
        for c in document.sequence.tracks[t].clips.indices where wanted.contains(document.sequence.tracks[t].clips[c].id) {
            guard document.sequence.tracks[t].locked != true else { throw NativeTextStyleError.lockedTrack }
            guard document.sequence.tracks[t].clips[c].text != nil else { throw NativeTextStyleError.missingClip }
            found.insert(document.sequence.tracks[t].clips[c].id)
            try body(&document.sequence.tracks[t].clips[c])
        }
    }
    guard found == wanted else { throw NativeTextStyleError.missingClip }
}
