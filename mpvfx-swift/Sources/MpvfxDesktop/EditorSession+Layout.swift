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
// The Layout menu and its shortcuts (issue #322). ⌥⌘G opens the menu at the pointer for the selected clips; ⌥ and an
// arrow key move a picture in picture to that side; ⌥⌘[ and ⌥⌘] swap two clips' cells (with more clips, step them
// around). The last two work on the layout the menu applied last, while the same clips are selected; otherwise ⌥⌘[ and
// ⌥⌘] stay the scene-split threshold. Each re-arranging is one undo step.
import Foundation
import MpvfxCanvas
import MpvfxPlayer
import MpvfxShared
import MpvfxTimeline

extension EditorSession {
    /// The selected clips in selection order (the stage's), else the timeline's in track order.
    func layoutClipIds() -> [String] {
        if !player.view.selectedIds.isEmpty { return player.view.selectedIds }
        let picked = timeline.view.selection
        return editor.document.sequence.tracks.flatMap(\.clips).map(\.id).filter { picked.contains($0) }
    }

    @discardableResult
    func applyLayout(_ layout: NativeGridLayout, options: NativeGridOptions, ids: [String]? = nil) -> Bool {
        let ids = ids ?? layoutClipIds()
        let frame = (playback.currentTime * editor.fps).rounded()
        guard editor.applyGridLayout(layout, clipIds: ids, atFrame: frame, options: options) else {
            player.view.showToast(editor.lastFailure?.message ?? "The clips could not be arranged.", isError: true)
            redraw()
            return false
        }
        lastLayout = (layout, ids, options)
        syncStage(); redraw()
        return true
    }

    /// The Layout menu's keys, ahead of the transport and the timeline.
    func layoutKey(_ k: EditorKey) -> Bool {
        if player.view.layoutMenu != nil, let handled = player.layoutMenuKey(k) { redraw(); return handled }
        guard k.alt, !k.shift else { return false }
        if k.command {
            switch k.code {
            case .char("g"), .char("G"):
                let ids = layoutClipIds()
                guard !ids.isEmpty else { player.view.showToast("Select clips to arrange.", isError: true); redraw(); return true }
                player.openLayoutMenu(at: player.pointerLocation, clipCount: ids.count)
                redraw()
                return true
            case .char("["), .char("]"):
                guard let last = lastLayout, last.ids.count > 1, Set(last.ids) == Set(layoutClipIds()) else { return false }
                let forward = k.code == .char("]")
                applyLayout(last.layout, options: last.options, ids: StageLayoutMenu.rotated(last.ids, forward: forward))
                return true
            default: return false
            }
        }
        switch k.code {
        case .left, .right, .up, .down:
            guard let last = lastLayout, last.layout == .pictureInPicture, Set(last.ids) == Set(layoutClipIds()) else { return false }
            var options = last.options
            options.corner = StageLayoutMenu.corner(options.corner, moving: k.code)
            if options != last.options { applyLayout(.pictureInPicture, options: options, ids: last.ids) }
            return true
        default: return false
        }
    }
}
