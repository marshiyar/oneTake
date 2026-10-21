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
    /// On the timeline at least once (the tile's "in the timeline" dot, the filter's timeline choice, and the
    /// default order puts these first).
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
    /// A recently opened project folder (the "Recent" group of the panel's "…" menu).
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

/// The Media panel (left sidebar), media first: the tab strip; one header row (the library ▸ event switcher,
/// Import, and the "…" menu of library and project actions); search with the filter menu; then the grid of
/// sections (Video, Images, Audio, Fonts, Library media, Exports). Spacing comes from `MediaPanelMetrics`.
public final class LeftSidebarPanel {
    public enum Hit: Hashable {
        case showSidebar, hideSidebar, panelMenu
        case tab(LeftSidebarTab)
        case switcher, importMedia, more
        case search, clearSearch, filter, clearFilters
        case createField, createConfirm, createCancel
        case tile(MediaTileRef), tileAction(MediaTileRef)
        /// The play / stop button of a tile that can be auditioned, and the progress bar of the one that is.
        case tileAudition(MediaTileRef), auditionBar(MediaTileRef)
        case menuItem(String, Int), deleteConfirm(String), deleteCancel, removePlacements, renameField, renameOK, renameCancel
        case binArea
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
    /// Audition (play a file on its own): the host starts or stops it for a bin asset id (Space on a tile, the tile's play
    /// button), seeks it to seconds (a click on the progress bar) or by seconds (← / →), and stops it (Esc).
    public var onAuditionToggle: ((String) -> Void)?
    public var onAuditionSeek: ((String, Double) -> Void)?
    public var onAuditionSeekBy: ((Double) -> Void)?
    public var onAuditionStop: (() -> Void)?
    /// The asset being auditioned, with its position; nil when none. Filled by the host every frame.
    public var audition: AuditionTileState?
    /// A tile's audition failure, shown on the tile until the next try ("Can't play \"take3.wav\": the file is missing").
    public var auditionErrors: [String: String] = [:]

    public internal(set) var hits = HitMap<Hit>()
    public let dropdown = PanelDropdown()
    public var hovered: Hit?
    public internal(set) var search: PanelTextField?
    public var searchQuery = ""
    public var filter = MediaFilter()
    /// The tile the arrows move and Enter acts on (a click selects; Escape clears).
    public internal(set) var selected: MediaTileRef?
    /// Tab order over the header controls and the grid (the selected tile, or the first one).
    public internal(set) var focus = PanelFocus<Hit>()
    var selectedLibraryId: String?
    var selectedEventId: String?
    var linkedImport = false
    var creating: (kind: String, field: PanelTextField)?
    public struct Menu: Equatable {
        public var target: MediaTileRef; public var at: CanvasPoint; public var mode: Int = 0; public var removePlacements = false
        public var rename: PanelTextField?
        public var assetId: String { target.id }
    }
    public internal(set) var menu: Menu?
    var binScroller = PanelScroller()
    var binScroll: Double {
        get { binScroller.offset }
        set { binScroller.jump(to: newValue) }
    }
    var binMax = 0.0
    /// Asks the host to call `tick` (~60 Hz) until it returns false (wheel glides, scrollbar fades).
    public var onAnimate: (() -> Void)?
    var binRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    var size = CanvasSize(0, 0)
    var lastClick: (ref: MediaTileRef, at: Double)?
    /// Tiles whose name did not fit in two lines at the last draw (they get the full name in a tooltip).
    var truncatedNames: Set<MediaTileRef> = []
    /// Every tile of the last draw in grid order, in content coordinates (unscrolled; the arrows and scrolling a
    /// tile into view use it, including tiles scrolled out of sight).
    var tileFrames: [(MediaTileRef, CanvasRect)] = []
    /// The progress bar of the audition playing, as drawn (the seek click maps along its width).
    var auditionBars: [MediaTileRef: CanvasRect] = [:]

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
    /// The hide button's place; docked there is no hide button, so it is the menu button's.
    func hideRect(_ strip: CanvasRect) -> CanvasRect { PanelTabStrip.buttonRect(strip, index: docked ? 0 : 1) }
    func drawHideButton(_ c: CanvasContext, _ r: CanvasRect) {
        guard !docked else { return }
        PanelTabStrip.iconButton(c, r, icon: .sidebarHideLeft, hovered: hovered == .hideSidebar)
        hits.add(r, .hideSidebar)
    }
    public static let tabLabels: [LeftSidebarTab: String] = [.assets: "Media", .compositions: "Scenes", .blocks: "Elements"]

    var activeLibrary: LibraryNavModel.Library? {
        let libs = library.libraries
        return libs.first { $0.id == selectedLibraryId } ?? libs.first { $0.projects.contains { $0.id == library.currentProjectId } } ?? libs.first
    }
    var activeEvent: LibraryNavModel.Item? {
        guard let l = activeLibrary else { return nil }
        return l.events.first { $0.id == selectedEventId } ?? l.events.first
    }
    /// The header shows the library switcher and the "…" menu whenever the host runs library or project commands.
    var showsLibrary: Bool { library.available || onLibrary != nil }

    /// Project files matching the search (any kind, any use).
    public var filteredItems: [MediaBinItem] { items.filter { matchesSearch($0.name) } }

    /// Project files by kind, after the search and the filter, in the filter's order (timeline first by default).
    public var categorized: [(MediaBinItem.Category, [MediaBinItem])] {
        let f = filteredItems.filter { filter.admits($0) }
        return MediaBinItem.order.compactMap { cat in
            let list = f.filter { $0.category == cat }
            return list.isEmpty ? nil : (cat, sorted(list))
        }
    }

    // MARK: Draw

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        self.size = size
        hits.reset()
        truncatedNames = []
        let r = CanvasRect(x: 0, y: 0, width: size.width, height: size.height)
        if layout.effectiveLeftCollapsed {   // the rail
            hits.add(PanelTabStrip.drawRail(c, r, icon: .sidebarShowLeft, hovered: hovered == .showSidebar), .showSidebar)
            return
        }
        c.fillRect(r, PanelTheme.panelBg)
        c.withState {
            c.clip(r)
            var y = drawTabStrip(c, CanvasRect(x: 0, y: 0, width: r.width, height: PanelTabStrip.height))
            y = drawHeader(c, top: y + MediaPanelMetrics.rowGap)
            y = drawSearchRow(c, top: y)
            drawGrid(c, CanvasRect(x: 0, y: y, width: r.width, height: max(0, r.maxY - y)))
        }
        drawOverlays(c)
    }

    /// Above the panel body: the keyboard focus ring, the open context menu, the tooltip, then an open dropdown.
    func drawOverlays(_ c: CanvasContext) {
        if let ring = focus.ringRect(hits) { PanelDraw.focusRing(c, ring, radius: PanelTheme.radiusMd) }
        if let m = menu { drawMenu(c, m) }
        if !dropdown.isOpen, menu == nil { drawTooltip(c) }
        dropdown.draw(c)
    }

    // MARK: Tab strip (the tabs; hide and the panel menu at the right end)

    /// Drawn (and so focused) in reading order: the tabs, Import media, hide, the panel menu.
    func drawTabStrip(_ c: CanvasContext, _ strip: CanvasRect) -> Double {
        PanelTabStrip.drawBackground(c, strip)
        let tabs = stripTabs
        let hide = hideRect(strip), menu = PanelTabStrip.buttonRect(strip, index: 0)
        let x = strip.x + PanelTabStrip.edgeInset
        let bar = PanelTabBar(tabs: tabs.map { PanelTab(id: $0.rawValue, label: Self.tabLabels[$0] ?? $0.rawValue) },
                              selected: tab.rawValue, style: .strip)
        let laid = bar.layout(c, in: CanvasRect(x: x, y: strip.y, width: max(0, hide.x - 4 - x), height: strip.height))
        var hover: PanelTabBar.Part?
        if case .tab(let t)? = hovered { hover = .tab(t.rawValue) }
        bar.draw(c, laid, hovered: hover)
        for (r, part) in PanelTabBar.hitRects(laid) { if case .tab(let id) = part, let t = LeftSidebarTab(rawValue: id) { hits.add(r, .tab(t)) } }
        drawHideButton(c, hide)
        PanelTabStrip.iconButton(c, menu, icon: .panelMenu, hovered: hovered == .panelMenu, open: dropdown.key == "\(Hit.panelMenu)")
        hits.add(menu, .panelMenu)
        return strip.height
    }

    /// Adds `hit` for the part of `rect` inside `clip`, so a tile scrolled under the search row takes no clicks there.
    func addClipped(_ rect: CanvasRect, _ hit: Hit, to clip: CanvasRect) {
        let top = max(rect.y, clip.y), bottom = min(rect.maxY, clip.maxY)
        guard bottom > top else { return }
        hits.add(CanvasRect(x: rect.x, y: top, width: rect.width, height: bottom - top), hit)
    }

    // MARK: Input

    public var isEditingText: Bool { search != nil || creating != nil || menu?.rename != nil }

    func openDropdown(_ hit: Hit, anchor: CanvasRect? = nil, _ options: [PanelDropdown.Option], _ selected: String?, _ pick: @escaping (String) -> Void) {
        guard let a = anchor ?? hits.rect(where: { $0 == hit }), !options.isEmpty else { return }
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
        focus.pointerPressed()
        if dropdown.pointerDown(p) { onChange?(); return true }
        let hit = hits.hit(p)
        if let m = menu, !menuRect(m).contains(p) { menu = nil; onChange?(); return true }
        if search != nil, hit != .search { commitSearch() }
        guard let hit else { return false }
        if pressChrome(hit) || pressSearchRow(hit) || pressTile(hit, at: p, time: time) || pressMenu(hit) || pressNameRow(hit) { return true }
        onChange?()
        return true
    }

    /// The tab strip and the header row. Returns true when the press opened a dropdown (which already asked for a
    /// redraw).
    func pressChrome(_ hit: Hit) -> Bool {
        switch hit {
        case .showSidebar, .hideSidebar: layout.toggleLeft()
        case .importMedia: onImport?()
        case .panelMenu: openPanelMenu(); return true
        case .switcher: openSwitcher(); return true
        case .more: openMoreMenu(); return true
        case .tab(let t): selectTab(t)
        default: break
        }
        return false
    }

    /// The search field, its clear button, the filter menu and Clear filters.
    func pressSearchRow(_ hit: Hit) -> Bool {
        switch hit {
        case .filter: openFilterMenu(); return true
        case .search: if search == nil { search = PanelTextField(key: "search", value: searchQuery) }
        case .clearSearch: searchQuery = ""; search = nil; binScroll = 0
        case .clearFilters: filter = MediaFilter(); binScroll = 0
        default: break
        }
        return false
    }

    /// A press on a tile selects it (a second press soon after runs its action; a moving press drags a project
    /// file); the tile's hover button runs the action at once.
    func pressTile(_ hit: Hit, at p: CanvasPoint, time: Double) -> Bool {
        switch hit {
        case .tile(let ref):
            selected = ref
            if case .media(let id) = ref { pressedAsset = (id, p) }
            if let lc = lastClick, lc.ref == ref, time - lc.at < 0.4 { runPrimary(ref); lastClick = nil } else { lastClick = (ref, time) }
        case .tileAction(let ref): selected = ref; runPrimary(ref)
        case .tileAudition, .auditionBar: _ = pressAudition(hit, at: p)
        default: break
        }
        return false
    }

    public func secondaryClick(_ p: CanvasPoint) -> Bool {
        guard case .tile(let ref)? = hits.hit(p), !menuEntries(ref).isEmpty else {
            if menu != nil { menu = nil; onChange?() }
            return false
        }
        selected = ref
        menu = Menu(target: ref, at: p)
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
        let shown: Hit? = h == .binArea ? nil : h
        guard shown != hovered else { return false }
        hovered = shown
        return true
    }

    /// `dy` in points from the host: precise (trackpad) deltas move 1:1, wheel line steps glide (PanelScroller).
    public func scroll(_ p: CanvasPoint, dy: Double, precise: Bool = false) -> Bool {
        if dropdown.isOpen { dropdown.scrollBy(dy); return true }
        guard binRect.contains(p) else { return false }
        if binScroller.scroll(by: dy, precise: precise, max: binMax) { onAnimate?() }
        return true
    }

    public func selectTab(_ t: LeftSidebarTab) {
        guard availableTabs.contains(t) else { return }
        tab = t
        layout.update { $0.sidebarTab = t }
    }

    /// Advances wheel glides and scrollbar fades; true while either still needs frames.
    @discardableResult
    public func tick(_ dt: Double) -> Bool { binScroller.tick(dt) }

    func commitSearch() { if let s = search { searchQuery = s.draft; search = nil; binScroll = 0 } }
}
