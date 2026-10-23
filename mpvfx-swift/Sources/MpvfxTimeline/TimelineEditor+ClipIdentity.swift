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

public extension TimelineEditor {
    /// A clip's own timeline label. Its asset and source filename stay unchanged.
    /// An empty label restores the source name; a locked track cannot be renamed.
    @discardableResult
    func renameClip(_ id: String, name: String) -> Bool {
        guard let address = address(clipId: id), !isClipLocked(id) else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var d = document
        guard let ti = d.sequence.tracks.firstIndex(where: { $0.id == address.trackId }),
              let ci = d.sequence.tracks[ti].clips.firstIndex(where: { $0.id == id }) else { return false }
        d.sequence.tracks[ti].clips[ci].name = name.isEmpty ? nil : name
        return commit(d, "Rename clip")
    }
}
