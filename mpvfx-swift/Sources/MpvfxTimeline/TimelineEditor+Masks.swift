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

/// Mask edits (issue #297): add, change and remove a clip's shape masks. Each is validated with the whole document and
/// recorded as one undo step; a drag or a burst of arrow nudges folds into one step through `coalesceKey`.
public extension TimelineEditor {
    /// A mask is drawn over a picture, text or shape, never a sound.
    private func canTakeMasks(_ clipId: String) -> Bool {
        guard let c = clip(clipId)?.clip else { return false }
        return document.assets.first { $0.id == c.assetId }?.kind != .audio
    }

    func masks(clipId: String) -> [NativeClipMask] { clip(clipId)?.clip.masks ?? [] }

    /// Adds a mask of `kind` (rectangle, ellipse, linear or band) in the middle of the layer, half its size (a linear
    /// split through the middle), as the topmost mask. Returns its id; nil, with nothing recorded, when the clip is
    /// not there, is locked or is a sound.
    @discardableResult
    func addMask(clipId: String, kind: String = "rectangle") -> String? {
        guard NativeClipMask(id: "", kind: kind).isSupported, canTakeMasks(clipId) else { return nil }
        var created: String?
        let ok = editMasks(clipId, label: "Add mask") { list in
            var n = list.count + 1
            while list.contains(where: { $0.id == "mask-\(n)" }) { n += 1 }
            let sized = kind == "rectangle" || kind == "ellipse"
            list.append(NativeClipMask(id: "mask-\(n)", kind: kind, configuration: .init(
                x: 0.5, y: 0.5, width: sized ? 0.5 : (kind == "band" ? 0.5 : nil), height: sized ? 0.5 : nil)))
            created = "mask-\(n)"
            return true
        }
        return ok ? created : nil
    }

    /// Changes one mask. False, with nothing recorded, when the mask is not there, `edit` changes nothing, or the
    /// document refuses the result (a negative width, an opacity above 1).
    @discardableResult
    func setMask(clipId: String, maskId: String, label: String = "Edit mask", coalesceKey: String? = nil,
                 _ edit: (inout NativeClipMask) -> Void) -> Bool {
        editMasks(clipId, label: label, coalesceKey: coalesceKey) { list in
            guard let i = list.firstIndex(where: { $0.id == maskId }) else { return false }
            let before = list[i]
            edit(&list[i])
            return list[i] != before
        }
    }

    @discardableResult
    func removeMask(clipId: String, maskId: String) -> Bool {
        editMasks(clipId, label: "Remove mask") { list in
            guard let i = list.firstIndex(where: { $0.id == maskId }) else { return false }
            list.remove(at: i); return true
        }
    }

    private func editMasks(_ clipId: String, label: String, coalesceKey: String? = nil,
                           _ body: (inout [NativeClipMask]) -> Bool) -> Bool {
        guard !isClipLocked(clipId) else { return false }
        var d = document
        for t in d.sequence.tracks.indices {
            guard let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var list = d.sequence.tracks[t].clips[i].masks ?? []
            guard body(&list) else { return false }
            d.sequence.tracks[t].clips[i].masks = list.isEmpty ? nil : list
            return withHistory(label, coalesceKey: coalesceKey) { commitPresets(d, label: label) }
        }
        return false
    }
}
