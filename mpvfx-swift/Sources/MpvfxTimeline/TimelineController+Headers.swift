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
import MpvfxCanvas

/// Track header clicks (TimelineTrackHeader / VisibilityButton / TimelineFxButton).
public extension TimelineController {
    /// What a header click did, for hosts and tests.
    enum HeaderAction: Equatable, Sendable {
        case toggledHidden(row: Int), toggledMuted(row: Int)
        case openedFx(clipId: String)
        case groupPointer(row: Int)
        case openedGroupFx(groupId: String), openedGroupRack(groupId: String)
    }

    /// Route a click on track header `row`: eye → hide, speaker (audio rows) → mute, FX → `onOpenClipFx`,
    /// group pointer → select the track's clips and group them (`onRequestGroupName` first when set, the
    /// "Name this group" dialog, which then calls `groupSelectedAudio(label:)`).
    @discardableResult
    func headerClick(x: Double, y: Double, row: Int) -> HeaderAction? {
        guard view.tracks.indices.contains(row), let control = view.headerControl(atX: x, y: y, row: row) else { return nil }
        let track = view.tracks[row]
        let action: HeaderAction
        switch control {
        case .visibility:
            if track.kind == "audio" { toggleTrackMuted(row: row); action = .toggledMuted(row: row) }
            else { toggleTrackHidden(row: row); action = .toggledHidden(row: row) }
        case .fx(let clipId):
            view.selection = [clipId]
            let rect = view.headerControls(row: row).first { $0.control == control }?.rect ?? CanvasRect(x: x, y: y, width: 0, height: 0)
            onOpenClipFx?(clipId, rect)
            action = .openedFx(clipId: clipId)
        case .groupPointer:
            view.selection = Set(track.clips.map(\.id))
            if let ask = onRequestGroupName { ask(track.clips.count, track.name) }
            else { groupSelectedAudio(label: track.name) }
            action = .groupPointer(row: row)
        }
        lastHeaderAction = action
        needsDisplay?()
        return action
    }

    /// Group header (TimelineGroupHeader): FX button → `onOpenGroupFx`, name button → `onOpenGroupFxRack`.
    @discardableResult
    func groupHeaderClick(_ id: String, x: Double, y: Double) -> Bool {
        guard let g = view.groups.first(where: { $0.id == id }), let top = view.groupHeaderTop(id) else { return false }
        let fx = view.groupFxRect(g, top: top)
        if x >= fx.x && x <= fx.maxX && y >= fx.y && y <= fx.maxY {
            onOpenGroupFx?(id, fx); lastHeaderAction = .openedGroupFx(groupId: id); needsDisplay?(); return true
        }
        let name = view.groupNameRect(top: top)
        if x >= name.x && x <= name.maxX && y >= name.y && y <= name.maxY {
            onOpenGroupFxRack?(id); lastHeaderAction = .openedGroupRack(groupId: id); needsDisplay?(); return true
        }
        return false
    }
}
