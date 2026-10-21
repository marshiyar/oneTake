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
import MpvfxShared

/// The panel's menus: the tab strip's panel menu, the switcher (libraries and events), "…" (library and project
/// actions, recent projects), the filter menu, and a tile's context menu.
extension LeftSidebarPanel {
    typealias Option = PanelDropdown.Option

    func openPanelMenu() {
        let generators = NativeGeneratorKind.allCases.map { Option(value: "generator:" + $0.rawValue, label: "Add " + $0.label.lowercased(), group: "Background generators") }
        openDropdown(.panelMenu, [.init(value: "import", label: "Import media…")] + generators + [.init(value: "hide", label: "Hide panel")], nil) { [weak self] v in
            if v.hasPrefix("generator:"), let kind = NativeGeneratorKind(rawValue: String(v.dropFirst(10))) { self?.onAddGenerator?(kind) }
            else if v == "import" { self?.onImport?() } else { self?.layout.toggleLeft() }
        }
    }

    /// An anchor `width` wide whose right edge is the button's, so a wide menu opens right-aligned under it.
    func rightAligned(_ hit: Hit, width: Double) -> CanvasRect? {
        hits.rect { $0 == hit }.map { CanvasRect(x: $0.maxX - width, y: $0.y, width: width, height: $0.height) }
    }

    // MARK: Switcher

    func openSwitcher() {
        openDropdown(.switcher, switcherOptions(), nil) { [weak self] v in self?.pickSwitcher(v) }
    }

    func switcherOptions() -> [Option] {
        guard let lib = activeLibrary else { return libraryCreation("Library") }
        let libs = library.libraries.map { Option(value: "library:\($0.id)", label: Self.displayName($0.name), group: "Libraries", checked: $0.id == lib.id) }
        let events = lib.events.map { Option(value: "event:\($0.id)", label: $0.name, group: "Events", checked: $0.id == activeEvent?.id) }
        return libs + events
    }

    func libraryCreation(_ group: String) -> [Option] {
        guard library.available else { return [] }
        return [Option(value: "newLibrary", label: "New library…", group: group, disabled: library.busy),
                Option(value: "openLibrary", label: "Open library…", group: group, disabled: library.busy)]
    }

    func pickSwitcher(_ v: String) {
        if v.hasPrefix("library:") { selectedLibraryId = String(v.dropFirst(8)); selectedEventId = nil; binScroll = 0 }
        else if v.hasPrefix("event:") { selectedEventId = String(v.dropFirst(6)); binScroll = 0 }
        else { _ = runLibraryOption(v) }
    }

    // MARK: "…": library and project actions

    func openMoreMenu() {
        openDropdown(.more, anchor: rightAligned(.more, width: 236), libraryOptions() + projectOptions() + recentOptions(), nil) { [weak self] v in
            self?.runMoreOption(v)
        }
    }

    /// "Show library in Finder" names the file manager of the platform it runs on.
    static var revealLabel: String {
        #if os(macOS)
        "Show library in Finder"
        #elseif os(Windows)
        "Show library in File Explorer"
        #else
        "Show library in Files"
        #endif
    }

    func libraryOptions() -> [Option] {
        var o = libraryCreation("Library")
        guard library.available, activeLibrary != nil else { return o }
        let busy = library.busy, g = "Library"
        o += [Option(value: "newEvent", label: "New event…", group: g, disabled: busy),
              Option(value: "renameEvent", label: "Rename event…", group: g, disabled: !canRename("renameEvent")),
              Option(value: "importIntoEvent", label: "Import into \(activeEvent?.name ?? "event")…", group: g, disabled: busy || activeEvent == nil),
              Option(value: "storage:managed", label: "Copy files into the library", group: g, checked: !linkedImport),
              Option(value: "storage:linked", label: "Link to the original files", group: g, checked: linkedImport),
              Option(value: "reveal", label: Self.revealLabel, group: g, disabled: busy)]
        return o
    }

    func projectOptions() -> [Option] {
        let busy = library.busy, g = "Project"
        var o = (activeLibrary?.projects ?? []).filter { $0.eventId == activeEvent?.id }.map {
            Option(value: "project:\($0.id)", label: $0.name, group: g, checked: $0.id == library.currentProjectId, disabled: busy)
        }
        if library.available, activeLibrary != nil { o.append(Option(value: "newProject", label: "New project…", group: g, disabled: busy || activeEvent == nil)) }
        if library.available, activeLibrary != nil { o.append(Option(value: "renameProject", label: "Rename project…", group: g, disabled: !canRename("renameProject"))) }
        o.append(Option(value: "openProject", label: "Open project…", group: g, disabled: busy))
        if !library.isStandalone { o.append(Option(value: "standalone", label: "Open existing standalone project", group: g, disabled: busy)) }
        return o
    }

    func recentOptions() -> [Option] {
        library.recentProjects.map { Option(value: "recent:\($0.path)", label: $0.name, group: "Recent projects", disabled: library.busy) }
    }

    func runMoreOption(_ v: String) {
        if !runLibraryOption(v) { runProjectOption(v) }
    }

    /// Returns false when `v` is not a library action.
    func runLibraryOption(_ v: String) -> Bool {
        let l = activeLibrary
        switch v {
        case "newLibrary": onLibrary?(.createLibrary)
        case "openLibrary": onLibrary?(.openLibrary)
        case "renameEvent": startRename(v)
        case "newEvent": creating = ("event", PanelTextField(key: "create", value: ""))
        case "importIntoEvent": if let l, let e = activeEvent { onLibrary?(.importIntoEvent(libraryId: l.id, eventId: e.id, linked: linkedImport)) }
        case "storage:managed", "storage:linked": linkedImport = v == "storage:linked"
        case "reveal": if let l { onLibrary?(.reveal(libraryId: l.id)) }
        default: return false
        }
        return true
    }

    func runProjectOption(_ v: String) {
        switch v {
        case "renameProject": startRename(v)
        case "newProject": creating = ("project", PanelTextField(key: "create", value: ""))
        case "openProject": onLibrary?(.openProject)
        case "standalone": onLibrary?(.openStandalone)
        default:
            if v.hasPrefix("project:") { onLibrary?(.switchProject(String(v.dropFirst(8)))) }
            if v.hasPrefix("recent:") { onLibrary?(.openRecentProject(String(v.dropFirst(7)))) }
        }
    }

    // MARK: Filter

    func openFilterMenu() {
        let kinds = availableKinds.map { Option(value: "kind:\($0.rawValue)", label: MediaFilter.kindLabels[$0] ?? $0.rawValue, group: "Show", checked: filter.kind == $0) }
        let usage = MediaFilter.Usage.allCases.map {
            Option(value: "usage:\($0.rawValue)", label: MediaFilter.usageLabels[$0] ?? $0.rawValue, group: "Timeline", checked: filter.usage == $0)
        }
        let sort = MediaFilter.Sort.allCases.map { Option(value: "sort:\($0.rawValue)", label: MediaFilter.sortLabels[$0] ?? $0.rawValue, group: "Sort by", checked: filter.sort == $0) }
        openDropdown(.filter, anchor: rightAligned(.filter, width: 208), kinds + usage + sort, nil) { [weak self] v in self?.applyFilterOption(v) }
    }

    func applyFilterOption(_ v: String) {
        let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "kind": filter.kind = MediaFilter.Kind(rawValue: parts[1]) ?? filter.kind
        case "usage": filter.usage = MediaFilter.Usage(rawValue: parts[1]) ?? filter.usage
        case "sort": filter.sort = MediaFilter.Sort(rawValue: parts[1]) ?? filter.sort
        default: return
        }
        binScroll = 0
    }

    // MARK: Tile actions

    /// The tile's main action (Enter, double-click, the hover button): add a project file at the playhead, add a
    /// library file to the project and the timeline, save a copy of a finished export.
    func runPrimary(_ ref: MediaTileRef) {
        switch ref {
        case .media(let id):
            if mediaItem(id)?.category != .fonts { onAddAtPlayhead?(id) }
        case .library(let id):
            guard let l = activeLibrary, libraryAsset(id)?.available == true, !library.busy else { return }
            onLibrary?(.attach(libraryId: l.id, assetId: id))
        case .export(let id):
            guard let l = activeLibrary, export(id)?.status == "complete", !library.busy else { return }
            onLibrary?(.saveOutput(libraryId: l.id, jobId: id))
        }
    }

    // MARK: Context menu

    enum MenuAction: Equatable { case primary, copyPath, rename, delete, relink }
    struct MenuEntry: Equatable { var label: String; var shortcut: String?; var action: MenuAction }

    func menuEntries(_ ref: MediaTileRef) -> [MenuEntry] {
        switch ref {
        case .media(let id): return mediaItem(id).map(mediaEntries) ?? []
        case .library(let id): return libraryAsset(id).map(libraryEntries) ?? []
        case .export(let id): return export(id)?.status == "complete" ? [MenuEntry(label: "Save to…", shortcut: "Enter", action: .primary)] : []
        }
    }

    /// A project file: add at the playhead (not fonts, which no track takes), copy its path, rename, delete.
    func mediaEntries(_ item: MediaBinItem) -> [MenuEntry] {
        let base = [MenuEntry(label: "Copy path", action: .copyPath), MenuEntry(label: "Rename", action: .rename), MenuEntry(label: "Delete", action: .delete)]
        return item.category == .fonts ? base : [MenuEntry(label: "Add at playhead", shortcut: "Enter", action: .primary)] + base
    }

    /// A library file: add it while its original is there (a font goes to the project only), relink a linked one
    /// that is missing.
    func libraryEntries(_ a: LibraryNavModel.Asset) -> [MenuEntry] {
        var e = a.available ? [MenuEntry(label: a.kind == "font" ? "Add to project" : "Add to timeline", shortcut: "Enter", action: .primary)] : []
        if a.linked && !a.available { e.append(MenuEntry(label: "Relink…", action: .relink)) }
        return e
    }

    static let menuW = 200.0

    func menuRect(_ m: Menu) -> CanvasRect {
        let h: Double = m.mode == 0 ? Double(menuEntries(m.target).count) * M.menuItem + 8 : (m.mode == 1 ? 84 : 76)
        let x = min(max(4, m.at.x), size.width - Self.menuW - 4)
        let y = min(max(4, m.at.y), size.height - h - 4)
        return CanvasRect(x: x, y: y, width: Self.menuW, height: h)
    }

    func drawMenu(_ c: CanvasContext, _ m: Menu) {
        let r = menuRect(m)
        PanelStyle.drawPopover(c, r)
        switch m.mode {
        case 0: drawMenuEntries(c, m, r)
        case 1: drawDeleteConfirm(c, m, r)
        default: drawRename(c, m, r)
        }
    }

    func drawMenuEntries(_ c: CanvasContext, _ m: Menu, _ r: CanvasRect) {
        for (i, e) in menuEntries(m.target).enumerated() {
            let ir = CanvasRect(x: r.x + 4, y: r.y + 4 + Double(i) * M.menuItem, width: r.width - 8, height: M.menuItem)
            if hovered == .menuItem(m.assetId, i) { c.fillRoundedRect(ir, radius: PanelTheme.radius, PanelTheme.panelHover) }
            PanelDraw.text(c, e.label, in: CanvasRect(x: ir.x + 8, y: ir.y, width: ir.width - 16, height: ir.height), font: PanelTheme.font(11),
                           color: e.action == .delete ? PanelTheme.red400 : PanelTheme.text1)
            if let s = e.shortcut {
                PanelDraw.text(c, s, in: CanvasRect(x: ir.x + 8, y: ir.y, width: ir.width - 16, height: ir.height), font: PanelTheme.font(10),
                               color: PanelTheme.text2, align: .right)
            }
            hits.add(ir, .menuItem(m.assetId, i))
        }
    }

    func drawDeleteConfirm(_ c: CanvasContext, _ m: Menu, _ r: CanvasRect) {
        let inner = r.insetBy(4)
        c.fillRect(inner, PanelTheme.red950.withAlpha(0.3)); c.fillRect(CanvasRect(x: inner.x, y: inner.y, width: 2, height: inner.height), PanelTheme.red500)
        PanelDraw.text(c, "Delete \(fullName(m.target))?", in: CanvasRect(x: inner.x + 10, y: inner.y + 4, width: inner.width - 14, height: 16), font: PanelTheme.font(10),
                       color: PanelTheme.red400)
        let cb = CanvasRect(x: inner.x + 10, y: inner.y + 24, width: 11, height: 11)
        c.strokeRoundedRect(cb, radius: 2, PanelTheme.neutral400, width: 1)
        if m.removePlacements { PanelIcon.check.draw(c, in: cb, color: PanelTheme.neutral200, lineWidth: 2.5) }
        PanelDraw.text(c, "Also remove all timeline placements (undoable)", in: CanvasRect(x: cb.maxX + 4, y: inner.y + 20, width: inner.width - 30, height: 20),
                       font: PanelTheme.font(9), color: PanelTheme.neutral300)
        hits.add(CanvasRect(x: cb.x, y: inner.y + 20, width: inner.width - 14, height: 20), .removePlacements)
        let del = CanvasRect(x: inner.x + 10, y: inner.maxY - 26, width: 60, height: 24)
        PanelDraw.smallButton(c, del, label: "Delete", fill: hovered == .deleteConfirm(m.assetId) ? PanelTheme.red500 : PanelTheme.red600, color: PanelTheme.white)
        hits.add(del, .deleteConfirm(m.assetId))
        let cancel = CanvasRect(x: del.maxX + 6, y: del.y, width: 60, height: 24)
        PanelDraw.smallButton(c, cancel, label: "Cancel", fill: nil, color: hovered == .deleteCancel ? PanelTheme.neutral200 : PanelTheme.neutral400)
        hits.add(cancel, .deleteCancel)
    }

    func drawRename(_ c: CanvasContext, _ m: Menu, _ r: CanvasRect) {
        let inner = r.insetBy(8)
        let fr = CanvasRect(x: inner.x, y: inner.y, width: inner.width, height: 24)
        c.fillRoundedRect(fr, radius: PanelTheme.radius, PanelTheme.neutral800)
        c.strokeRoundedRect(fr.insetBy(0.5), radius: PanelTheme.radius, PanelTheme.accent.withAlpha(0.6), width: 1)
        PanelDraw.text(c, m.rename?.draft ?? fullName(m.target), in: fr.insetBy(6), font: PanelTheme.font(11), color: PanelTheme.text0)
        hits.add(fr, .renameField)
        let ok = CanvasRect(x: inner.maxX - 60, y: inner.maxY - 24, width: 60, height: 24)
        PanelDraw.smallButton(c, ok, label: "Rename", fill: PanelTheme.primaryFill, color: PanelTheme.onAccent)
        hits.add(ok, .renameOK)
        let cancel = CanvasRect(x: ok.x - 64, y: ok.y, width: 60, height: 24)
        PanelDraw.smallButton(c, cancel, label: "Cancel", fill: nil, color: hovered == .renameCancel ? PanelTheme.neutral200 : PanelTheme.neutral400)
        hits.add(cancel, .renameCancel)
    }

    /// The context menu's presses; false so the caller asks for a redraw.
    func pressMenu(_ hit: Hit) -> Bool {
        switch hit {
        case .menuItem(_, let i): runMenuEntry(i)
        case .removePlacements: menu?.removePlacements.toggle()
        case .deleteConfirm(let id): onDeleteAsset?(id, menu?.removePlacements ?? false); menu = nil
        case .deleteCancel: menu?.mode = 0
        case .renameOK: commitRename()
        case .renameCancel: menu?.mode = 0; menu?.rename = nil
        default: break
        }
        return false
    }

    func runMenuEntry(_ i: Int) {
        guard let m = menu, case let entries = menuEntries(m.target), entries.indices.contains(i) else { return }
        switch entries[i].action {
        case .primary: runPrimary(m.target); menu = nil
        case .copyPath: copyPath(m.target); menu = nil
        case .rename: menu?.mode = 2; menu?.rename = PanelTextField(key: "rename", value: fullName(m.target))
        case .delete: menu?.mode = 1
        case .relink: if let l = activeLibrary { onLibrary?(.relink(libraryId: l.id, assetId: m.assetId)) }; menu = nil
        }
    }

    /// Copy path exists only on project files (`mediaEntries`): their project-relative path, or the file name for
    /// an item the host listed without one (as the bin always did).
    func copyPath(_ ref: MediaTileRef) {
        guard case .media(let id) = ref, let item = mediaItem(id) else { return }
        onCopyPath?(item.path ?? item.name)
    }

    /// The name row of New event / New project; false so the caller asks for a redraw.
    func pressNameRow(_ hit: Hit) -> Bool {
        switch hit {
        case .createConfirm: confirmCreate()
        case .createCancel: creating = nil
        default: break
        }
        return false
    }

    func commitRename() {
        guard let m = menu, let f = m.rename else { return }
        let n = f.draft.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { onRenameAsset?(m.assetId, n) }
        menu = nil
    }
}
