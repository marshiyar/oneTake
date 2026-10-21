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

/// One item of the media bin: a project asset with what the card shows.
public struct MediaBinItem: Equatable {
    public enum Category: String, CaseIterable { case video, images, audio, fonts }
    public var id: String
    public var name: String
    public var path: String?
    public var category: Category
    public var duration: Double?
    /// On the timeline at least once ("Added" badge; used assets sort first).
    public var used: Bool
    public init(id: String, name: String, path: String?, category: Category, duration: Double?, used: Bool) {
        self.id = id; self.name = name; self.path = path; self.category = category; self.duration = duration; self.used = used
    }
    public static let labels: [Category: String] = [.video: "Video", .images: "Images", .audio: "Audio", .fonts: "Fonts"]
    /// FILTER_ORDER.
    public static let order: [Category] = [.video, .images, .audio, .fonts]
}

/// What the library navigator shows (`LibraryView`), filled by the host from the backend.
public struct LibraryNavModel: Equatable {
    public struct Item: Equatable { public var id, name: String
        public init(id: String, name: String) { self.id = id; self.name = name } }
    public struct Project: Equatable { public var id, name, eventId: String
        public init(id: String, name: String, eventId: String) { self.id = id; self.name = name; self.eventId = eventId } }
    public struct Asset: Equatable { public var id, name, kind, eventId: String; public var available: Bool; public var linked: Bool
        public init(id: String, name: String, kind: String, eventId: String, available: Bool = true, linked: Bool = false) {
            self.id = id; self.name = name; self.kind = kind; self.eventId = eventId; self.available = available; self.linked = linked } }
    public struct Export: Equatable { public var id, label, status: String
        public init(id: String, label: String, status: String) { self.id = id; self.label = label; self.status = status } }
    public struct Library: Equatable {
        public var id, name: String
        public var events: [Item]
        public var projects: [Project]
        public var assets: [Asset]
        public var exports: [Export]
        public init(id: String, name: String, events: [Item] = [], projects: [Project] = [], assets: [Asset] = [], exports: [Export] = []) {
            self.id = id; self.name = name; self.events = events; self.projects = projects; self.assets = assets; self.exports = exports
        }
    }
    /// A recently opened project folder (the "Recent" list beside "Open project…").
    public struct RecentProject: Equatable { public var path, name: String
        public init(path: String, name: String) { self.path = path; self.name = name } }
    public var available = false
    public var libraries: [Library] = []
    public var recentProjects: [RecentProject] = []
    public var currentProjectId: String?
    public var isStandalone = false
    public var busy = false
    public var error: String?
    public init() {}
}

/// Commands the navigator issues; the host runs them against `DesktopBackend.libraries` (LibraryCommand).
public enum LibraryNavCommand: Equatable {
    case createLibrary, openLibrary
    case createEvent(libraryId: String, name: String)
    case createProject(libraryId: String, eventId: String, name: String)
    case switchProject(String)
    case importIntoEvent(libraryId: String, eventId: String, linked: Bool)
    case attach(libraryId: String, assetId: String)
    case relink(libraryId: String, assetId: String)
    case saveOutput(libraryId: String, jobId: String)
    case reveal(libraryId: String)
    case openStandalone
    /// Any project folder through the folder dialog, or one from the recent list (its folder).
    case openProject
    case openRecentProject(String)
}

/// The left sidebar: the tab strip (Media; Import media, hide and the panel menu), the library navigator (max 45%),
/// search, and the categorized media bin.
public final class LeftSidebarPanel {
    public enum Hit: Equatable {
        case showSidebar, hideSidebar, importMedia, panelMenu, search, clearSearch
        case tab(LeftSidebarTab)
        case newLibrary, openLibrary, pickLibrary, pickEvent, newEvent, pickProject, newProject
        case toggleMedia, toggleExports, storageMode, importIntoEvent, attach(String), relink(String), saveOutput(String)
        case reveal, openStandalone, openProject, pickRecent, createConfirm, createCancel, createField
        case asset(String)
        case menu(String), menuItem(String, Int), deleteConfirm(String), deleteCancel, removePlacements, renameField, renameOK, renameCancel
        case libraryArea, binArea
    }

    public let layout: PanelLayoutState
    public var items: [MediaBinItem] = []
    public var library = LibraryNavModel()
    public var tab: LeftSidebarTab = .assets
    /// Thumbnail per asset id (filled by the host from the preview decoder / backend thumbnails).
    public var thumbnail: (String) -> CanvasImage? = { _ in nil }
    /// Level bars (0…1) for an audio row (`bars`), filled by the host from the backend waveform.
    public var bars: (String) -> [Double]? = { _ in nil }
    public var importing = false

    public var onImport: (() -> Void)?
    public var onAddAtPlayhead: ((String) -> Void)?
    public var onRenameAsset: ((String, String) -> Void)?
    public var onDeleteAsset: ((String, Bool) -> Void)?
    public var onCopyPath: ((String) -> Void)?
    public var onLibrary: ((LibraryNavCommand) -> Void)?
    public var onChange: (() -> Void)?

    public private(set) var hits = HitMap<Hit>()
    public let dropdown = PanelDropdown()
    public var hovered: Hit?
    public private(set) var search: PanelTextField?
    public var searchQuery = ""
    var selectedLibraryId: String?
    var selectedEventId: String?
    var mediaOpen = false
    var exportsOpen = false
    var linkedImport = false
    var creating: (kind: String, field: PanelTextField)?
    public struct Menu: Equatable { public var assetId: String; public var at: CanvasPoint; public var mode: Int = 0; public var removePlacements = false
        public var rename: PanelTextField? }
    public private(set) var menu: Menu?
    var binScroller = PanelScroller(), libScroller = PanelScroller()
    var binScroll: Double { get { binScroller.offset } set { binScroller.set(newValue, max: .infinity) } }
    var libScroll: Double { get { libScroller.offset } set { libScroller.set(newValue, max: .infinity) } }
    var binMax = 0.0, libMax = 0.0
    /// Asks the host to call `tick` (~60 Hz) until it returns false (wheel glides, scrollbar fades).
    public var onAnimate: (() -> Void)?
    var libRect = CanvasRect(x: 0, y: 0, width: 0, height: 0), binRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    var size = CanvasSize(0, 0)
    var lastClick: (id: String, at: Double)?

    public init(layout: PanelLayoutState) {
        self.layout = layout
        tab = layout.prefs.sidebarTab ?? .assets
        if tab != .assets { tab = .assets }   // getPersistedTab: only "assets" and "blocks" persist; Scenes/Elements need content
    }

    /// Tabs shown (getSidebarTabs): Media always; Scenes with sub-compositions; Elements with blocks (none natively).
    public var availableTabs: [LeftSidebarTab] { [.assets] }
    /// In the dock: the dock's tab bar names the panel and its × closes it, so the strip keeps only Import media and
    /// the panel menu (no Media tab, no hide button).
    public var docked = false
    /// The strip's tabs: none in the dock.
    var stripTabs: [LeftSidebarTab] { docked ? [] : availableTabs }
    /// Where Import media ends: the hide button, or the menu button when docked (no hide button).
    func hideRect(_ strip: CanvasRect) -> CanvasRect { PanelTabStrip.buttonRect(strip, index: docked ? 0 : 1) }
    func drawHideButton(_ c: CanvasContext, _ r: CanvasRect) {
        guard !docked else { return }
        PanelTabStrip.iconButton(c, r, icon: .sidebarHideLeft, hovered: hovered == .hideSidebar)
        hits.add(r, .hideSidebar)
    }
    public static let tabLabels: [LeftSidebarTab: String] = [.assets: "Media", .compositions: "Scenes", .blocks: "Elements"]

    /// What the status line says for the control under the pointer.
    public var hint: String? {
        switch hovered {
        case .importMedia?: "Import media files into the project"
        case .hideSidebar?: "Hide the panel"
        case .showSidebar?: "Show the panel"
        case .panelMenu?: "Panel menu"
        case .asset?: "Drag onto the timeline or the stage · double-click to add at the playhead · right-click for more"
        default: nil
        }
    }

    var activeLibrary: LibraryNavModel.Library? {
        let libs = library.libraries
        return libs.first { $0.id == selectedLibraryId } ?? libs.first { $0.projects.contains { $0.id == library.currentProjectId } } ?? libs.first
    }
    var activeEvent: LibraryNavModel.Item? {
        guard let l = activeLibrary else { return nil }
        return l.events.first { $0.id == selectedEventId } ?? l.events.first
    }

    public var filteredItems: [MediaBinItem] {
        guard !searchQuery.isEmpty else { return items }
        let q = searchQuery.lowercased()
        return items.filter { $0.name.lowercased().contains(q) }
    }

    /// Categorized, used-first (AssetsTab categorized).
    public var categorized: [(MediaBinItem.Category, [MediaBinItem])] {
        let f = filteredItems
        return MediaBinItem.order.compactMap { cat in
            let list = f.filter { $0.category == cat }
            guard !list.isEmpty else { return nil }
            return (cat, list.enumerated().sorted { ($0.element.used ? 0 : 1, $0.offset) < ($1.element.used ? 0 : 1, $1.offset) }.map(\.element))
        }
    }

    // MARK: Draw

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        self.size = size
        hits.reset()
        let r = CanvasRect(x: 0, y: 0, width: size.width, height: size.height)
        if layout.effectiveLeftCollapsed {   // the rail
            hits.add(PanelTabStrip.drawRail(c, r, icon: .sidebarShowLeft, hovered: hovered == .showSidebar), .showSidebar)
            return
        }
        c.fillRect(r, PanelTheme.panelBg)
        c.withState {
            c.clip(r)
            var y = drawTabStrip(c, CanvasRect(x: 0, y: 0, width: r.width, height: PanelTabStrip.height))
            if library.available || onLibrary != nil {
                y += drawLibrary(c, CanvasRect(x: 0, y: y, width: r.width, height: r.height * 0.45))
                PanelDraw.hline(c, x0: 0, x1: r.maxX, y: y, PanelTheme.panelHairline)
                y += 1
            }
            drawAssets(c, CanvasRect(x: 0, y: y, width: r.width, height: max(0, r.height - y)))
        }
        if let m = menu { drawMenu(c, m) }
        dropdown.draw(c)
    }

    // MARK: Library navigator (px-3 pt-3 pb-2 space-y-2 text-neutral-300)

    func drawLibrary(_ c: CanvasContext, _ box: CanvasRect) -> Double {
        let font = PanelTheme.font(PanelTheme.textXs)
        let x = box.x + 12, w = box.width - 24
        var y = box.y + 12 - libScroll
        // text-xs rows are 16px line boxes, controls 28px (py-1.5 + 16), stacked with space-y-2 (8px).
        let rowH = 28.0, lineH = 16.0, gap = 8.0
        func button(_ label: String, _ hit: Hit, right: Double, at yy: Double, height: Double = 16, enabled: Bool = true) -> Double {
            let tw = c.measureText(label, font: font).width
            let br = CanvasRect(x: right - tw, y: yy + (height - lineH) / 2, width: tw, height: lineH)
            let color = !enabled ? PanelTheme.neutral400.withAlpha(0.4) : (hovered == hit ? PanelTheme.white : PanelTheme.neutral400)
            PanelDraw.text(c, label, in: br, font: font, color: color)
            if enabled { hits.add(br, hit) }
            return br.x
        }
        func select(_ text: String, _ hit: Hit, _ rect: CanvasRect) {   // control: bg-panel-input rounded px-2 py-1.5 text-xs
            c.fillRoundedRect(rect, radius: PanelTheme.radius, PanelTheme.panelInput)
            PanelDraw.text(c, text, in: CanvasRect(x: rect.x + 12, y: rect.y + 6, width: rect.width - 34, height: lineH), font: font, color: PanelTheme.neutral200)
            PanelIcon.selectCaret.draw(c, in: CanvasRect(x: rect.maxX - 20, y: rect.y + (rect.height - 12) / 2, width: 12, height: 12),
                                       color: hovered == hit ? PanelTheme.neutral200 : PanelTheme.neutral400)
            hits.add(rect, hit)
        }
        func link(_ label: String, _ hit: Hit, color: CanvasColor = PanelTheme.neutral400) {   // button block, text-neutral-400 hover:text-white
            let r = CanvasRect(x: x, y: y, width: c.measureText(label, font: font).width, height: lineH)
            PanelDraw.text(c, label, in: r, font: font, color: hovered == hit ? PanelTheme.white : color)
            hits.add(r, hit); y += lineH + gap
        }
        func summary(_ label: String, open: Bool, _ hit: Hit) {   // <summary className="text-xs text-neutral-400"> + native marker
            let color = hovered == hit ? PanelTheme.neutral200 : PanelTheme.neutral400
            (open ? PanelIcon.caretDown : PanelIcon.caretRight).draw(c, in: CanvasRect(x: x, y: y + 2, width: 12, height: 12), color: color)
            PanelDraw.text(c, label, in: CanvasRect(x: x + 13, y: y, width: w - 13, height: lineH), font: font, color: color)
            hits.add(CanvasRect(x: x, y: y, width: w, height: lineH), hit); y += lineH + gap
        }
        c.withState {
            c.clip(box)
            // Header: "Libraries" + New library / Open
            PanelDraw.text(c, "Libraries", in: CanvasRect(x: x, y: y, width: w / 2, height: lineH), font: PanelTheme.font(PanelTheme.textXs, .medium), color: PanelTheme.neutral300)
            let open = button("Open", .openLibrary, right: x + w, at: y, enabled: !library.busy)
            _ = button("New library", .newLibrary, right: open - 12, at: y, enabled: !library.busy)   // flex gap-3
            y += lineH + gap
            if let lib = activeLibrary {
                select(lib.name, .pickLibrary, CanvasRect(x: x, y: y, width: w, height: rowH)); y += rowH + gap
                let ev = activeEvent
                let evBtnW = c.measureText("New event", font: font).width
                select(ev?.name ?? "No events", .pickEvent, CanvasRect(x: x, y: y, width: w - evBtnW - 8, height: rowH))
                _ = button("New event", .newEvent, right: x + w, at: y, height: rowH, enabled: !library.busy); y += rowH + gap
                let projects = lib.projects.filter { $0.eventId == ev?.id }
                let cur = projects.first { $0.id == library.currentProjectId }
                let pBtnW = c.measureText("New project", font: font).width
                select(cur?.name ?? "Select project", .pickProject, CanvasRect(x: x, y: y, width: w - pBtnW - 8, height: rowH))
                _ = button("New project", .newProject, right: x + w, at: y, height: rowH, enabled: !library.busy && ev != nil); y += rowH + gap
                if let cr = creating {
                    let fr = CanvasRect(x: x, y: y, width: w - 100, height: rowH)
                    c.fillRoundedRect(fr, radius: PanelTheme.radius, PanelTheme.panelInput)
                    let text = cr.field.draft.isEmpty ? (cr.kind == "event" ? "Event name" : "Project name") : cr.field.draft
                    PanelDraw.text(c, text, in: fr.insetBy(8), font: font, color: cr.field.draft.isEmpty ? PanelTheme.neutral500 : PanelTheme.neutral200)
                    hits.add(fr, .createField)
                    let cancel = button("Cancel", .createCancel, right: x + w, at: y, height: rowH)
                    _ = button("Create", .createConfirm, right: cancel - 8, at: y, height: rowH, enabled: !cr.field.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    y += rowH + gap
                }
                // ▶ Library media (N)
                let assets = lib.assets.filter { $0.eventId == ev?.id }
                summary("Library media (\(lib.assets.count))", open: mediaOpen, .toggleMedia)
                if mediaOpen {
                    select(linkedImport ? "Link to original files" : "Copy into library", .storageMode, CanvasRect(x: x, y: y, width: w, height: rowH)); y += rowH + gap
                    link(library.busy ? "Working…" : "Import into event…", .importIntoEvent)
                    for a in assets.prefix(40) {
                        let suffix = !a.available ? " (offline)" : ""
                        let action = a.kind == "font" ? "Add to project" : "Add to timeline"
                        let ax = button(action, .attach(a.id), right: x + w, at: y, enabled: a.available && !library.busy)
                        var nameRight = ax - 8
                        if a.linked && !a.available { nameRight = button("Relink", .relink(a.id), right: ax - 8, at: y) - 8 }
                        PanelDraw.text(c, a.name + suffix, in: CanvasRect(x: x, y: y, width: max(0, nameRight - x), height: lineH), font: font, color: PanelTheme.neutral300)
                        y += lineH + gap
                    }
                }
                if !lib.exports.isEmpty {
                    summary("Library exports (\(lib.exports.count))", open: exportsOpen, .toggleExports)
                    if exportsOpen {
                        for e in lib.exports.prefix(40) {
                            var right = x + w
                            if e.status == "complete" { right = button("Save as…", .saveOutput(e.id), right: right, at: y) - 8 }
                            PanelDraw.text(c, "\(e.label): \(e.status)", in: CanvasRect(x: x, y: y, width: right - x, height: lineH), font: font, color: PanelTheme.neutral300)
                            y += lineH + gap
                        }
                    }
                }
                link("Show library in Finder", .reveal)
            } else {
                for line in InspectorPanel.wrap("Your existing project stays available. Create a library to organize new projects and shared media.", perLine: max(20, Int(w / 6.5))) {
                    PanelDraw.text(c, line, in: CanvasRect(x: x, y: y, width: w, height: 16), font: font, color: PanelTheme.neutral500); y += 16
                }
                y += 8
            }
            if !library.isStandalone { link("Open existing standalone project", .openStandalone) }
            else if activeLibrary != nil {
                PanelDraw.text(c, "Editing the existing standalone project", in: CanvasRect(x: x, y: y, width: w, height: lineH), font: font, color: PanelTheme.neutral500); y += lineH + gap
            }
            // Any project folder (Cmd/Ctrl+O) and the recently opened ones: the only place to open projects on Linux and
            // Windows, which have no menu bar.
            let openRight = x + c.measureText("Open project…", font: font).width
            _ = button("Open project…", .openProject, right: openRight, at: y, enabled: !library.busy)
            _ = button("Recent", .pickRecent, right: openRight + 16 + c.measureText("Recent", font: font).width, at: y,
                       enabled: !library.busy && !library.recentProjects.isEmpty)
            y += lineH + gap
            if let err = library.error {
                for line in InspectorPanel.wrap(err, perLine: max(20, Int(w / 6.5))) {
                    PanelDraw.text(c, line, in: CanvasRect(x: x, y: y, width: w, height: 16), font: font, color: PanelTheme.red400); y += 16
                }
            }
        }
        let contentH = y + libScroll - box.y   // the last row's space-y gap stands in for pb-2 (8px)
        let h = min(box.height, contentH)
        libMax = max(0, contentH - h)
        libScroller.clamp(max: libMax)
        libRect = CanvasRect(x: box.x, y: box.y, width: box.width, height: h)
        PanelScrollbar.draw(c, track: libRect, offset: libScroll, content: contentH, hovered: false, opacity: libScroller.barOpacity)
        hits.add(libRect, .libraryArea)
        // The region is scrollable; keep earlier hits on top of the area hit.
        hits = { var m = HitMap<Hit>(); m.add(libRect, .libraryArea); for r in hits.regions where r.action != .libraryArea { m.add(r.rect, r.action) }; return m }()
        return h
    }

    // MARK: Tab strip (the tabs; Import media, hide and the panel menu at the right end)

    func drawTabStrip(_ c: CanvasContext, _ strip: CanvasRect) -> Double {
        PanelTabStrip.drawBackground(c, strip)
        let tabs = stripTabs
        let tabRects = PanelTabStrip.tabRects(c, strip, labels: tabs.map { Self.tabLabels[$0]! })
        for (rect, t) in zip(tabRects, tabs) {
            PanelTabStrip.tab(c, rect, label: Self.tabLabels[t]!, active: tab == t, hovered: hovered == .tab(t))
            hits.add(rect, .tab(t))
        }
        let hide = hideRect(strip), menu = PanelTabStrip.buttonRect(strip, index: 0)
        drawHideButton(c, hide)
        PanelTabStrip.iconButton(c, menu, icon: .panelMenu, hovered: hovered == .panelMenu, open: dropdown.key == "\(Hit.panelMenu)")
        hits.add(menu, .panelMenu)
        // Import media: plus and label (px-2, gap 6) before the icons; only the plus when the strip has no room for the label.
        let label = importing ? "Importing…" : "Import media"
        let font = PanelTheme.font(11, .medium), bh = PanelTabStrip.buttonSize, glyph = 11.0
        let labelled = 8 + glyph + 6 + c.measureText(label, font: font).width + 8
        let showLabel = labelled <= hide.x - 4 - (tabRects.last?.maxX ?? strip.x) - 4
        let bw = showLabel ? labelled : bh
        let ib = CanvasRect(x: hide.x - 4 - bw, y: hide.y, width: bw, height: bh)
        c.fillRoundedRect(ib, radius: PanelTheme.radius, hovered == .importMedia ? PanelTheme.panelHover : PanelTheme.panelInput)
        let tc = hovered == .importMedia ? PanelTheme.text1 : PanelTheme.text3
        let gx = showLabel ? ib.x + 8 : ib.midX - glyph / 2
        PanelIcon.plus.draw(c, in: CanvasRect(x: gx, y: ib.y + (bh - glyph) / 2, width: glyph, height: glyph), color: tc, lineWidth: 2.5)
        if showLabel {
            PanelDraw.text(c, label, in: CanvasRect(x: gx + glyph + 6, y: ib.y, width: ib.maxX - 8 - gx - glyph - 6, height: bh), font: font, color: tc)
        }
        if !importing { hits.add(ib, .importMedia) }
        return strip.height
    }

    // MARK: Media bin

    func drawAssets(_ c: CanvasContext, _ r: CanvasRect) {
        binRect = r
        hits.add(r, .binArea)
        var y = r.y + 10   // px-4 pt-2.5
        let x = r.x + 16, w = r.width - 32
        let all = items
        if !all.isEmpty {   // SearchInput: rounded-md bg-panel-input px-2.5 py-[5px] gap-1.5; 12px glyph, 11px text (16.5 line)
            let sr = CanvasRect(x: x, y: y, width: w, height: 26.5)
            c.fillRoundedRect(sr, radius: PanelTheme.radiusMd, PanelTheme.panelInput)
            drawMagnifier(c, CanvasRect(x: sr.x + 10, y: sr.y + (sr.height - 12) / 2, width: 12, height: 12))
            let focused = search != nil
            let text = focused ? search!.draft : searchQuery
            let tr = CanvasRect(x: sr.x + 28, y: sr.y + 5, width: sr.width - 48, height: 16.5)
            PanelDraw.text(c, text.isEmpty && !focused ? "Search assets..." : text, in: tr, font: PanelTheme.font(11),
                           color: text.isEmpty ? PanelTheme.text5 : PanelTheme.text1)
            if focused { let tw = c.measureText(text, font: PanelTheme.font(11)).width
                c.fillRect(CanvasRect(x: tr.x + tw + 1, y: tr.y + 2, width: 1, height: 12.5), PanelTheme.text1) }
            hits.add(sr, .search)
            if !searchQuery.isEmpty || !(search?.draft.isEmpty ?? true) {
                let cr = CanvasRect(x: sr.maxX - 20, y: sr.y + 6, width: 14, height: 14)
                PanelIcon.close.draw(c, in: cr.insetBy(2), color: PanelTheme.text5); hits.add(cr, .clearSearch)
            }
            y = sr.maxY + 8 + 6 + 4   // mb-2, pb-1.5, then the list's mt-1
        }
        let groups = categorized
        let list = CanvasRect(x: r.x, y: y, width: r.width, height: max(0, r.maxY - y))
        c.withState {
            c.clip(list)
            var cy = y - binScroll
            if groups.isEmpty {
                if !searchQuery.isEmpty {
                    PanelDraw.text(c, "No assets match “\(searchQuery)”", in: CanvasRect(x: list.x, y: list.y + list.height / 2 - 20, width: list.width, height: 16),
                                   font: PanelTheme.font(11), color: PanelTheme.neutral500, align: .center)
                    let b = CanvasRect(x: list.x + list.width / 2 - 40, y: list.y + list.height / 2 + 2, width: 80, height: 22)
                    c.fillRoundedRect(b, radius: PanelTheme.radiusMd, PanelTheme.panelInput)
                    PanelDraw.text(c, "Clear search", in: b, font: PanelTheme.font(11, .medium), color: hovered == .clearSearch ? PanelTheme.text1 : PanelTheme.text3, align: .center)
                    hits.add(b, .clearSearch)
                } else {
                    let ic = CanvasRect(x: list.x + list.width / 2 - 12, y: list.y + list.height / 2 - 24, width: 24, height: 24)
                    PanelIcon.upload.draw(c, in: ic, color: PanelTheme.neutral700)
                    PanelDraw.text(c, "Drop media files here", in: CanvasRect(x: list.x, y: ic.maxY + 8, width: list.width, height: 14),
                                   font: PanelTheme.font(10), color: PanelTheme.neutral600, align: .center)
                }
            }
            for (cat, list) in groups {
                // flex items-center gap-2 px-4 py-2 border-t border-panel-border: h3 12/600 (18px line), count 11px text-5.
                PanelDraw.hline(c, x0: r.x, x1: r.maxX, y: cy, PanelTheme.panelBorder)
                let t = PanelDraw.text(c, MediaBinItem.labels[cat]!, in: CanvasRect(x: x, y: cy + 9, width: w, height: 18), font: PanelTheme.font(12, .semibold), color: PanelTheme.text1)
                PanelDraw.text(c, "\(list.count)", in: CanvasRect(x: x + t.width + 8, y: cy + 9.75, width: 40, height: 16.5), font: PanelTheme.font(11), color: PanelTheme.text5)
                cy += 35
                switch cat {
                case .video, .images:
                    let gx = r.x + 8, gw = r.width - 16, gap = 4.0, cw = (gw - gap) / 2
                    for (i, item) in list.enumerated() {
                        let col = i % 2
                        let cardH = drawCard(c, CanvasRect(x: gx + Double(col) * (cw + gap), y: cy, width: cw, height: 0), item, measureOnly: false)
                        if col == 1 || i == list.count - 1 { cy += cardH + gap }
                    }
                    cy += 4   // the category's mb-1 (pb-1 of the grid is the trailing row gap)
                case .audio, .fonts:
                    for item in list { cy += drawRow(c, CanvasRect(x: r.x, y: cy, width: r.width, height: 44), item) }
                    cy += 4
                }
            }
            binMax = max(0, cy + binScroll - list.maxY + 8)
            binScroller.clamp(max: binMax)
        }
        PanelScrollbar.draw(c, track: list, offset: binScroll, content: list.height + binMax, hovered: false, opacity: binScroller.barOpacity)
    }

    /// SearchInput's glyph: 256 view box, circle (116,116) r76 and a round-capped line to (232,232), stroke 22.
    func drawMagnifier(_ c: CanvasContext, _ r: CanvasRect) {
        c.strokeSVG(["M192 116a76 76 0 1 0-152 0 76 76 0 1 0 152 0Z"], viewBox: 256, in: r, PanelTheme.text5, width: 22, round: false)
        c.strokeSVG(["M170 170 232 232"], viewBox: 256, in: r, PanelTheme.text5, width: 22)
    }

    /// AssetCard: `p-1 rounded-md flex-col gap-1`; an aspect-video tile (`rounded bg-neutral-900`) holding the frame
    /// (video: object-contain, image: object-cover), the "Added" and duration badges (`top-1 left-1/right-1
    /// text-[9px] leading-none px-1.5 py-[3px] rounded bg-neutral-950/80`), then the middle-truncated name
    /// (`text-[10px] leading-tight`, text-2 when used, text-4 otherwise). Hover: `bg-neutral-800/40`.
    @discardableResult
    func drawCard(_ c: CanvasContext, _ r: CanvasRect, _ item: MediaBinItem, measureOnly: Bool) -> Double {
        let tileW = r.width - 8, tileH = tileW * 9 / 16
        let h = 4 + tileH + 4 + 12.5 + 4
        let card = CanvasRect(x: r.x, y: r.y, width: r.width, height: h)
        let hov = hovered == .asset(item.id) || menu?.assetId == item.id
        if hov { c.fillRoundedRect(card, radius: PanelTheme.radiusMd, PanelTheme.neutral800.withAlpha(0.4)) }
        let tile = CanvasRect(x: r.x + 4, y: r.y + 4, width: tileW, height: tileH)
        c.fillRoundedRect(tile, radius: PanelTheme.radius, PanelTheme.neutral900)
        if let img = thumbnail(item.id) {
            c.withState {
                c.clip(.roundedRect(tile, radius: PanelTheme.radius))
                let ia = Double(img.width) / max(1, Double(img.height)), ta = tile.width / tile.height
                let cover = item.category == .images
                let wide = ia > ta
                let dw = (wide == cover) ? tile.height * ia : tile.width, dh = (wide == cover) ? tile.height : tile.width / ia
                c.drawImage(img, in: CanvasRect(x: tile.x + (tile.width - dw) / 2, y: tile.y + (tile.height - dh) / 2, width: dw, height: dh))
            }
        } else if item.category == .video {   // VideoFrameThumbnail without a frame: bg-neutral-800, "VIDEO" 9px
            c.fillRect(tile, PanelTheme.neutral800)
            PanelDraw.text(c, "VIDEO", in: tile, font: PanelTheme.font(9, .medium), color: PanelTheme.neutral600, align: .center)
        } else {
            let ext = (item.name as NSString).pathExtension.lowercased()
            PanelDraw.text(c, ext, in: tile, font: PanelTheme.font(10, .medium), color: PanelTheme.neutral600, align: .center)
        }
        func badge(_ s: String, _ font: CanvasFont, _ color: CanvasColor, right: Bool) {
            let bw = c.measureText(s, font: font).width + 12
            let b = CanvasRect(x: right ? tile.maxX - 4 - bw : tile.x + 4, y: tile.y + 4, width: bw, height: 15)
            c.fillRoundedRect(b, radius: PanelTheme.radius, PanelTheme.neutral950.withAlpha(0.8))
            PanelDraw.text(c, s, in: CanvasRect(x: b.x + 6, y: b.y + 3, width: bw - 12, height: 9), font: font, color: color)
        }
        if item.used { badge("Added", PanelTheme.font(9, .semibold), PanelTheme.text1, right: false) }
        if let d = item.duration, let s = Self.binDuration(d) { badge(s, PanelTheme.font(9, .medium), PanelTheme.text2, right: true) }
        PanelDraw.text(c, Self.truncateMiddle(item.name, 22), in: CanvasRect(x: r.x + 4, y: tile.maxY + 4, width: r.width - 8, height: 12.5),
                       font: PanelTheme.font(10), color: item.used ? PanelTheme.text2 : PanelTheme.text4, align: .center)
        hits.add(card, .asset(item.id))
        return h
    }

    /// assetHelpers.truncateMiddle: keep ⅔ head, ⅓ tail around one "…".
    static func truncateMiddle(_ s: String, _ maxLen: Int) -> String {
        let ch = Array(s)
        guard ch.count > maxLen else { return s }
        let keep = maxLen - 1, tail = keep / 3, head = keep - tail
        return String(ch[0..<head]) + "…" + String(ch[(ch.count - tail)...])
    }

    /// assetHelpers.formatDuration: MM:SS of the rounded seconds; nothing for non-positive or non-finite values.
    static func binDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let t = Int(seconds.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }


    /// AudioRow (`px-4 py-1.5 flex items-center gap-2.5`, hover `bg-panel-surface-hover`): a 28px play button
    /// (12px play triangle, text-5 → text-3 on hover), the name (12px medium, text-1 used / text-3), the raw
    /// duration in seconds (11px text-5) and, while level peaks exist, a 14px bar strip (`gap-[2px] mt-0.5`, bars
    /// `rgba(60,230,172,.5+v*.5)` at least 10% tall). FontRow (`px-2.5 py-1.5 border-l-2`): a 50×32 tile with the
    /// extension (9px neutral-700), the name (text-xs medium) over the extension (10px neutral-600).
    func drawRow(_ c: CanvasContext, _ r: CanvasRect, _ item: MediaBinItem) -> Double {
        let hov = hovered == .asset(item.id) || menu?.assetId == item.id
        if item.category == .fonts {
            let h = 44.0
            let row = CanvasRect(x: r.x, y: r.y, width: r.width, height: h)
            if hov { c.fillRect(row, PanelTheme.neutral800.withAlpha(0.5)) }
            let tile = CanvasRect(x: r.x + 12, y: r.y + 6, width: 50, height: 32)
            c.fillRoundedRect(tile, radius: PanelTheme.radius, PanelTheme.neutral900)
            let ext = (item.name as NSString).pathExtension.lowercased()
            PanelDraw.text(c, ext, in: tile, font: PanelTheme.font(9, .medium), color: PanelTheme.neutral700, align: .center)
            let tx = tile.maxX + 10, tw = max(0, r.maxX - 10 - tx)
            let base = (item.name as NSString).deletingPathExtension
            PanelDraw.text(c, base, in: CanvasRect(x: tx, y: r.y + 6.5, width: tw, height: 16), font: PanelTheme.font(12, .medium),
                           color: item.used ? PanelTheme.text1 : PanelTheme.text3)
            PanelDraw.text(c, ext, in: CanvasRect(x: tx, y: r.y + 22.5, width: tw, height: 15), font: PanelTheme.font(10), color: PanelTheme.neutral600)
            hits.add(row, .asset(item.id))
            return h
        }
        let levels = bars(item.id) ?? []
        let colH = levels.isEmpty ? 14.0 : 14 + 2 + 14
        let h = 12 + max(28, colH)
        let row = CanvasRect(x: r.x, y: r.y, width: r.width, height: h)
        if hov { c.fillRect(row, PanelTheme.panelHover.withAlpha(0.5)) }
        let play = CanvasRect(x: r.x + 16, y: r.y + (h - 28) / 2, width: 28, height: 28)
        c.fillSVG(["M6 4 20 12 6 20Z"], viewBox: 24, in: CanvasRect(x: play.x + 8, y: play.y + 8, width: 12, height: 12), hov ? PanelTheme.text3 : PanelTheme.text5)
        let tx = play.maxX + 10, right = r.maxX - 16
        let colY = r.y + (h - colH) / 2
        let durText = item.duration.flatMap { $0 > 0 ? PanelFormat.number($0, decimals: 3) + "s" : nil }
        let durW = durText.map { c.measureText($0, font: PanelTheme.font(11)).width + 6 } ?? 0
        let ns = PanelDraw.text(c, item.name, in: CanvasRect(x: tx, y: colY, width: max(0, right - tx - durW), height: 14), font: PanelTheme.font(12, .medium),
                                color: item.used ? PanelTheme.text1 : PanelTheme.text3)
        if let durText {
            PanelDraw.text(c, durText, in: CanvasRect(x: tx + ns.width + 6, y: colY, width: durW, height: 14), font: PanelTheme.font(11), color: PanelTheme.text5)
        }
        if !levels.isEmpty {
            let strip = CanvasRect(x: tx, y: colY + 16, width: max(0, right - tx), height: 14)
            let gap = 2.0, bw = max(0.5, (strip.width - gap * Double(levels.count - 1)) / Double(levels.count))
            for (i, v) in levels.enumerated() {
                let lv = max(0, min(1, v)), bh = strip.height * max(0.1, lv)
                c.fillRoundedRect(CanvasRect(x: strip.x + Double(i) * (bw + gap), y: strip.maxY - bh, width: bw, height: bh), radius: 1,
                                  PanelTheme.mint.withAlpha(0.5 + lv * 0.5))
            }
        }
        hits.add(row, .asset(item.id))
        return h
    }

    // MARK: Context menu

    static let menuItems = ["Add at playhead", "Copy path", "Rename", "Delete"]
    static let menuW = 200.0

    func menuRect(_ m: Menu) -> CanvasRect {
        let h: Double = m.mode == 0 ? Double(Self.menuItems.count) * 28 + 8 : (m.mode == 1 ? 84 : 76)
        let x = min(max(4, m.at.x), size.width - Self.menuW - 4)
        let y = min(max(4, m.at.y), size.height - h - 4)
        return CanvasRect(x: x, y: y, width: Self.menuW, height: h)
    }

    func drawMenu(_ c: CanvasContext, _ m: Menu) {
        let r = menuRect(m)
        PanelStyle.drawPopover(c, r)
        guard let item = items.first(where: { $0.id == m.assetId }) else { return }
        switch m.mode {
        case 0:
            for (i, label) in Self.menuItems.enumerated() {
                let ir = CanvasRect(x: r.x + 4, y: r.y + 4 + Double(i) * 28, width: r.width - 8, height: 28)
                if hovered == .menuItem(m.assetId, i) { c.fillRoundedRect(ir, radius: PanelTheme.radius, PanelStyle.menuItemHover.withAlpha(0.08)) }
                PanelDraw.text(c, label, in: CanvasRect(x: ir.x + 8, y: ir.y, width: ir.width - 16, height: ir.height), font: PanelTheme.font(11),
                               color: i == 3 ? PanelTheme.red400 : PanelTheme.neutral200)
                hits.add(ir, .menuItem(m.assetId, i))
            }
        case 1:   // confirm delete
            let inner = r.insetBy(4)
            c.fillRect(inner, PanelTheme.red950.withAlpha(0.3)); c.fillRect(CanvasRect(x: inner.x, y: inner.y, width: 2, height: inner.height), PanelTheme.red500)
            PanelDraw.text(c, "Delete \(item.name)?", in: CanvasRect(x: inner.x + 10, y: inner.y + 4, width: inner.width - 14, height: 16), font: PanelTheme.font(10), color: PanelTheme.red400)
            let cb = CanvasRect(x: inner.x + 10, y: inner.y + 24, width: 11, height: 11)
            c.strokeRoundedRect(cb, radius: 2, PanelTheme.neutral400, width: 1)
            if m.removePlacements { PanelIcon.check.draw(c, in: cb, color: PanelTheme.neutral200, lineWidth: 2.5) }
            PanelDraw.text(c, "Also remove all timeline placements (undoable)", in: CanvasRect(x: cb.maxX + 4, y: inner.y + 20, width: inner.width - 30, height: 20),
                           font: PanelTheme.font(9), color: PanelTheme.neutral300)
            hits.add(CanvasRect(x: cb.x, y: inner.y + 20, width: inner.width - 14, height: 20), .removePlacements)
            let del = CanvasRect(x: inner.x + 10, y: inner.maxY - 24, width: 56, height: 20)
            PanelDraw.smallButton(c, del, label: "Delete", fill: hovered == .deleteConfirm(m.assetId) ? PanelTheme.red500 : PanelTheme.red600, color: PanelTheme.white)
            hits.add(del, .deleteConfirm(m.assetId))
            let cancel = CanvasRect(x: del.maxX + 6, y: del.y, width: 56, height: 20)
            PanelDraw.smallButton(c, cancel, label: "Cancel", fill: nil, color: hovered == .deleteCancel ? PanelTheme.neutral200 : PanelTheme.neutral400)
            hits.add(cancel, .deleteCancel)
        default:  // rename
            let inner = r.insetBy(8)
            let fr = CanvasRect(x: inner.x, y: inner.y, width: inner.width, height: 24)
            c.fillRoundedRect(fr, radius: PanelTheme.radius, PanelTheme.neutral800)
            c.strokeRoundedRect(fr.insetBy(0.5), radius: PanelTheme.radius, PanelTheme.accent.withAlpha(0.6), width: 1)
            let t = m.rename?.draft ?? item.name
            PanelDraw.text(c, t, in: fr.insetBy(6), font: PanelTheme.font(11), color: PanelTheme.white)
            hits.add(fr, .renameField)
            let ok = CanvasRect(x: inner.maxX - 56, y: inner.maxY - 22, width: 56, height: 20)
            PanelDraw.smallButton(c, ok, label: "Rename", fill: PanelTheme.accent.withAlpha(hovered == .renameOK ? 1 : 0.8), color: PanelTheme.white)
            hits.add(ok, .renameOK)
            let cancel = CanvasRect(x: ok.x - 60, y: ok.y, width: 56, height: 20)
            PanelDraw.smallButton(c, cancel, label: "Cancel", fill: nil, color: hovered == .renameCancel ? PanelTheme.neutral200 : PanelTheme.neutral400)
            hits.add(cancel, .renameCancel)
        }
    }

    // MARK: Input

    public var isEditingText: Bool { search != nil || creating != nil || menu?.rename != nil }

    func openDropdown(_ hit: Hit, _ options: [PanelDropdown.Option], _ selected: String?, _ pick: @escaping (String) -> Void) {
        guard let a = hits.rect(where: { $0 == hit }), !options.isEmpty else { return }
        dropdown.open(key: "\(hit)", options: options, selected: selected, anchor: a, bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)) { [weak self] v in
            pick(v); self?.onChange?()
        }
        onChange?()
    }

    /// Asset under a press that has not moved yet; it becomes `draggingAssetId` after a few pixels (AssetCard drag).
    var pressedAsset: (id: String, at: CanvasPoint)?
    /// A bin asset being dragged out of the sidebar (the host drops it on the timeline or the stage).
    public private(set) var draggingAssetId: String?
    static let dragThreshold = 4.0

    /// Ends a press: a drag stops (the host has already seen where it ended).
    public func pointerUp(_ p: CanvasPoint) {
        pressedAsset = nil
        lastDraggedAssetId = draggingAssetId
        if draggingAssetId != nil { draggingAssetId = nil; onChange?() }
    }
    /// The asset the last drag carried (still readable after pointerUp, for the drop).
    public private(set) var lastDraggedAssetId: String?

    public func pointerDown(_ p: CanvasPoint, time: Double = Date().timeIntervalSinceReferenceDate) -> Bool {
        pressedAsset = nil; draggingAssetId = nil
        if dropdown.pointerDown(p) { onChange?(); return true }
        let hit = hits.hit(p)
        if let m = menu {
            guard menuRect(m).contains(p) else { menu = nil; onChange?(); return true }
        }
        if search != nil, hit != .search { commitSearch() }
        guard let hit else { return false }
        switch hit {
        case .showSidebar, .hideSidebar: layout.toggleLeft()
        case .importMedia: onImport?()
        case .panelMenu:
            openDropdown(hit, [.init(value: "import", label: "Import media…"), .init(value: "hide", label: "Hide panel")], nil) { [weak self] v in
                if v == "import" { self?.onImport?() } else { self?.layout.toggleLeft() }
            }
            return true
        case .search: if search == nil { search = PanelTextField(key: "search", value: searchQuery) }
        case .clearSearch: searchQuery = ""; search = nil; binScroll = 0
        case .tab(let t): selectTab(t)
        case .newLibrary: onLibrary?(.createLibrary)
        case .openLibrary: onLibrary?(.openLibrary)
        case .pickLibrary:
            openDropdown(hit, library.libraries.map { .init(value: $0.id, label: $0.name) }, activeLibrary?.id) { [weak self] v in
                self?.selectedLibraryId = v; self?.selectedEventId = nil }
            return true
        case .pickEvent:
            openDropdown(hit, (activeLibrary?.events ?? []).map { .init(value: $0.id, label: $0.name) }, activeEvent?.id) { [weak self] v in self?.selectedEventId = v }
            return true
        case .pickProject:
            let ps = (activeLibrary?.projects ?? []).filter { $0.eventId == activeEvent?.id }
            openDropdown(hit, ps.map { .init(value: $0.id, label: $0.name) }, library.currentProjectId) { [weak self] v in self?.onLibrary?(.switchProject(v)) }
            return true
        case .newEvent: creating = ("event", PanelTextField(key: "create", value: ""))
        case .newProject: creating = ("project", PanelTextField(key: "create", value: ""))
        case .createField: break
        case .createCancel: creating = nil
        case .createConfirm: confirmCreate()
        case .toggleMedia: mediaOpen.toggle()
        case .toggleExports: exportsOpen.toggle()
        case .storageMode:
            openDropdown(hit, [.init(value: "managed", label: "Copy into library"), .init(value: "linked", label: "Link to original files")],
                         linkedImport ? "linked" : "managed") { [weak self] v in self?.linkedImport = v == "linked" }
            return true
        case .importIntoEvent: if let l = activeLibrary, let e = activeEvent { onLibrary?(.importIntoEvent(libraryId: l.id, eventId: e.id, linked: linkedImport)) }
        case .attach(let a): if let l = activeLibrary { onLibrary?(.attach(libraryId: l.id, assetId: a)) }
        case .relink(let a): if let l = activeLibrary { onLibrary?(.relink(libraryId: l.id, assetId: a)) }
        case .saveOutput(let j): if let l = activeLibrary { onLibrary?(.saveOutput(libraryId: l.id, jobId: j)) }
        case .reveal: if let l = activeLibrary { onLibrary?(.reveal(libraryId: l.id)) }
        case .openStandalone: onLibrary?(.openStandalone)
        case .openProject: onLibrary?(.openProject)
        case .pickRecent:
            openDropdown(hit, library.recentProjects.map { .init(value: $0.path, label: $0.name) }, nil) { [weak self] v in self?.onLibrary?(.openRecentProject(v)) }
            return true
        case .asset(let id):
            pressedAsset = (id, p)
            // Double-click (or Enter) adds at the playhead.
            if let lc = lastClick, lc.id == id, time - lc.at < 0.4 { onAddAtPlayhead?(id); lastClick = nil } else { lastClick = (id, time) }
        case .menu: break
        case .menuItem(let id, let i):
            switch i {
            case 0: onAddAtPlayhead?(id); menu = nil
            case 1: if let path = items.first(where: { $0.id == id })?.path ?? items.first(where: { $0.id == id })?.name { onCopyPath?(path) }; menu = nil
            case 2: menu?.mode = 2; menu?.rename = PanelTextField(key: "rename", value: items.first { $0.id == id }?.name ?? "")
            default: menu?.mode = 1
            }
        case .removePlacements: menu?.removePlacements.toggle()
        case .deleteConfirm(let id): onDeleteAsset?(id, menu?.removePlacements ?? false); menu = nil
        case .deleteCancel: menu?.mode = 0
        case .renameField: break
        case .renameOK: commitRename()
        case .renameCancel: menu?.mode = 0; menu?.rename = nil
        case .libraryArea, .binArea: break
        }
        onChange?()
        return true
    }

    public func secondaryClick(_ p: CanvasPoint) -> Bool {
        guard case .asset(let id)? = hits.hit(p) else { if menu != nil { menu = nil; onChange?() }; return false }
        menu = Menu(assetId: id, at: p)
        onChange?()
        return true
    }

    public func pointerMove(_ p: CanvasPoint) -> Bool {
        if let pa = pressedAsset, draggingAssetId == nil, hypot(p.x - pa.at.x, p.y - pa.at.y) >= Self.dragThreshold {
            draggingAssetId = pa.id; lastClick = nil
            return true
        }
        if draggingAssetId != nil { return false }
        if dropdown.isOpen { return dropdown.pointerMove(p) }
        let h = hits.hit(p)
        let shown: Hit? = { switch h { case .libraryArea?, .binArea?: return nil; default: return h } }()
        guard shown != hovered else { return false }
        hovered = shown
        return true
    }

    /// `dy` in points from the host: precise (trackpad) deltas move 1:1, wheel line steps glide (PanelScroller).
    public func scroll(_ p: CanvasPoint, dy: Double, precise: Bool = false) -> Bool {
        if dropdown.isOpen { dropdown.scrollBy(dy); return true }
        if libRect.contains(p) { if libScroller.scroll(by: dy, precise: precise, max: libMax) { onAnimate?() }; return true }
        if binRect.contains(p) { if binScroller.scroll(by: dy, precise: precise, max: binMax) { onAnimate?() }; return true }
        return false
    }

    public func selectTab(_ t: LeftSidebarTab) {
        guard availableTabs.contains(t) else { return }
        tab = t
        layout.update { $0.sidebarTab = t }
    }

    /// Advances wheel glides and scrollbar fades; true while either still needs frames.
    @discardableResult
    public func tick(_ dt: Double) -> Bool {
        let a = binScroller.tick(dt), b = libScroller.tick(dt)
        return a || b
    }

    func commitSearch() { if let s = search { searchQuery = s.draft; search = nil; binScroll = 0 } }
    func confirmCreate() {
        guard let cr = creating, let l = activeLibrary else { return }
        let name = cr.field.draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if cr.kind == "event" { onLibrary?(.createEvent(libraryId: l.id, name: name)) }
        else if let e = activeEvent { onLibrary?(.createProject(libraryId: l.id, eventId: e.id, name: name)) }
        creating = nil
    }
    func commitRename() {
        guard let m = menu, let f = m.rename else { return }
        let n = f.draft.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { onRenameAsset?(m.assetId, n) }
        menu = nil
    }

    /// Text input for search / name fields; Escape closes the menu. Search filters live as you type.
    public func keyDown(_ k: EditorKey) -> Bool {
        if dropdown.key(k) { onChange?(); return true }
        if var s = search {
            let out = s.key(k)
            switch out {
            case .commit: search = s; commitSearch()
            case .cancel: search = nil
            case .editing: search = s; searchQuery = s.draft; binScroll = 0
            case .none: return false
            }
            onChange?(); return true
        }
        if var cr = creating {
            switch cr.field.key(k) {
            case .commit: confirmCreate()
            case .cancel: creating = nil
            case .editing: creating = (cr.kind, cr.field)
            case .none: return false
            }
            onChange?(); return true
        }
        if var m = menu {
            if var f = m.rename {
                switch f.key(k) {
                case .commit: menu?.rename = f; commitRename()
                case .cancel: menu?.mode = 0; menu?.rename = nil
                case .editing: m.rename = f; menu = m
                case .none: return false
                }
                onChange?(); return true
            }
            if case .escape = k.code { menu = nil; onChange?(); return true }
        }
        return false
    }
}
