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
import MpvfxShared

/// Document edits behind the clip context menu.
public extension TimelineEditor {
    @discardableResult func setMuted(clipId: String, _ muted: Bool) -> Bool {
        guard !isClipLocked(clipId) else { return false }
        // A video whose sound is detached stays muted; unmute its linked audio clip instead.
        if !muted, document.sequence.tracks.contains(where: { $0.clips.contains { $0.audioDetachedFrom == clipId } }) {
            lastFailure = .init(code: .incompatibleDestination, message: "This video's sound is detached; unmute its linked audio clip instead")
            return false
        }
        var d = document
        for ti in d.sequence.tracks.indices {
            if let ci = d.sequence.tracks[ti].clips.firstIndex(where: { $0.id == clipId }) {
                guard d.sequence.tracks[ti].clips[ci].muted != muted else { return false }
                d.sequence.tracks[ti].clips[ci].muted = muted
                withHistory(muted ? "Mute clip" : "Unmute clip") { replaceDocument(d, inverse: .restoreDocument(document)) }; return true
            }
        }
        return false
    }

    @discardableResult func detachAudio(clipId: String, hasAudioStream: Bool = true) -> Bool {
        guard !isClipLocked(clipId) else { return false }
        do {
            let d = try detachNativeVideoAudio(document, videoClipId: clipId, hasAudioStream: hasAudioStream, engine: engine)
            withHistory("Detach audio") { replaceDocument(d, inverse: .restoreDocument(document)) }; return true
        } catch { lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "\(error)"); return false }
    }

    @discardableResult func reattachAudio(clipId: String) -> Bool {
        guard !isClipLocked(clipId) else { return false }
        do {
            let d = try reattachNativeVideoAudio(document, audioClipId: clipId, engine: engine)
            withHistory("Reattach audio") { replaceDocument(d, inverse: .restoreDocument(document)) }; return true
        } catch { lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "\(error)"); return false }
    }
}
