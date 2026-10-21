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
import XCTest
import MpvfxCanvas
import MpvfxTheme
import MpvfxTimeline
@testable import MpvfxPanels

/// A Media panel with everything the redesign has to place: two events, library files (one already in the
/// project, one missing), a finished and a running export, video, images, audio and fonts with long names.
enum MediaPanelFixture {
    static let long = "NUNCA MUDA QUICK BMW M3 EDIT final colour pass (2).mp4"

    static func items() -> [MediaBinItem] {
        func v(_ path: String, _ cat: MediaBinItem.Category, _ d: Double?, _ used: Bool) -> MediaBinItem {
            MediaBinItem(id: path, name: (path as NSString).lastPathComponent, path: path, category: cat, duration: d, used: used)
        }
        return [v("media/\(long)", .video, 11, true), v("media/Su-57 edit.mp4", .video, 39, true), v("media/b-roll.mov", .video, 21, false),
                v("assets/A1/NUNCA MUDA QUICK BMW M3 EDIT.mp4", .video, 11, true), v("media/poster.png", .images, nil, false),
                v("media/drive.wav", .audio, 92.5, true), v("media/room-tone.wav", .audio, 30, false), v("media/Inter.ttf", .fonts, nil, false)]
    }

    /// A1 is already attached to the project (its bin path is `assets/A1/…`), A3's linked original is gone, A4 is in
    /// the other event.
    static let libraryAssets: [LibraryNavModel.Asset] = [
        .init(id: "A1", name: "NUNCA MUDA QUICK BMW M3 EDIT.mp4", kind: "video", eventId: "E"),
        .init(id: "A2", name: "Su-57 raw.mp4", kind: "video", eventId: "E"),
        .init(id: "A3", name: "interview.mov", kind: "video", eventId: "E", available: false, linked: true),
        .init(id: "A4", name: "day2.mov", kind: "video", eventId: "E2"),
    ]
    /// One finished export (Save to…) and one still running (no action).
    static let exports: [LibraryNavModel.Export] = [
        .init(id: "J1", label: "render-546cccc1-d7d8-473d-8eda-5f0c.mp4", status: "complete"), .init(id: "J2", label: "draft.mp4", status: "running"),
    ]
    static let events: [LibraryNavModel.Item] = [.init(id: "E", name: "Media"), .init(id: "E2", name: "Day 2")]

    static func library() -> LibraryNavModel {
        var m = LibraryNavModel()
        m.available = true
        m.isStandalone = true
        m.libraries = [.init(id: "L", name: "Untitled.mpvfxlibrary", events: events, projects: [.init(id: "P1", name: "Cut A", eventId: "E")],
                             assets: libraryAssets, exports: exports)]
        m.recentProjects = [.init(path: "/p/Alpha", name: "Alpha")]
        return m
    }

    static func panel() -> LeftSidebarPanel {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        s.items = items()
        s.library = library()
        s.onLibrary = { _ in }
        return s
    }
}

private func center(_ r: CanvasRect) -> CanvasPoint { CanvasPoint(r.x + r.width / 2, r.y + r.height / 2) }

/// Layout audit at the panel's minimum (280 pt) and two default widths (364 pt, 409 pt): no two targets overlap,
/// every row shares one inset, every target is at least 24 pt and toolbar controls at least 28 pt.
final class MediaPanelLayoutAuditTests: XCTestCase {
    static let widths = [280.0, 364.0, 409.0]
    typealias Hit = LeftSidebarPanel.Hit

    /// The states the audit draws: at rest, a tile hovered (its action shows), a filter on (its line shows), the
    /// New event name row and an error.
    static func states() -> [(String, (LeftSidebarPanel) -> Void)] {
        [("rest", { _ in }),
         ("hover", { $0.hovered = .tile(.media("media/b-roll.mov")) }),
         ("filtered", { $0.filter = MediaFilter(kind: .video, usage: .notInTimeline, sort: .name) }),
         ("naming", { $0.runMoreOption("newEvent") }),
         ("error", { $0.library.error = "Could not open the library: permission denied for /Volumes/Footage/Untitled.mpvfxlibrary" })]
    }

    func drawn(_ width: Double, _ state: (LeftSidebarPanel) -> Void) -> LeftSidebarPanel {
        let s = MediaPanelFixture.panel()
        s.draw(PanelMeasureCanvas(), size: CanvasSize(width, 900))
        state(s)
        s.draw(PanelMeasureCanvas(), size: CanvasSize(width, 900))
        return s
    }

    /// A tile and its own hover button, and the search field and its clear button, nest on purpose.
    func nests(_ a: Hit, _ b: Hit) -> Bool {
        switch (a, b) {
        case (.tile(let x), .tileAction(let y)), (.tileAction(let y), .tile(let x)): return x == y
        case (.search, .clearSearch), (.clearSearch, .search): return true
        default: return false
        }
    }

    func testNoTargetsOverlapAtEveryWidthAndState() {
        for w in Self.widths { for (name, state) in Self.states() {
            let s = drawn(w, state)
            let regions = s.hits.regions.filter { $0.action != .binArea }
            for (i, a) in regions.enumerated() { for b in regions[(i + 1)...] where !nests(a.action, b.action) {
                let ix = min(a.rect.maxX, b.rect.maxX) - max(a.rect.x, b.rect.x), iy = min(a.rect.maxY, b.rect.maxY) - max(a.rect.y, b.rect.y)
                XCTAssertFalse(ix > 0.01 && iy > 0.01, "\(w) pt \(name): \(a.action) overlaps \(b.action)")
            } }
        } }
    }

    func testEveryRowSharesOneInset() throws {
        let inset = MediaPanelMetrics.inset
        for w in Self.widths { for (name, state) in Self.states() {
            let s = drawn(w, state)
            func rect(_ h: Hit) throws -> CanvasRect { try XCTUnwrap(s.hits.rect { $0 == h }, "\(w) \(name): no \(h)") }
            XCTAssertEqual(try rect(.switcher).x, inset, "\(w) \(name)")
            XCTAssertEqual(try rect(.more).maxX, w - inset, accuracy: 0.01, "\(w) \(name)")
            XCTAssertEqual(try rect(.search).x, inset, "\(w) \(name)")
            XCTAssertEqual(try rect(.filter).maxX, w - inset, accuracy: 0.01, "\(w) \(name)")
            let content = s.hits.regions.filter { r in if case .tile = r.action { return true }; return false }.map(\.rect)
            XCTAssertEqual(content.map(\.x).min() ?? -1, inset, accuracy: 0.01, "\(w) \(name): the grid's left edge")
            let cw = w - 2 * inset, cols = MediaPanelMetrics.columns(cw), tw = MediaPanelMetrics.tileWidth(cw, columns: cols)
            let columnXs = (0..<cols).map { inset + Double($0) * (tw + MediaPanelMetrics.tileGap) }
            for r in content where r.width < cw - 0.01 {
                XCTAssertTrue(columnXs.contains { abs($0 - r.x) < 0.01 }, "\(w) \(name): a tile at x \(r.x) is off the column grid \(columnXs)")
            }
            if name == "rest" { XCTAssertEqual(content.map(\.maxX).max() ?? -1, w - inset, accuracy: 0.01, "\(w): the grid's right edge") }
            for r in s.hits.regions where r.action != .binArea && r.rect.y >= PanelTabStrip.height {
                XCTAssertGreaterThanOrEqual(r.rect.x, inset - 0.01, "\(w) \(name): \(r.action) starts left of the inset")
                XCTAssertLessThanOrEqual(r.rect.maxX, w - inset + 0.01, "\(w) \(name): \(r.action) ends right of the inset")
            }
        } }
    }

    func testTargetsAreAtLeast24AndToolbarControls28() {
        let toolbar: [Hit] = [.switcher, .importMedia, .more, .search, .filter]
        for w in Self.widths { for (name, state) in Self.states() {
            let s = drawn(w, state)
            for r in s.hits.regions where r.action != .binArea && r.rect.maxY < s.binRect.maxY - 0.5 {
                XCTAssertGreaterThanOrEqual(min(r.rect.width, r.rect.height), 24, "\(w) pt \(name): \(r.action) is \(r.rect.width)×\(r.rect.height)")
                if toolbar.contains(r.action) { XCTAssertGreaterThanOrEqual(r.rect.height, 28, "\(w) pt \(name): \(r.action)") }
            }
        } }
    }

    /// 2 columns at 280 and 364 pt, 3 at 409 pt; every row of tiles has one height and one gap.
    func testGridDensity() {
        XCTAssertEqual(Self.widths.map { MediaPanelMetrics.columns($0 - 2 * MediaPanelMetrics.inset) }, [2, 2, 3])
        let s = drawn(409, { _ in })
        let videos = s.hits.regions.compactMap { r -> CanvasRect? in if case .tile(.media(let id)) = r.action, id.hasSuffix(".mp4") || id.hasSuffix(".mov") { return r.rect }; return nil }
        XCTAssertEqual(Set(videos.map(\.height)).count, 1, "one tile height")
        let xs = Array(Set(videos.map(\.x))).sorted()
        XCTAssertEqual(xs.count, 3)
        XCTAssertEqual(xs[1] - (xs[0] + videos[0].width), MediaPanelMetrics.tileGap, accuracy: 0.01)
    }

    /// The owner's second screenshot looked like the panel lost its inset with the library media open. Showing
    /// library media, the exports and a scrolled grid must not move anything sideways.
    func testInsetHoldsWithLibraryMediaShownAndScrolled() {
        for w in Self.widths {
            let s = drawn(w, { $0.filter.kind = .library })
            s.binScroll = 120
            s.draw(PanelMeasureCanvas(), size: CanvasSize(w, 900))
            for r in s.hits.regions where r.action != .binArea && r.rect.y >= PanelTabStrip.height {
                XCTAssertGreaterThanOrEqual(r.rect.x, MediaPanelMetrics.inset - 0.01, "\(w) pt: \(r.action) at x \(r.rect.x)")
            }
        }
    }

    /// A tile scrolled under the search row takes no clicks there: the search field gets them.
    func testTilesScrolledUnderTheSearchRowTakeNoClicks() throws {
        let s = drawn(364, { _ in })
        s.binScroll = 60
        s.draw(PanelMeasureCanvas(), size: CanvasSize(364, 900))
        let search = try XCTUnwrap(s.hits.rect { $0 == .search })
        XCTAssertEqual(s.hits.hit(center(search)), .search)
        for r in s.hits.regions { if case .tile = r.action { XCTAssertGreaterThanOrEqual(r.rect.y, s.binRect.y - 0.01) } }
    }
}

final class MediaPanelInteractionTests: XCTestCase {
    /// Tall enough that every section of the fixture is on screen at 364 pt.
    func drawn(_ s: LeftSidebarPanel, _ c: PanelMeasureCanvas = PanelMeasureCanvas(), width: Double = 364, height: Double = 1500) -> PanelMeasureCanvas {
        c.reset(); s.draw(c, size: CanvasSize(width, height)); return c
    }

    func press(_ s: LeftSidebarPanel, _ h: LeftSidebarPanel.Hit, time: Double = 0) throws {
        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == h }, "no \(h)")), time: time))
    }

    /// Media first: the header row is right under the tab strip and the grid starts under one search row, with
    /// no library rows between (the old navigator took about half of the panel).
    func testMediaComesFirst() throws {
        let s = MediaPanelFixture.panel()
        let c = drawn(s)
        let firstTile = try XCTUnwrap(s.hits.regions.first { if case .tile = $0.action { return true }; return false }?.rect)
        XCTAssertLessThanOrEqual(firstTile.y, PanelTabStrip.height + 8 + 32 + 8 + 32 + 8 + 24 + 0.01)
        for t in ["Libraries", "New library", "Open", "New event", "New project", "Select project", "Open project…", "Recent",
                  "Editing the existing standalone project", "Library media (2)", "Library exports (2)", "Add to timeline", "Copy into library"] {
            XCTAssertFalse(c.drawnStrings.contains(t), "\(t) is no longer a row of the panel")
        }
    }

    func testSwitcherShowsLibraryAndEventAndSwitchesEvent() throws {
        let s = MediaPanelFixture.panel()
        var c = drawn(s)
        XCTAssertTrue(c.drawnStrings.contains("Untitled"), "the library's name without .mpvfxlibrary")
        XCTAssertTrue(c.drawnStrings.contains("Media"))
        try press(s, .switcher)
        XCTAssertEqual(s.dropdown.options.map(\.label), ["Untitled", "Media", "Day 2"])
        XCTAssertEqual(s.dropdown.options.map(\.group), ["Libraries", "Events", "Events"])
        XCTAssertEqual(s.dropdown.options.filter(\.checked).map(\.label), ["Untitled", "Media"])
        s.dropdown.pick("event:E2")
        c = drawn(s, c)
        XCTAssertTrue(c.drawnStrings.contains("Day 2"))
        XCTAssertTrue(c.drawnStrings.contains("day2.mov"), "the library section follows the event")
        XCTAssertFalse(c.drawnStrings.contains("Su-57 raw.mp4"))
    }

    /// The standalone status is the switcher's tooltip and status-line hint, not a row.
    func testStandaloneStatusIsATooltipNotARow() throws {
        let s = MediaPanelFixture.panel()
        var c = drawn(s)
        XCTAssertFalse(c.drawnStrings.contains { $0.contains("standalone") })
        XCTAssertTrue(s.pointerMove(center(try XCTUnwrap(s.hits.rect { $0 == .switcher }))))
        XCTAssertEqual(s.hint, "Library Untitled · event Media · editing the existing standalone project")
        c = drawn(s, c)
        XCTAssertTrue(c.drawnStrings.contains { $0.contains("standalone") }, "the tooltip shows it")
    }

    /// Every action of the old navigator is one "…" item away, and runs the same command.
    func testMoreMenuRunsEveryLibraryAndProjectAction() throws {
        let s = MediaPanelFixture.panel()
        var cmds: [LibraryNavCommand] = []
        s.onLibrary = { cmds.append($0) }
        s.library.isStandalone = false
        s.library.currentProjectId = "P1"
        _ = drawn(s)
        let picks = ["newLibrary", "openLibrary", "importIntoEvent", "storage:linked", "importIntoEvent", "reveal", "project:P1", "openProject",
                     "standalone", "recent:/p/Alpha"]
        for v in picks {
            try press(s, .more)
            XCTAssertTrue(s.dropdown.options.contains { $0.value == v && !$0.disabled }, "no \(v)")
            s.dropdown.pick(v)
            _ = drawn(s)
        }
        XCTAssertEqual(cmds, [.createLibrary, .openLibrary, .importIntoEvent(libraryId: "L", eventId: "E", linked: false),
                              .importIntoEvent(libraryId: "L", eventId: "E", linked: true), .reveal(libraryId: "L"), .switchProject("P1"),
                              .openProject, .openStandalone, .openRecentProject("/p/Alpha")])
        try press(s, .more)
        XCTAssertEqual(s.dropdown.options.filter(\.checked).map(\.label), ["Link to the original files", "Cut A"])
        s.dropdown.pick("newProject")
        _ = drawn(s)
        for ch in "Cut B" { _ = s.keyDown(ch == " " ? EditorKey(.space) : EditorKey(.char(ch))) }
        _ = drawn(s)
        try press(s, .createConfirm)
        XCTAssertEqual(cmds.last, .createProject(libraryId: "L", eventId: "E", name: "Cut B"))
    }

    /// While a library command runs, its items are disabled and picking one does nothing.
    func testBusyLibraryDisablesTheActions() throws {
        let s = MediaPanelFixture.panel()
        var cmds: [LibraryNavCommand] = []
        s.onLibrary = { cmds.append($0) }
        s.library.busy = true
        _ = drawn(s)
        try press(s, .more)
        XCTAssertTrue(s.dropdown.options.filter { !$0.value.hasPrefix("storage:") }.allSatisfy(\.disabled))
        s.dropdown.pick("openLibrary")
        XCTAssertEqual(cmds, [])
    }

    func testFilterNarrowsByKindAndTimelineUseAndSorts() throws {
        let s = MediaPanelFixture.panel()
        _ = drawn(s)
        XCTAssertEqual(s.sections.map(\.id), ["video", "images", "audio", "fonts", "library", "exports"])
        try press(s, .filter)
        XCTAssertEqual(Set(s.dropdown.options.compactMap(\.group)), ["Show", "Timeline", "Sort by"])
        s.dropdown.pick("kind:video")
        XCTAssertEqual(s.sections.map(\.id), ["video"])
        _ = drawn(s)
        try press(s, .filter)
        s.dropdown.pick("usage:notInTimeline")
        XCTAssertEqual(s.sections.flatMap(\.tiles), [.media("media/b-roll.mov")])
        var c = drawn(s)
        XCTAssertTrue(c.drawnStrings.contains("Video · Not in the timeline"))
        try press(s, .clearFilters)
        XCTAssertTrue(s.filter.isDefault)
        s.filter.sort = .name
        XCTAssertEqual(s.sections.first?.tiles.first, .media("media/b-roll.mov"))
        s.filter = MediaFilter(kind: .all, usage: .inTimeline)
        XCTAssertEqual(s.sections.map(\.id), ["video", "audio"], "library files and exports are never in this timeline")
        c = drawn(s, c)
    }

    /// Library files already attached to this project are bin tiles; only the others form "Library media", and
    /// exports are their own section.
    func testLibraryMediaAndExportsAreSectionsWithoutDuplicates() {
        let s = MediaPanelFixture.panel()
        XCTAssertEqual(s.sections.first { $0.id == "library" }?.tiles, [.library("A2"), .library("A3")])
        XCTAssertEqual(s.sections.first { $0.id == "exports" }?.tiles, [.export("J1"), .export("J2")])
        s.searchQuery = "su-57"
        XCTAssertEqual(s.sections.flatMap(\.tiles), [.media("media/Su-57 edit.mp4"), .library("A2")])
    }

    func testTileHoverActionAddsAttachesAndSaves() throws {
        let s = MediaPanelFixture.panel()
        var added: [String] = [], cmds: [LibraryNavCommand] = []
        s.onAddAtPlayhead = { added.append($0) }
        s.onLibrary = { cmds.append($0) }
        for ref in [MediaTileRef.media("media/b-roll.mov"), .library("A2"), .export("J1")] {
            _ = drawn(s)
            XCTAssertNil(s.hits.rect { $0 == .tileAction(ref) }, "the action shows on hover only")
            XCTAssertTrue(s.pointerMove(center(try XCTUnwrap(s.hits.rect { $0 == .tile(ref) }))))
            _ = drawn(s)
            let a = try XCTUnwrap(s.hits.rect { $0 == .tileAction(ref) }, "\(ref)")
            XCTAssertEqual(a.width, MediaPanelMetrics.tileAction); XCTAssertEqual(a.height, MediaPanelMetrics.tileAction)
            XCTAssertTrue(s.pointerDown(center(a)))
        }
        XCTAssertEqual(added, ["media/b-roll.mov"])
        XCTAssertEqual(cmds, [.attach(libraryId: "L", assetId: "A2"), .saveOutput(libraryId: "L", jobId: "J1")])
        for ref in [MediaTileRef.library("A3"), .export("J2"), .media("media/Inter.ttf")] {
            s.hovered = .tile(ref); _ = drawn(s)
            XCTAssertNil(s.hits.rect { $0 == .tileAction(ref) }, "\(ref): missing, unfinished or a font: no action")
        }
    }

    func testContextMenusPerTileKind() throws {
        let s = MediaPanelFixture.panel()
        let cases: [(MediaTileRef, [String])] = [
            (.media("media/b-roll.mov"), ["Add at playhead", "Copy path", "Rename", "Delete"]), (.media("media/Inter.ttf"), ["Copy path", "Rename", "Delete"]),
            (.library("A2"), ["Add to timeline"]), (.library("A3"), ["Relink…"]), (.export("J1"), ["Save to…"]),
        ]
        for (ref, labels) in cases {
            _ = drawn(s)
            XCTAssertTrue(s.secondaryClick(center(try XCTUnwrap(s.hits.rect { $0 == .tile(ref) }))), "\(ref)")
            let m = drawn(s)
            XCTAssertTrue(labels.allSatisfy(m.drawnStrings.contains), "\(ref): \(labels)")
            XCTAssertEqual(s.menuEntries(ref).map(\.label), labels)
            _ = s.keyDown(EditorKey(.escape))
        }
        _ = drawn(s)
        XCTAssertFalse(s.secondaryClick(center(try XCTUnwrap(s.hits.rect { $0 == .tile(.export("J2")) }))), "a running export has no menu")
        var cmds: [LibraryNavCommand] = []
        s.onLibrary = { cmds.append($0) }
        _ = drawn(s)
        _ = s.secondaryClick(center(try XCTUnwrap(s.hits.rect { $0 == .tile(.library("A3")) })))
        _ = drawn(s)
        try press(s, .menuItem("A3", 0))
        XCTAssertEqual(cmds, [.relink(libraryId: "L", assetId: "A3")])
    }

    /// Names: at most two lines, cut at the end (never in the middle), the full name in a tooltip on hover.
    func testNamesWrapToTwoLinesWithEndTruncationAndATooltip() throws {
        let m = PanelMeasureCanvas(), font = PanelTheme.font(11)
        let wrapped = MediaTileText.lines(m, MediaPanelFixture.long, font: font, width: 120, maxLines: 2)
        XCTAssertEqual(wrapped.lines.count, 2); XCTAssertTrue(wrapped.truncated)
        XCTAssertEqual(wrapped.lines[0], "NUNCA MUDA QUICK", "the first line breaks after a whole word")
        XCTAssertTrue(wrapped.lines[1].hasPrefix("BMW M3")); XCTAssertTrue(wrapped.lines[1].hasSuffix("…"))
        XCTAssertTrue(wrapped.lines.allSatisfy { m.measureText($0, font: font).width <= 120 })
        XCTAssertEqual(MediaTileText.lines(m, "b-roll.mov", font: font, width: 120, maxLines: 2).lines, ["b-roll.mov"])
        XCTAssertEqual(MediaTileText.lines(m, "averyveryveryverylongname.mp4", font: font, width: 60, maxLines: 2).lines.count, 2, "a long word breaks by character")

        let s = MediaPanelFixture.panel()
        var c = drawn(s, width: 280)
        let ref = MediaTileRef.media("media/\(MediaPanelFixture.long)")
        XCTAssertTrue(s.truncatedNames.contains(ref))
        XCTAssertFalse(c.drawnStrings.contains { $0.contains("…") && !$0.hasSuffix("…") }, "no middle ellipsis anywhere")
        let before = c.drawnStrings.count
        XCTAssertTrue(s.pointerMove(center(try XCTUnwrap(s.hits.rect { $0 == .tile(ref) }))))
        c = drawn(s, c, width: 280)
        XCTAssertEqual(c.drawnStrings.suffix(c.drawnStrings.count - before).joined(separator: " "), MediaPanelFixture.long, "the tooltip is the full name")
        XCTAssertTrue(s.hint?.hasPrefix(MediaPanelFixture.long) ?? false)
    }

    func testTimelineUseIsAQuietMarkNotAnAddedBadge() {
        let s = MediaPanelFixture.panel()
        let c = drawn(s)
        XCTAssertFalse(c.drawnStrings.contains("Added"))
        XCTAssertTrue(c.drawnStrings.contains("01:33 · In the timeline"), "an audio row says so in words")
        XCTAssertTrue(c.drawnStrings.contains("Missing"), "a library file whose original is gone")
        XCTAssertTrue(c.drawnStrings.contains("00:11"), "the duration badge")
    }

    /// Click selects; the arrows move across and down (into the next section); Enter adds; Shift+Enter opens the
    /// menu; Escape closes it, then clears the selection, after which the arrows go back to the timeline.
    func testKeyboardMovesTheSelectionAndRunsTheAction() throws {
        let s = MediaPanelFixture.panel()
        var added: [String] = []
        s.onAddAtPlayhead = { added.append($0) }
        _ = drawn(s)
        XCTAssertFalse(s.keyDown(EditorKey(.right)), "nothing selected: the arrows belong to the timeline")
        try press(s, .tile(.media("media/\(MediaPanelFixture.long)")))
        let order = s.sections[0].tiles
        XCTAssertEqual(order, [.media("media/\(MediaPanelFixture.long)"), .media("media/Su-57 edit.mp4"),
                               .media("assets/A1/NUNCA MUDA QUICK BMW M3 EDIT.mp4"), .media("media/b-roll.mov")], "timeline first")
        XCTAssertTrue(s.keyDown(EditorKey(.right))); XCTAssertEqual(s.selected, order[1])
        XCTAssertTrue(s.keyDown(EditorKey(.down))); XCTAssertEqual(s.selected, order[3])
        XCTAssertTrue(s.keyDown(EditorKey(.left))); XCTAssertEqual(s.selected, order[2])
        XCTAssertTrue(s.keyDown(EditorKey(.down))); XCTAssertEqual(s.selected, .media("media/poster.png"), "down into Images")
        XCTAssertTrue(s.keyDown(EditorKey(.enter)))
        XCTAssertEqual(added, ["media/poster.png"])
        _ = drawn(s)
        XCTAssertTrue(s.keyDown(EditorKey(.enter, shift: true)))
        XCTAssertEqual(s.menu?.target, .media("media/poster.png"))
        XCTAssertTrue(s.keyDown(EditorKey(.escape))); XCTAssertNil(s.menu)
        XCTAssertTrue(s.keyDown(EditorKey(.escape))); XCTAssertNil(s.selected)
        XCTAssertFalse(s.keyDown(EditorKey(.down)))
    }

    /// Down past the visible rows scrolls the grid so the selected tile shows.
    func testKeyboardScrollsTheSelectionIntoView() throws {
        let s = MediaPanelFixture.panel()
        s.draw(PanelMeasureCanvas(), size: CanvasSize(364, 420))
        try press(s, .tile(.media("media/\(MediaPanelFixture.long)")))
        for _ in 0..<6 { _ = s.keyDown(EditorKey(.down)); s.draw(PanelMeasureCanvas(), size: CanvasSize(364, 420)) }
        let sel = try XCTUnwrap(s.selected)
        let r = try XCTUnwrap(s.hits.rect { $0 == .tile(sel) })
        XCTAssertGreaterThan(s.binScroll, 0)
        XCTAssertGreaterThanOrEqual(r.y, s.binRect.y - 0.01); XCTAssertLessThanOrEqual(r.maxY, s.binRect.maxY + 0.01)
    }

    /// Tab walks the controls left to right, top to bottom (the tab bar first, one stop), then enters the grid at one tile; Enter presses the
    /// focused control.
    func testTabWalksTheControlsThenTheGrid() throws {
        let s = MediaPanelFixture.panel()
        _ = drawn(s)
        var order: [LeftSidebarPanel.Hit] = []
        for _ in 0..<9 { _ = s.keyDown(EditorKey(.tab)); _ = drawn(s); if let f = s.focus.current { order.append(f) } }
        XCTAssertEqual(order, [.tab(.assets), .hideSidebar, .panelMenu, .switcher, .importMedia, .more, .search, .filter, .tile(.media("media/\(MediaPanelFixture.long)"))])
        XCTAssertEqual(s.selected, .media("media/\(MediaPanelFixture.long)"), "entering the grid selects its tile")
        for _ in 0..<5 { _ = s.keyDown(EditorKey(.tab, shift: true)) }
        XCTAssertEqual(s.focus.current, .switcher)
        _ = drawn(s)
        XCTAssertTrue(s.keyDown(EditorKey(.enter)))
        XCTAssertTrue(s.dropdown.isOpen, "Enter opens the focused switcher")
    }

    func testEmptyStatesOfferTheWayBack() throws {
        let s = MediaPanelFixture.panel()
        s.searchQuery = "zzz"
        var c = drawn(s)
        XCTAssertTrue(c.drawnStrings.contains("No media matches “zzz”"))
        try press(s, .clearSearch)
        XCTAssertEqual(s.searchQuery, "")
        s.filter = MediaFilter(kind: .fonts, usage: .inTimeline)
        c = drawn(s, c)
        XCTAssertTrue(c.drawnStrings.contains("No media matches the filter"))
        XCTAssertNotNil(s.hits.rect { $0 == .clearFilters })
        let empty = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        c = drawn(empty, c)
        XCTAssertTrue(c.drawnStrings.contains("Drop media files here"))
        XCTAssertNil(empty.hits.rect { $0 == .search }, "nothing to search yet")
        XCTAssertNotNil(empty.hits.rect { $0 == .importMedia })
    }

    /// The panel's text and control colours meet WCAG 2.2 AA in both modes: 4.5:1 for text, 3:1 for the focus ring
    /// and the glyphs that tell a tile's kind.
    func testColoursMeetAAInBothModes() {
        defer { Theme.setMode(.dark) }
        for mode in ThemeMode.allCases {
            Theme.setMode(mode)
            let t = ThemeTokens.self, bg = t.panelBgPair.now, input = t.panelInputPair.now, tile = t.neutral(900), pop = t.popoverPair.now
            let text: [(String, ThemeColor, ThemeColor)] = [
                ("Import", t.onAccent, t.primaryFillPair.now), ("Import hover", t.onAccent, t.primaryFillHoverPair.now),
                ("names and secondary text", t.textPairs[2].now, bg), ("placeholder", t.textPairs[2].now, input), ("names", t.textPairs[1].now, bg),
                ("menu shortcut", t.textPairs[2].now, pop), ("Clear", t.studioAccent, bg), ("error", t.red400, bg),
                ("tooltip", t.neutral(200), t.neutral(900)),
            ]
            for (what, fg, back) in text { XCTAssertGreaterThanOrEqual(fg.contrast(back), 4.5, "\(mode) \(what)") }
            let ui: [(String, ThemeColor, ThemeColor)] = [("focus ring", t.studioAccent, bg), ("kind glyph", t.textPairs[3].now, tile),
                                                          ("icon buttons", t.textPairs[3].now, input)]
            for (what, fg, back) in ui { XCTAssertGreaterThanOrEqual(fg.contrast(back), 3, "\(mode) \(what)") }
        }
    }
}
