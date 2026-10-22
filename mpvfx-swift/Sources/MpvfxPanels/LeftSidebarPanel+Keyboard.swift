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
import MpvfxTimeline

/// Keys: text fields first (search, the name row, rename), then the panel's own: Tab walks the header controls
/// and enters the grid at the selected tile; the arrows move the selection across and down the grid; Enter runs
/// the tile's action (Shift+Enter opens its menu); Escape clears the selection. Keys the panel does not use
/// return false and reach the timeline and playback shortcuts.
extension LeftSidebarPanel {
    public func keyDown(_ k: EditorKey) -> Bool {
        if dropdown.key(k) { onChange?(); return true }
        if let handled = keyIntoField(k) { if handled { onChange?() }; return handled }
        if menu != nil, k.code == .escape { menu = nil; onChange?(); return true }
        let handled = keyNavigate(k)
        if handled { onChange?() }
        return handled
    }

    /// nil when no field is being edited.
    func keyIntoField(_ k: EditorKey) -> Bool? {
        if search != nil { return keySearch(k) }
        if creating != nil { return keyNameRow(k) }
        if menu?.rename != nil { return keyRename(k) }
        return nil
    }

    func keySearch(_ k: EditorKey) -> Bool {
        guard var s = search else { return false }
        switch s.key(k) {
        case .commit: search = s; commitSearch()
        case .cancel: search = nil
        case .editing: search = s; searchQuery = s.draft; binScroll = 0
        case .none: return false
        }
        return true
    }

    func keyNameRow(_ k: EditorKey) -> Bool {
        guard var cr = creating else { return false }
        switch cr.field.key(k) {
        case .commit: confirmCreate()
        case .cancel: creating = nil
        case .editing: creating = (cr.kind, cr.field)
        case .none: return false
        }
        return true
    }

    func keyRename(_ k: EditorKey) -> Bool {
        guard var f = menu?.rename else { return false }
        switch f.key(k) {
        case .commit: menu?.rename = f; commitRename()
        case .cancel: menu?.mode = 0; menu?.rename = nil
        case .editing: menu?.rename = f
        case .none: return false
        }
        return true
    }

    func keyNavigate(_ k: EditorKey) -> Bool {
        if keyAudition(k) { return true }
        if isTabStop(focus.current), stripArrow(k) { return true }   // Left / Right / Home / End on the tab bar
        switch k.code {
        case .tab:
            let moved = focus.move(hits, forward: !k.shift) { [unowned self] in self.isFocusable($0) }
            if case .tile(let ref)? = focus.current { selected = ref }
            return moved
        case .left, .right, .up, .down: return moveSelection(k.code)
        case .enter: return pressEnter(shift: k.shift)
        case .space: return pressFocusedControl()
        case .escape: return clearSelection()
        default: return false
        }
    }

    /// The header and search controls, and one stop in the grid: the selected tile, else the first.
    func isFocusable(_ h: Hit) -> Bool {
        switch h {
        case .tab(let t): return t == tab   // the tab bar is one stop: the selected tab
        case .hideSidebar, .panelMenu, .switcher, .importMedia, .more, .search, .filter, .clearFilters, .clearSearch, .createCancel, .createConfirm: return true
        case .tile(let ref): return ref == (selected.flatMap { s in tileFrames.contains { $0.0 == s } ? s : nil } ?? tileFrames.first?.0)
        default: return false
        }
    }

    func isTabStop(_ h: Hit?) -> Bool { if case .tab? = h { return true }; return false }

    /// Presses the focused header control the way a click does, keeping the ring where it was.
    func pressFocusedControl() -> Bool {
        guard focus.visible, let cur = focus.current, !isTile(cur), let r = hits.rect(where: { $0 == cur }) else { return false }
        _ = pointerDown(CanvasPoint(r.midX, r.midY))
        focus.visible = true; focus.current = cur
        return true
    }

    func isTile(_ h: Hit) -> Bool { if case .tile = h { return true }; return false }

    func pressEnter(shift: Bool) -> Bool {
        if pressFocusedControl() { return true }
        guard let ref = selected, let frame = tileFrames.first(where: { $0.0 == ref })?.1 else { return false }
        if shift {
            guard !menuEntries(ref).isEmpty else { return false }
            menu = Menu(target: ref, at: CanvasPoint(frame.x + 8, frame.maxY + binRect.y - binScroll))
        } else {
            runPrimary(ref)
        }
        return true
    }

    func clearSelection() -> Bool {
        guard selected != nil || focus.visible else { return false }
        selected = nil; focus.visible = false; focus.current = nil
        return true
    }

    /// Only once a tile is selected: before that the arrows belong to the timeline.
    func moveSelection(_ code: EditorKey.Code) -> Bool {
        guard let cur = selected else { return false }
        guard let next = neighbor(of: cur, code) else { return tileFrames.contains { $0.0 == cur } }
        selected = next
        if case .tile? = focus.current { focus.current = .tile(next) }
        scrollIntoView(next)
        return true
    }

    /// Left and right step through the grid's order; up and down go to the nearest tile in the row above or below
    /// (across sections, and between the grid and the audio rows).
    func neighbor(of ref: MediaTileRef, _ code: EditorKey.Code) -> MediaTileRef? {
        guard let i = tileFrames.firstIndex(where: { $0.0 == ref }) else { return tileFrames.first?.0 }
        switch code {
        case .left: return i > 0 ? tileFrames[i - 1].0 : nil
        case .right: return i + 1 < tileFrames.count ? tileFrames[i + 1].0 : nil
        default: return vertical(from: tileFrames[i].1, down: code == .down)
        }
    }

    func vertical(from cur: CanvasRect, down: Bool) -> MediaTileRef? {
        let cands: [(MediaTileRef, CanvasRect)] = tileFrames.filter { (_, r) in down ? r.y >= cur.maxY - 0.5 : r.maxY <= cur.y + 0.5 }
        let tops: [Double] = cands.map { $0.1.y }
        guard let rowY = down ? tops.min() : tops.max() else { return nil }
        let row = cands.filter { abs($0.1.y - rowY) < 0.5 }
        return row.min { abs($0.1.midX - cur.midX) < abs($1.1.midX - cur.midX) }?.0
    }

    /// Scrolls the least that shows the whole tile (content coordinates, as `tileFrames` records them).
    func scrollIntoView(_ ref: MediaTileRef) {
        guard let f = tileFrames.first(where: { $0.0 == ref })?.1 else { return }
        if f.y < binScroll { binScroll = max(0, f.y - M.rowGap) }
        else if f.maxY > binScroll + binRect.height { binScroll = f.maxY - binRect.height + M.rowGap }
    }
}
