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

/// What a primary press does on each part of the timeline, split out of `pointerDown` by hit kind.
extension TimelineController {
    /// An open menu takes the press (a click on an item, or outside it to close it).
    func menuPointerDown(x: Double, y: Double) -> Bool {
        if view.gapMenu != nil { gapMenuClick(x: x, y: y); return true }
        if view.clipMenu != nil { clipMenuClick(x: x, y: y); return true }
        if view.keyframeMenu != nil { keyframeMenuClick(x: x, y: y); return true }
        return false
    }

    func hitPointerDown(_ hit: Hit, x: Double, y: Double, keys: TimelineGestureKeys) {
        switch hit {
        case .ruler:
            gesture = .scrub; view.scrubbing = true; scrub(to: x)
        case .empty(let row):
            emptyPointerDown(row: row, x: x, y: y, additive: keys.shift || keys.command)
        case .header(let row): headerPointerDown(row: row, x: x, y: y)
        case let .groupHeader(id, caret):
            if caret { toggleGroup(id) } else { groupHeaderClick(id, x: x, y: y) }
        case let .clipExtra(id, _): clipExtraPointerDown(id, additive: keys.shift || keys.command)
        case .clip: clipPointerDown(hit, x: x, y: y, keys: keys)
        }
    }

    /// A track header: a lane control (keyframe navigation, toggles) when one is under the pointer, else the header.
    func headerPointerDown(row: Int, x: Double, y: Double) {
        if laneHeaderClick(x: x, y: y, row: row) { return }
        headerClick(x: x, y: y, row: row)
    }

    /// An effect strip or property lane under a clip selects the clip (⇧/⌘ toggles it); keys of other clips drop.
    func clipExtraPointerDown(_ id: String, additive: Bool) {
        if view.selectedKeyframes.contains(where: { $0.clipId != id }) { view.selectedKeyframes = [] }
        if additive { toggleSelected(id) } else { view.selection = [id] }
    }

    /// Empty body: click clears (unless additive) and may grow into a marquee; the ruler-height strip scrubs.
    func emptyPointerDown(row: Int?, x: Double, y: Double, additive: Bool) {
        if row == nil && y < TimelineLayout.rulerHeight { gesture = .scrub; view.scrubbing = true; scrub(to: x); return }
        if !additive { view.selection = [] }
        marqueeKeyframeBase = additive ? view.selectedKeyframes : []
        if !additive { view.selectedKeyframes = [] }
        if x >= TimelineLayout.contentOrigin { gesture = .pendingMarquee(x: x, y: y, base: additive ? view.selection : []) }
    }
}
