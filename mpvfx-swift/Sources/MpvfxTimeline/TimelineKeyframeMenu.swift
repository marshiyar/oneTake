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
// The keyframe diamond's context menu (no incoming-segment ease editor; custom curves are edited in the inspector).
import Foundation
import MpvfxCanvas
import MpvfxShared

/// Drawn keyframe diamond context menu: move the keys to the playhead, set their
/// outgoing ease or open the inspector's easing editor on them, delete them, or delete every key in the diamond's
/// scope. Each edit is one undo step.
public struct TimelineKeyframeMenu: Equatable, Sendable {
    public enum Action: String, Sendable { case moveToPlayhead, linear, easeIn, easeOut, easeInOut, hold, editEasing, delete, deleteAll }
    public struct Item: Equatable, Sendable {
        public var action: Action; public var label: String; public var hint: String?
        public var enabled = true; public var checked: Bool?; public var destructive = false
    }
    public enum Entry: Equatable, Sendable { case item(Item), divider }

    /// The ease presets in menu order, with the curves the inspector's easing picker uses.
    public static let eases: [(action: Action, label: String, value: NativeInterpolation)] = [
        (.linear, "Linear", .linear),
        (.easeIn, "Ease In", .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 1, y2: 1))),
        (.easeOut, "Ease Out", .cubicBezier(CubicBezierControlPoints(x1: 0, y1: 0, x2: 0.58, y2: 1))),
        (.easeInOut, "Ease In-Out", .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 0.58, y2: 1))),
        (.hold, "Hold", .hold),
    ]

    public var x: Double, y: Double
    /// The keys the actions edit: the clicked diamond, or the whole key selection when the diamond is part of it.
    public var refs: Set<TimelineKeyframeRef>
    /// The diamond's scope for "Delete All Keyframes": its clip, and its lane's property group (nil: the clip bar).
    public var clipId: String, group: String?
    public var entries: [Entry]
    public var hovered: Action?

    public var height: Double {
        var h: Double = 2.0 * TimelineClipMenu.padY + 2.0
        for e in entries { if case .divider = e { h += TimelineClipMenu.dividerHeight } else { h += TimelineClipMenu.itemHeight } }
        return h
    }
    public var rect: CanvasRect { CanvasRect(x: x, y: y, width: TimelineClipMenu.width, height: height) }

    public func itemRects() -> [(Item, CanvasRect)] {
        var cy = y + 1 + TimelineClipMenu.padY; var out: [(Item, CanvasRect)] = []
        for e in entries {
            switch e {
            case .divider: cy += TimelineClipMenu.dividerHeight
            case .item(let it):
                out.append((it, CanvasRect(x: x + 1, y: cy, width: TimelineClipMenu.width - 2, height: TimelineClipMenu.itemHeight)))
                cy += TimelineClipMenu.itemHeight
            }
        }
        return out
    }
    public func item(atX px: Double, y py: Double) -> Item? {
        itemRects().first { px >= $0.1.x && px <= $0.1.maxX && py >= $0.1.y && py < $0.1.maxY }?.0
    }

    /// `current`: the ease every target key shares (nil when they differ), checked in the list. `canEditEasing`: the
    /// host shows the easing editor (TimelineController.onEditKeyframeEasing is set) and a target key has one
    /// (TimelineEditor.keyframeEasingGroup).
    public static func entries(count: Int, canMoveToPlayhead: Bool, current: NativeInterpolation?, canEditEasing: Bool) -> [Entry] {
        var e: [Entry] = [.item(Item(action: .moveToPlayhead, label: "Move to Playhead", enabled: canMoveToPlayhead)), .divider]
        for ease in eases { e.append(.item(Item(action: ease.action, label: ease.label, checked: current == ease.value))) }
        e.append(.item(Item(action: .editEasing, label: "Edit Easing…", enabled: canEditEasing)))
        e.append(.divider)
        e.append(.item(Item(action: .delete, label: count == 1 ? "Delete Keyframe" : "Delete \(count) Keyframes", hint: "⌫", destructive: true)))
        e.append(.item(Item(action: .deleteAll, label: "Delete All Keyframes", destructive: true)))
        return e
    }
}

extension TimelineView {
    func drawKeyframeMenu(_ c: CanvasContext, _ m: TimelineKeyframeMenu) {
        let rows: [TimelineView.MenuRow?] = m.entries.map {
            guard case .item(let it) = $0 else { return nil }
            return MenuRow(label: it.label, hint: it.hint, enabled: it.enabled, checked: it.checked == true,
                           destructive: it.destructive, hovered: m.hovered == it.action)
        }
        drawMenu(c, m.rect, rows)
    }
}

// MARK: - Controller
extension TimelineController {
    /// Right-click on a diamond: the menu acts on the key selection when the diamond belongs to it, else on the
    /// diamond alone (which becomes the selection, without seeking).
    internal func openKeyframeMenu(_ hit: TimelineKeyframeHit, x: Double, y: Double) {
        guard let editor else { return }
        let inSelection = hit.refs.isSubset(of: view.selectedKeyframes) && view.selectedKeyframes.allSatisfy { $0.clipId == hit.clipId }
        if !inSelection { view.selectedKeyframes = hit.refs }
        view.selection = [hit.clipId]
        let refs = view.selectedKeyframes
        let outs = refs.compactMap { editor.outgoing($0) }
        let current = outs.allSatisfy { $0 == outs.first } ? outs.first : nil
        let group = hit.lane.flatMap { lane in clip(hit.clipId).flatMap { $0.1.lanes.indices.contains(lane) ? $0.1.lanes[lane].group : nil } }
        let entries = TimelineKeyframeMenu.entries(count: Set(refs.map(\.frame)).count, canMoveToPlayhead: playheadMoveDelta(refs) != nil,
                                                   current: current, canEditEasing: onEditKeyframeEasing != nil && refs.contains { TimelineEditor.keyframeEasingGroup($0.parameterId) != nil })
        var m = TimelineKeyframeMenu(x: x, y: y, refs: refs, clipId: hit.clipId, group: group, entries: entries)
        if m.x + TimelineClipMenu.width > viewport.width { m.x -= TimelineClipMenu.width }
        if m.y + m.height > viewport.height { m.y = max(0, m.y - m.height) }
        view.keyframeMenu = m
    }

    internal func keyframeMenuClick(x: Double, y: Double) {
        guard let m = view.keyframeMenu else { return }
        guard let item = m.item(atX: x, y: y) else {
            if !m.rect.contains(x: x, y: y) { view.keyframeMenu = nil; needsDisplay?() }
            return
        }
        guard item.enabled else { return }
        view.keyframeMenu = nil
        runKeyframeMenu(item.action, m)
        needsDisplay?()
    }

    /// Frames that put the earliest target key on the playhead; nil when they are already there or the offset would
    /// leave the clip or cross another key of their parameters (the range drags and nudges use).
    func playheadMoveDelta(_ refs: Set<TimelineKeyframeRef>) -> Double? {
        guard let first = refs.first, refs.allSatisfy({ $0.clipId == first.clipId }), let (_, c) = clip(first.clipId),
              let earliest = refs.map(\.frame).min() else { return nil }
        let fps = max(view.frameRate, 1e-9)
        let delta = ((playback.currentTime - c.start) * fps).rounded() - earliest
        guard delta != 0, let range = keyframeDeltaRange(refs), range.contains(delta) else { return nil }
        return delta
    }

    @discardableResult func runKeyframeMenu(_ action: TimelineKeyframeMenu.Action, _ m: TimelineKeyframeMenu) -> Bool {
        guard let editor else { return false }
        switch action {
        case .moveToPlayhead:
            guard let delta = playheadMoveDelta(m.refs) else { return false }
            return moveKeyframes(m.refs, deltaFrames: delta, label: "Move keyframes to playhead")
        case .linear, .easeIn, .easeOut, .easeInOut, .hold:
            guard let ease = TimelineKeyframeMenu.eases.first(where: { $0.action == action }) else { return false }
            let ok = editor.setOutgoing(m.refs.sorted { ($0.frame, $0.parameterId) < ($1.frame, $1.parameterId) }, ease.value)
            needsDisplay?(); return ok
        case .editEasing:
            guard let open = onEditKeyframeEasing else { return false }
            open(m.clipId, m.refs)
            return true
        case .delete:
            return deleteKeyframes(m.refs)
        case .deleteAll:
            guard let (_, c) = clip(m.clipId) else { return false }
            var all = Set<TimelineKeyframeRef>()
            for ch in view.keyframeChannels(c, group: m.group) {
                for f in ch.frames { all.insert(TimelineKeyframeRef(clipId: c.id, parameterId: ch.parameterId, frame: f)) }
            }
            return deleteKeyframes(all, label: "Delete all keyframes")
        }
    }
}
