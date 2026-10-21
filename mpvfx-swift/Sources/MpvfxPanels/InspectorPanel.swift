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
import MpvfxTimeline

/// The Design tab: the flat inspector drawn natively. One accordion group is open at a time; closed groups
/// are summary rows above and below it. Rows edit the open document through TimelineEditor (undoable).
public final class InspectorPanel {
    public enum Hit: Equatable {
        case group(String), field(String), scrub(String), keyframe(String), kfPrev(String), kfNext(String), stopwatch(String), reset(String)
        case slider(String), toggle(String), segment(String, String), button(String), fxToggle(String), fxRemove(String)
        case headerClear, headerReset, body, groupReset(String), scrollbar
        case custom(String, Int)
    }

    public var editor: TimelineEditor?
    /// Selected clip ids (the timeline/stage selection).
    public var selection: [String] = []
    /// Playhead (composition seconds).
    public var time = 0.0
    /// The open accordion group ("" when all are closed). Every change, from a header click or a host reveal, is saved
    /// as `PanelPreferences.openInspectorGroup` so the next launch reopens it.
    public var openGroupId: String = "layout" {
        didSet { if openGroupId != oldValue, let layout { layout.update { $0.openInspectorGroup = openGroupId } } }
    }
    /// Where the open group is saved; set by `RightPanel.init`, nil for a standalone inspector (tests).
    weak var layout: PanelLayoutState?
    /// An audio group whose bus FX rack is shown while no clip is selected (timeline group header FX / name buttons).
    /// Selecting a clip retires it.
    public var audioGroupId: String?
    public var onEdited: (() -> Void)?
    public var onSeek: ((Double) -> Void)?
    public var onClearSelection: (() -> Void)?
    /// Grade clipboard actions owned by the timeline controller (shared with its menu and shortcuts).
    public var onCopyGrade: (() -> Bool)?
    public var onPasteGrade: (() -> Bool)?
    /// Called after a header click opened or closed a group (the host redraws); saving is done by `openGroupId`.
    public var onOpenGroupChanged: ((String) -> Void)?

    // Interaction state
    public private(set) var hits = HitMap<Hit>()
    public var hovered: Hit?
    public private(set) var field: PanelTextField?
    /// The body's scroll (wheel glides, trackpad 1:1, clamped) and its scrollbar fade.
    public internal(set) var bodyScroller = PanelScroller()
    public internal(set) var bodyScroll: Double {
        get { bodyScroller.offset }
        set { bodyScroller.set(newValue, max: .infinity) }
    }
    var bodyMaxScroll = 0.0
    /// Set when a group opens: the next layout scrolls the body so the open group's header sits at its top
    /// (`toggleOpen` → scroll the open group's header to the top), clamped to the end.
    var scrollOpenGroupToStart = false
    /// Set by showKeyframeEasing: the next layout scrolls the open group's "Keyframe easing" rows into view.
    var revealEasingRows = false
    var cropActive: String?
    var cropBefore: NativeClipCrop?
    var cropLinkAll = false
    struct Scrub { var key: String; var startX: Double; var value: Double; var current: Double; var moved: Bool }
    var scrub: Scrub?
    struct SliderDrag { var key: String; var track: CanvasRect; var min: Double; var max: Double; var current: Double; var vertical = false }
    var sliderDrag: SliderDrag?
    var lastRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    /// Custom-row drag in flight (row id, part).
    var customDrag: (String, Int)?
    /// Keyframes selected on the timeline (synced before each paint): the easing rows edit these when any are on the
    /// selected clip's eased channels, else the keys at/before the playhead.
    public var selectedKeyframes: Set<TimelineKeyframeRef> = []
    /// An ease-graph handle drag in flight (committed on release, one undo step).
    public internal(set) var easeDrag: EaseDrag?
    /// The ease graph's plot area and value range from the last draw.
    public internal(set) var easeGraphBox: EaseGraphBox?
    /// The Transform group's 3D transform disclosure (collapsed by default).
    public var transform3DOpen = false
    /// A 3D cube drag in flight (committed on release) and the cube's frame from the last draw.
    public internal(set) var cubeDrag: CubeDrag?
    public internal(set) var cubeBox: CanvasRect?
    /// Keyboard focus (Tab / ⇧Tab, Enter / Space) and its ring.
    public var focus = PanelFocus<Hit>()
    /// Groups whose header (and body, when open) play the 120 ms entrance (`hf-flat-group-enter`: opacity 0→1,
    /// translateY -4→0, ease-out): the one just toggled and the one it closed.
    public private(set) var enteringGroups: [String] = []
    var enterElapsed = 0.0
    public static let enterDuration = 0.12
    /// Asks the host to start calling `tick` (~60 Hz) until it returns false.
    public var onAnimate: (() -> Void)?
    /// The scrolling body (below the clip header) and its content height, from the last layout.
    var bodyRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    var bodyContentHeight = 0.0
    /// Scrollbar thumb drag: pointer y minus the thumb's top at the press.
    var scrollbarGrab: Double?
    /// Grade UI state (open curve tab, selected curve point / secondary, LUT and finish disclosure, copy scope).
    public var grade = GradeUIState()
    /// Effects UI state (catalog, family tab, the effect being edited).
    public var effectsUI = EffectsUIState()
    /// Audio FX rack UI state (open menu, open module, folded preset runs).
    public var audioFxUI = AudioFxUIState()
    /// Audition (InspectorPanel+Audition.swift): the host plays the request's document instead of the open one, or
    /// goes back to the open one on nil. Never an edit: nothing is written and nothing reaches the undo history.
    public var onAudition: ((AuditionRequest?) -> Void)?
    /// The shelf item being auditioned ("preset:…", "job:…", "add:…"), nil when none.
    public internal(set) var auditionKey: String?
    /// Host hooks: import a .cube LUT (returns the project-relative path) and list LUT assets.
    public var onImportLut: (() -> Void)?
    /// Host hook: the selected clip's current frame graded with a preset, for the Grade preset tiles (nil: no previews).
    public var presetPreview: ((PresetPreviewRequest) -> PresetPreviewState)?
    /// Host hook: the built-in sample picture graded with a tile's look or effect, for the Effects catalog tiles and
    /// for preset tiles whose clip has no picture (nil: those tiles show the "No preview renderer" placeholder).
    public var effectPreview: ((EffectPreviewRequest) -> PresetPreviewState)?
    /// Whether the clip has a picture the preset tiles can show (nil: assume it does).
    public var presetPreviewsAvailable: ((String) -> Bool)?
    /// "Retry look previews" (the host drops what it holds and renders again).
    public var onRetryPresetPreviews: (() -> Void)?
    /// Host hook: the selected clip's graded frame at the playhead for the Grade scopes, at most w x h pixels.
    public var scopeFrame: ((_ clipId: String, _ pixelWidth: Int, _ pixelHeight: Int) -> PresetPreviewState)?
    public var lutAssets: () -> [String] = { [] }
    /// Opens a select popover under `anchor` (the right panel's PanelDropdown); `pick` gets the chosen value.
    public var onOpenDropdown: ((_ key: String, _ options: [PanelDropdown.Option], _ selected: String?, _ anchor: CanvasRect,
                                 _ pick: @escaping (String) -> Void) -> Void)?
    /// The Composition section's preset select, from the last draw (the popover opens under it).
    var compositionPresetField: CanvasRect?

    public init() {}

    func addHit(_ r: CanvasRect, _ h: Hit) { hits.add(r, h) }

    /// Width of an open group's rows (`px-4` inside the panel), from the last layout; 375 before the first draw.
    var bodyContentWidth: Double { lastRect.width > 32 ? lastRect.width - 32 : 375 }

    /// FlatGroupHeader click (`toggleOpen`): one group open at a time; opening scrolls it to the body's top,
    /// closing keeps the scroll (clamped at the next layout).
    public func toggleGroup(_ id: String) {
        let opening = openGroupId != id
        if let animate = onAnimate {   // no host clock (tests, offscreen): no entrance
            enteringGroups = [id] + (opening && !openGroupId.isEmpty ? [openGroupId] : [])
            enterElapsed = 0
            animate()
        }
        openGroupId = opening ? id : ""
        if opening { scrollOpenGroupToStart = true }
        onOpenGroupChanged?(openGroupId)
        onEdited?()
    }

    /// Advances the accordion entrance; true while it is still running.
    @discardableResult
    public func tick(_ dt: Double) -> Bool {
        let scrolling = bodyScroller.tick(dt)
        guard !enteringGroups.isEmpty else { return scrolling }
        enterElapsed += max(0, dt)
        if enterElapsed >= Self.enterDuration { enteringGroups = []; enterElapsed = 0; return scrolling }
        return true
    }

    /// The entrance's eased progress 0…1 (the studio's `ease-out`, cubic-bezier(0, 0, 0.58, 1)); 1 when nothing is entering.
    public var enterProgress: Double {
        guard !enteringGroups.isEmpty else { return 1 }
        return Self.easeOut(min(1, enterElapsed / Self.enterDuration))
    }

    static func easeOut(_ x: Double) -> Double {
        // Solve bx(t) = x for the curve's t (Newton), then return by(t). P1 = (0, 0), P2 = (0.58, 1).
        func bx(_ t: Double) -> Double { 3 * (1 - t) * t * t * 0.58 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * t * t + t * t * t }
        var t = x
        for _ in 0..<8 {
            let d = 1.74 * (2 * t - 3 * t * t) + 3 * t * t   // dbx/dt
            let e = bx(t) - x
            if abs(e) < 1e-6 || abs(d) < 1e-6 { break }
            t = max(0, min(1, t - e / d))
        }
        return by(t)
    }

    public var groups: [InspectorGroup] { buildGroups() }
    public var isEditingText: Bool { field != nil }

    // MARK: Draw

    public func draw(_ c: CanvasContext, in r: CanvasRect) {
        lastRect = r
        hits.reset()
        // The shelf went away (closed, the rack's owner changed, the selection or group moved on): the audition ends.
        defer { if let k = auditionKey, hits.rect(where: { $0 == .button(k) }) == nil { endAudition() } }
        c.fillRect(r, PanelTheme.panelBg)
        guard let editor else { return }
        if !selection.isEmpty { audioGroupId = nil }
        if selection.count > 1 { drawMultiSelect(c, r); return }
        let headerH: Double
        if let s = selected() {
            if cropActive != nil && cropActive != s.id { cropActive = nil }
            if cropActive == s.id && cropBefore == nil { cropBefore = editor.crop(clipId: s.id) ?? NativeClipCrop() }
            headerH = drawHeader(c, r, s)
        } else if let g = selectedBus() {
            headerH = drawBusHeader(c, r, g)
        } else if showsComposition {
            drawComposition(c, r, editor); return
        } else { return }   // a selection the document no longer has: a blank panel
        var groups = buildGroups()
        if !groups.contains(where: { $0.id == openGroupId }), let first = groups.first { openGroupId = first.id }
        // `data-flat-panel-body`: closed headers, the open group (`min-h-[180px] flex-none`: header + its whole
        // body), more closed headers, in one column that scrolls as a whole.
        let body = CanvasRect(x: r.x, y: r.y + headerH, width: r.width, height: max(0, r.height - headerH))
        let headerRowH = 40.0
        let total = groups.reduce(0.0) { $0 + headerRowH + ($1.id == openGroupId ? Self.openBodyHeight($1, headerRowH) : 0) }
        bodyMaxScroll = max(0, total - body.height)
        if scrollOpenGroupToStart, let i = groups.firstIndex(where: { $0.id == openGroupId }) {
            bodyScroll = Double(i) * headerRowH
            scrollOpenGroupToStart = false
        }
        if revealEasingRows, let i = groups.firstIndex(where: { $0.id == openGroupId }) {
            revealEasingRows = false
            let g = groups[i]
            if let r = g.rows.firstIndex(where: { if case .heading("Keyframe easing", _) = $0.kind { return true }; return false }) {
                // Content y of the heading: the headers above, the open header, the body's 12 top padding, the rows above.
                let top = Double(i + 1) * headerRowH + 12 + g.rows[..<r].reduce(0) { $0 + $1.height + g.spacing }
                let bottom = top + g.rows[r...].reduce(0) { $0 + $1.height + g.spacing }
                if top < bodyScroll || bottom > bodyScroll + body.height { bodyScroll = min(bodyMaxScroll, max(0, min(top - 8, bottom - body.height + 12))) }
            }
        }
        bodyScroller.clamp(max: bodyMaxScroll)
        bodyRect = body; bodyContentHeight = total
        let p = enterProgress
        c.withState {
            c.clip(body)
            var y = body.y - bodyScroll
            for g in groups {
                let open = g.id == openGroupId
                let slotH = headerRowH + (open ? Self.openBodyHeight(g, headerRowH) : 0)
                let entering = p < 1 && enteringGroups.contains(g.id)
                c.withState {
                    if entering { c.translate(0, -4 * (1 - p)) }
                    drawGroupHeader(c, CanvasRect(x: r.x, y: y, width: r.width, height: headerRowH), g, open: open)
                    if open { drawGroupBody(c, CanvasRect(x: r.x, y: y + headerRowH, width: r.width, height: slotH - headerRowH), g) }
                    // Opacity p over the column's uniform panel-bg: the backdrop laid over at 1 - p is the same blend.
                    if entering { c.fillRect(CanvasRect(x: r.x, y: y, width: r.width, height: slotH), PanelTheme.panelBg.withAlpha(1 - p)) }
                }
                y += slotH
            }
            groups.removeAll()
        }
        if let ring = focus.ringRect(hits) {   // body controls clip to the scrolling body; header ones draw as they are
            c.withState {
                if ring.y >= body.y - 2 { c.clip(body) }
                PanelDraw.focusRing(c, ring)
            }
        }
        if bodyMaxScroll > 0 {
            hits.add(PanelScrollbar.zone(track: body), .scrollbar)
            PanelScrollbar.draw(c, track: body, offset: bodyScroll, content: total, hovered: hovered == .scrollbar || scrollbarGrab != nil,
                                opacity: bodyScroller.barOpacity)
        }
    }

    /// The open body: `px-4 py-3` around the rows plus its `border-b`, and at least what makes the open group 180.
    static func openBodyHeight(_ g: InspectorGroup, _ headerH: Double) -> Double {
        let rows = g.rows.reduce(0) { $0 + $1.height } + g.spacing * Double(max(0, g.rows.count - 1))
        return max(180 - headerH, 12 + rows + 12 + 1)
    }

    /// PropertyPanelFlatHeader: `px-4 py-3` row (43.5 + border-b): 15px Phosphor kind icon, gap-2.5, name
    /// (13 semibold, 19.5 line), trailing reset ↺ and clear × at 13px (`gap-2.5 text-panel-text-3`).
    func drawHeader(_ c: CanvasContext, _ r: CanvasRect, _ s: Selected) -> Double {
        let h = 43.5
        let row = CanvasRect(x: r.x + 16, y: r.y, width: r.width - 32, height: h)
        let icon: PanelIcon
        let iconColor: CanvasColor
        switch s.kind {
        case .video: icon = .film; iconColor = PanelTheme.media
        case .image: icon = .image; iconColor = PanelTheme.media
        case .audio: icon = .music; iconColor = PanelTheme.audioViolet
        case .element: icon = .layers; iconColor = PanelTheme.container
        }
        icon.draw(c, in: CanvasRect(x: row.x, y: row.y + (h - 15) / 2, width: 15, height: 15), color: iconColor)
        var ax = row.maxX
        let clear = CanvasRect(x: ax - 13, y: row.y + (h - 13) / 2, width: 13, height: 13)
        PanelIcon.close.draw(c, in: clear, color: hovered == .headerClear ? PanelTheme.text1 : PanelTheme.text3)
        hits.add(clear.insetBy(-5), .headerClear)
        ax = clear.x - 10
        if let editor, editor.clip(s.id).map({ $0.clip.staticParameters != nil || !$0.clip.parameterTracks.isEmpty || $0.clip.crop != nil }) == true {
            let reset = CanvasRect(x: ax - 13, y: row.y + (h - 13) / 2, width: 13, height: 13)
            PanelIcon.reset.draw(c, in: reset, color: hovered == .headerReset ? PanelTheme.text1 : PanelTheme.text3)
            hits.add(reset.insetBy(-5), .headerReset)
            ax = reset.x - 10
        }
        let nameX = row.x + 15 + 10
        let name = s.asset?.name ?? s.clip.id
        PanelDraw.text(c, name, in: CanvasRect(x: nameX, y: row.y + (h - 19.5) / 2, width: max(0, ax - nameX), height: 19.5),
                       font: PanelTheme.font(13, .semibold), color: PanelTheme.text0)
        c.fillRect(CanvasRect(x: r.x, y: r.y + h, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
        return h + 1
    }

    /// The bus rack's header: the group's name and "Audio group", with clear (existing header primitives).
    func drawBusHeader(_ c: CanvasContext, _ r: CanvasRect, _ g: NativeAudioGroup) -> Double {
        let h = 44.0
        let row = CanvasRect(x: r.x + 16, y: r.y, width: r.width - 32, height: h)
        PanelIcon.music.draw(c, in: CanvasRect(x: row.x, y: row.y + (h - 14) / 2, width: 14, height: 14), color: PanelTheme.audioViolet)
        let clear = CanvasRect(x: row.maxX - 16, y: row.y + (h - 16) / 2, width: 16, height: 16)
        PanelIcon.close.draw(c, in: clear.insetBy(2), color: hovered == .headerClear ? PanelTheme.text1 : PanelTheme.text3)
        hits.add(clear.insetBy(-4), .headerClear)
        let nameX = row.x + 24, avail = max(0, clear.x - 10 - nameX)
        let ns = PanelDraw.text(c, g.label ?? "Group", in: CanvasRect(x: nameX, y: row.y, width: avail * 0.6, height: h),
                                font: PanelTheme.font(13, .semibold), color: PanelTheme.text0)
        PanelDraw.text(c, "Audio group", in: CanvasRect(x: nameX + ns.width + 8, y: row.y + 1.5, width: max(0, avail - ns.width - 8), height: h),
                       font: PanelTheme.font(10), color: PanelTheme.text4)
        PanelDraw.hline(c, x0: r.x, x1: r.maxX, y: r.y + h, PanelTheme.panelHairline)
        return h + 1
    }

    /// FlatMultiSelectState: count and clear (grouping visuals has no native equivalent yet).
    func drawMultiSelect(_ c: CanvasContext, _ r: CanvasRect) {
        let row = CanvasRect(x: r.x + 16, y: r.y + 12, width: r.width - 32, height: 28)
        PanelDraw.text(c, "\(selection.count) clips selected", in: row, font: PanelTheme.font(11, .semibold), color: PanelTheme.text1)
        let clear = CanvasRect(x: row.maxX - 28, y: row.y, width: 28, height: 28)
        PanelDraw.text(c, "×", in: clear, font: PanelTheme.font(14), color: hovered == .headerClear ? PanelTheme.text1 : PanelTheme.text3, align: .center)
        hits.add(clear, .headerClear)
        PanelDraw.text(c, "Select a single clip to edit its properties.", in: CanvasRect(x: row.x, y: row.maxY + 4, width: row.width, height: 16),
                       font: PanelTheme.font(10), color: PanelTheme.text4)
    }

    func drawGroupHeader(_ c: CanvasContext, _ r: CanvasRect, _ g: InspectorGroup, open: Bool) {
        c.fillRect(r.snapped, PanelTheme.panelBg)
        hits.add(r, .group(g.id))   // first, so header accessories added after it win the hit test
        let inner = CanvasRect(x: r.x + 16, y: r.y, width: r.width - 32, height: r.height)
        if open {
            PanelDraw.text(c, g.title, in: inner, font: PanelTheme.font(12, .semibold), color: PanelTheme.text0)
            PanelIcon.groupCaretDown.draw(c, in: CanvasRect(x: inner.maxX - 12, y: r.y + (r.height - 12) / 2, width: 12, height: 12), color: PanelTheme.text3)
            if g.reset != nil {
                let rr = CanvasRect(x: inner.maxX - 12 - 10 - 12, y: r.y + (r.height - 12) / 2, width: 12, height: 12)
                PanelIcon.reset.draw(c, in: rr, color: hovered == .groupReset(g.id) ? PanelTheme.text1 : PanelTheme.text3)
                hits.add(rr.insetBy(-4), .groupReset(g.id))
            }
        } else {
            let t = PanelDraw.text(c, g.title, in: CanvasRect(x: inner.x, y: inner.y, width: inner.width - 20, height: inner.height),
                                   font: PanelTheme.font(12, .medium), color: hovered == .group(g.id) ? PanelTheme.text1 : PanelTheme.text2)
            PanelDraw.text(c, g.summary, in: CanvasRect(x: inner.x + t.width + 8, y: inner.y + 1, width: max(0, inner.width - t.width - 28), height: inner.height),
                           font: PanelTheme.mono(9), color: PanelTheme.text4)
            PanelIcon.groupCaretRight.draw(c, in: CanvasRect(x: inner.maxX - 12, y: r.y + (r.height - 12) / 2, width: 12, height: 12), color: PanelTheme.text5)
            c.fillRect(CanvasRect(x: r.x, y: r.maxY - 1, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
        }
    }

    /// Open body: `bg-panel-bg-inset px-4 py-3 border-b border-panel-hairline`, rows `g.spacing` apart.
    func drawGroupBody(_ c: CanvasContext, _ box: CanvasRect, _ g: InspectorGroup) {
        c.fillRect(box.snapped, PanelTheme.panelBgInset)
        c.fillRect(CanvasRect(x: box.x, y: box.maxY - 1, width: box.width, height: 1).snapped, PanelTheme.panelHairline)
        hits.add(box, .body)
        var y = box.y + 12
        let x = box.x + 16, w = box.width - 32
        for row in g.rows {
            let inset = row.rail ? 12.0 : 0
            let rr = CanvasRect(x: x + inset, y: y + row.padY, width: w - inset, height: row.height - 2 * row.padY)
            if row.rail { c.fillRect(CanvasRect(x: x, y: y, width: 2, height: row.height).snapped, PanelTheme.panelBorderInput) }
            if rr.maxY > lastRect.y && rr.y < lastRect.maxY { drawRow(c, rr, row) }
            y += row.height + g.spacing
        }
    }

    // MARK: Rows

    func drawRow(_ c: CanvasContext, _ r: CanvasRect, _ row: InspectorRow) {
        switch row.kind {
        case .number(let n): drawNumber(c, r, n, compact: false)
        case .pair(let label, let a, let b):
            // LayoutGeometryRows, grouped: `space-y-1` heading row (11px rowLabel, the group's keyframe navigation
            // on the right, h-5) over a `grid-cols-2 gap-2` of compact fields.
            let head = CanvasRect(x: r.x, y: r.y, width: r.width, height: 20)
            PanelDraw.text(c, label, in: CanvasRect(x: head.x, y: head.midY - 8.25, width: head.width, height: 16.5),
                           font: PanelTheme.font(11), color: PanelTheme.rowLabel)
            if let kf = a.keyframe { _ = drawKeyframeNav(c, right: head.maxX, midY: head.midY, key: a.key, kf) }
            let colW = (r.width - 8) / 2, fy = head.maxY + 4
            drawNumber(c, CanvasRect(x: r.x, y: fy, width: colW, height: 30), a, compact: true)
            drawNumber(c, CanvasRect(x: r.x + colW + 8, y: fy, width: colW, height: 30), b, compact: true)
        case .quad(let ns):
            let gap = 8.0, colW = (r.width - gap * Double(ns.count - 1)) / Double(max(1, ns.count))
            for (i, n) in ns.enumerated() {
                drawNumber(c, CanvasRect(x: r.x + Double(i) * (colW + gap), y: r.y + 3, width: colW, height: r.height - 6), n, compact: true)
            }
        case .slider(let s): drawSlider(c, r, s)
        case .toggle(let t): drawToggle(c, r, t)
        case .segmented(let s): drawSegmented(c, r, s)
        case .section(let t):
            c.fillRect(CanvasRect(x: r.x, y: r.y, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
            PanelDraw.tracked(c, t.uppercased(), in: CanvasRect(x: r.x, y: r.y + 7, width: r.width, height: 13.5),
                              font: PanelTheme.font(9, .semibold), tracking: 1.08, color: PanelTheme.text5)
        case .heading(let t, let trailing):
            PanelDraw.text(c, t.uppercased(), in: r, font: PanelTheme.font(10, .medium), color: PanelTheme.text2)
            if let trailing { PanelDraw.text(c, trailing, in: r, font: PanelTheme.font(9), color: PanelTheme.text3, align: .right) }
        case .subheader(let t, let buttons):
            PanelDraw.text(c, t, in: r, font: PanelTheme.font(11, .semibold), color: PanelTheme.text1)
            var x = r.maxX
            for b in buttons.reversed() {
                let w = c.measureText(b.label, font: PanelTheme.font(10, .medium)).width + 4
                let br = CanvasRect(x: x - w, y: r.y, width: w, height: r.height)
                drawButton(c, br, b, plain: true)
                x = br.x - 8
            }
        case .note(let s):
            var y = r.y
            for line in Self.wrap(s, perLine: 48) {
                PanelDraw.text(c, line, in: CanvasRect(x: r.x, y: y, width: r.width, height: 16), font: PanelTheme.font(10), color: PanelTheme.text4)
                y += 16
            }
        case .buttons(let bs):
            let gap = 6.0, w = (r.width - gap * Double(bs.count - 1)) / Double(max(1, bs.count))
            for (i, b) in bs.enumerated() { drawButton(c, CanvasRect(x: r.x + Double(i) * (w + gap), y: r.y + 2, width: w, height: r.height - 4), b, plain: false) }
        case .fxNode(let n): drawFxNode(c, r, n)
        case .spacer: break
        case .custom(let cr): cr.draw(c, r, self)
        }
    }

    static func wrap(_ s: String, perLine: Int) -> [String] {
        var lines: [String] = [], cur = ""
        for word in s.split(separator: " ") {
            if cur.count + word.count + 1 > perLine, !cur.isEmpty { lines.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + word
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    /// FlatRow (`min-h-[30px]`): 11px grey label (rowLabel); the value field (`border-b pb-px font-mono`) 146 wide on
    /// the right, its value in the tier colour (the accent once changed, and while scrubbed; `text-neutral-100` while
    /// typed; `disabled:text-neutral-600`), then the keyframe gutter and, for a custom value, the hover reset. Compact (`rounded bg-panel-bg px-1.5 gap-1`): the value
    /// fills the field.
    func drawNumber(_ c: CanvasContext, _ r: CanvasRect, _ n: InspectorRow.Number, compact: Bool) {
        let isHover = hovered == .field(n.key) || hovered == .scrub(n.key) || hovered == .reset(n.key)
            || hovered == .keyframe(n.key) || hovered == .kfPrev(n.key) || hovered == .kfNext(n.key) || hovered == .stopwatch(n.key)
        let font = PanelTheme.mono(11)
        if compact { c.fillRoundedRect(r.snapped, radius: PanelTheme.radius, PanelTheme.panelBg) }
        let pad = compact ? 6.0 : 0.0
        var right = r.maxX - pad
        if n.tier == .explicitCustom, n.reset != nil {
            let rr = CanvasRect(x: right - 11, y: r.midY - 5.5, width: 11, height: 11)
            if isHover { PanelIcon.reset.draw(c, in: rr, color: hovered == .reset(n.key) ? PanelTheme.text1 : PanelTheme.text3) }
            hits.add(rr.insetBy(-3), .reset(n.key))
            right = rr.x - 4
        }
        if let kf = n.keyframe, !compact { right = drawKeyframeNav(c, right: right, midY: r.midY, key: n.key, kf) - 4 }
        let labelFont = PanelTheme.font(11)
        let lw = c.measureText(n.label, font: labelFont).width
        let labelRect = CanvasRect(x: r.x + pad, y: r.midY - 8.25, width: lw, height: 16.5)
        PanelDraw.text(c, n.label, in: labelRect, font: labelFont, color: n.tier.labelColor)
        let labelHit = CanvasRect(x: labelRect.x, y: r.y, width: lw + 4, height: r.height)
        if n.scrub != nil && !n.disabled { hits.add(labelHit, .scrub(n.key)) }
        let fieldX = compact ? labelRect.maxX + 4 : max(labelRect.maxX + 12, right - 146)
        let field = CanvasRect(x: fieldX, y: r.midY - 9.25, width: max(0, right - fieldX), height: 18.5)
        let editing = self.field?.key == n.key
        var text = n.text
        if let s = scrub, s.key == n.key, let fmt = n.scrub?.format { text = fmt(s.current) }
        if editing, let f = self.field { text = f.draft }
        let tr = CanvasRect(x: field.x, y: field.y, width: field.width, height: 16.5)
        if editing { c.fillRect(CanvasRect(x: tr.x - 3, y: tr.y, width: tr.width + 6, height: tr.height), PanelTheme.panelInput) }
        PanelDraw.text(c, text, in: tr, font: font,
                       color: n.tier.valueInk(disabled: n.disabled, typing: editing, adjusting: scrub?.key == n.key), align: .right)
        if editing {   // caret after the draft
            c.fillRect(CanvasRect(x: tr.maxX + 1, y: tr.midY - 6, width: 1, height: 12), PanelTheme.accent)
        }
        let underline: CanvasColor = n.tier == .explicitCustom
            ? PanelTheme.accent.withAlpha(isHover ? 0.7 : 0.3)
            : PanelTheme.panelBorderInput.withAlpha(isHover ? 1 : 0.5)
        c.fillRect(CanvasRect(x: field.x, y: field.maxY - 1, width: field.width, height: 1).snapped, editing ? PanelTheme.accent : underline)
        if !n.disabled { hits.add(CanvasRect(x: field.x, y: r.y, width: field.width, height: r.height), .field(n.key)) }
    }

    /// Keyframe controls on the property's row (docs/DESIGN.md Rollout 5): the 12px stopwatch (Phosphor Timer, the
    /// accent while the property is animated, else #a3a3a3 at .6; hover full opacity) 4px before the keyframe
    /// navigation (`flex h-5 items-center gap-0.5`, 41 wide): 12×20 stepper with the 6×10 arrow
    /// (`M5 1L1 5L5 9`, #a3a3a3, 1.4 round, opacity .25 when there is nowhere to go), the 9px KeyframeDiamond
    /// (`p-0.5`; ghost .25 / inactive .6 #a3a3a3 outline, active #3CE6AC filled; hover full opacity), the next
    /// stepper. Returns the gutter's left edge.
    @discardableResult
    func drawKeyframeNav(_ c: CanvasContext, right: Double, midY: Double, key: String, _ kf: InspectorRow.Keyframe) -> Double {
        let bg = PanelTheme.panelBgInset
        let x0 = right - 41
        let arrow = PanelTheme.neutral400
        let watch = CanvasRect(x: x0 - 16, y: midY - 6, width: 12, height: 12)
        let watchColor = kf.state == .none ? arrow.over(bg, opacity: hovered == .stopwatch(key) ? 1 : 0.6)
            : (hovered == .stopwatch(key) ? PanelTheme.text0 : PanelTheme.accent)
        PanelIcon.phosphor(.timer).draw(c, in: watch, color: watchColor)
        hits.add(watch.insetBy(-2), .stopwatch(key))
        let prevBtn = CanvasRect(x: x0, y: midY - 10, width: 12, height: 20)
        let hasPrev = kf.prev != nil, hasNext = kf.next != nil
        c.strokeSVG(["M5 1L1 5L5 9"], viewBox: 10, in: CanvasRect(x: prevBtn.x + 3, y: midY - 5, width: 10, height: 10),
                    arrow.over(bg, opacity: hasPrev ? 1 : 0.25), width: 1.4)
        if hasPrev { hits.add(prevBtn.insetBy(-2), .kfPrev(key)) }
        let d = CanvasRect(x: x0 + 14, y: midY - 6.5, width: 13, height: 13)
        let dia = CanvasRect(x: d.x + 2, y: d.y + 2, width: 9, height: 9)
        let hov = hovered == .keyframe(key)
        switch kf.state {
        case .onKey: c.fill(Self.keyframeDiamond(dia), PanelTheme.mint)
        case .animated, .none:
            let o = hov ? 1 : (kf.state == .animated ? 0.6 : 0.25)
            c.stroke(Self.keyframeDiamond(dia), arrow.over(bg, opacity: o), StrokeStyle(width: 1.2 * 0.9))
        }
        hits.add(d.insetBy(-2), .keyframe(key))
        let nextBtn = CanvasRect(x: x0 + 29, y: midY - 10, width: 12, height: 20)
        c.strokeSVG(["M1 1L5 5L1 9"], viewBox: 10, in: CanvasRect(x: nextBtn.x + 3, y: midY - 5, width: 10, height: 10),
                    arrow.over(bg, opacity: hasNext ? 1 : 0.25), width: 1.4)
        if hasNext { hits.add(nextBtn.insetBy(-2), .kfNext(key)) }
        return watch.x
    }

    /// KeyframeDiamond's `<rect x=5 y=0.7 width=6 height=6 rx=1 transform="rotate(45 5 0.7)">` in a 10-unit
    /// view box, mapped into the 9px box.
    static func keyframeDiamond(_ box: CanvasRect) -> CanvasPath {
        let s = box.width / 10, k = 0.5522847498
        let ca = cos(Double.pi / 4), sa = sin(Double.pi / 4)
        func map(_ x: Double, _ y: Double) -> CanvasPoint {   // rect space (0…6) → rotated about (5, 0.7)
            CanvasPoint(box.x + (5 + x * ca - y * sa) * s, box.y + (0.7 + x * sa + y * ca) * s)
        }
        var p = CanvasPath()
        p.move(to: map(1, 0)); p.line(to: map(5, 0))
        p.curve(to: map(6, 1), c1: map(5 + k, 0), c2: map(6, 1 - k)); p.line(to: map(6, 5))
        p.curve(to: map(5, 6), c1: map(6, 5 + k), c2: map(5 + k, 6)); p.line(to: map(1, 6))
        p.curve(to: map(0, 5), c1: map(1 - k, 6), c2: map(0, 5 + k)); p.line(to: map(0, 1))
        p.curve(to: map(1, 0), c1: map(0, 1 - k), c2: map(1 - k, 0))
        p.close()
        return p
    }

    /// FlatSlider (`min-h-[28px] gap-2.5`): 86px grey label (rowLabel), `h-5 flex-1` track (2px bg-panel-hover line; a
    /// 1×4 text-5 centre tick; a text-5 fill from the left only for a custom value), knob 7px text-4 (8px white
    /// when custom), `w-11` mono 10 value in the tier colour (the accent once changed, and while dragged;
    /// `neutral600` when disabled), `w-3.5` reset slot. An optional settings gear sits 6px after it.
    func drawSlider(_ c: CanvasContext, _ r: CanvasRect, _ s: InspectorRow.Slider) {
        var row = r
        if let st = s.settings {
            let gear = CanvasRect(x: r.maxX - 12, y: r.midY - 6, width: 12, height: 12)
            let hov = hovered == .keyframe(s.key)
            PanelIcon.phosphor(.gear).draw(c, in: gear, color: hov || st.active ? PanelTheme.text1 : PanelTheme.text4)
            hits.add(gear.insetBy(-3), .keyframe(s.key))
            row = CanvasRect(x: r.x, y: r.y, width: r.width - 18, height: r.height)
        }
        PanelDraw.text(c, s.label, in: CanvasRect(x: row.x, y: row.midY - 8.25, width: 86, height: 16.5), font: PanelTheme.font(11), color: s.tier.labelColor)
        var right = row.maxX
        if let kf = s.keyframe, s.settings == nil { right = drawKeyframeNav(c, right: right, midY: row.midY, key: s.key, kf) - 10 }
        if s.centerTick || s.reset != nil {
            let slot = CanvasRect(x: right - 14, y: row.midY - 5.5, width: 14, height: 11)
            if s.tier == .explicitCustom, s.reset != nil {
                PanelIcon.reset.draw(c, in: CanvasRect(x: slot.x, y: slot.y, width: 11, height: 11),
                                     color: hovered == .reset(s.key) ? PanelTheme.text1 : PanelTheme.text3)
                hits.add(slot.insetBy(-2), .reset(s.key))
            }
            right = slot.x - 10
        }
        let valueRect = CanvasRect(x: right - 44, y: row.midY - 7.5, width: 44, height: 15)
        let dragging = sliderDrag?.key == s.key
        let pos = dragging ? sliderDrag!.current : s.position
        let custom = s.tier == .explicitCustom || dragging
        PanelDraw.text(c, dragging ? s.format(pos) : s.display, in: valueRect, font: PanelTheme.mono(10),
                       color: s.tier.valueInk(disabled: s.disabled, adjusting: dragging), align: .right)
        let track = CanvasRect(x: row.x + 96, y: row.midY - 10, width: max(10, valueRect.x - 10 - (row.x + 96)), height: 20)
        let span = max(1e-9, s.max - s.min)
        let pct = max(0, min(1, (pos - s.min) / span))
        let lineY = track.midY - 1
        c.fillRoundedRect(CanvasRect(x: track.x, y: lineY, width: track.width, height: 2), radius: 1, PanelTheme.panelHover)
        if s.centerTick { c.fillRect(CanvasRect(x: track.midX - 0.5, y: lineY - 1, width: 1, height: 4), PanelTheme.text5) }
        if custom { c.fillRoundedRect(CanvasRect(x: track.x, y: lineY, width: track.width * pct, height: 2), radius: 1, PanelTheme.text5) }
        let k = custom ? 8.0 : 7.0
        c.fill(.roundedRect(CanvasRect(x: track.x + track.width * pct - k / 2, y: track.midY - k / 2, width: k, height: k), radius: k / 2),
               custom ? PanelTheme.white : PanelTheme.text4)
        if !s.disabled { hits.add(track, .slider(s.key)) }
    }

    /// FlatToggle: grey label (rowLabel), 24×14 pill, knob 10px (accent on the right when on, text-4 on the left when off).
    func drawToggle(_ c: CanvasContext, _ r: CanvasRect, _ t: InspectorRow.Toggle) {
        PanelDraw.text(c, t.label, in: r, font: PanelTheme.font(11), color: t.tier.labelColor)
        let sw = CanvasRect(x: r.maxX - 24, y: r.y + (r.height - 14) / 2, width: 24, height: 14)
        c.fillRoundedRect(sw, radius: 7, t.on ? PanelTheme.accent.withAlpha(0.35) : PanelTheme.panelHover)
        let knob = CanvasRect(x: t.on ? sw.maxX - 12 : sw.x + 2, y: sw.y + 2, width: 10, height: 10)
        c.fillRoundedRect(knob, radius: 5, t.on ? PanelTheme.accent : PanelTheme.text4)
        hits.add(CanvasRect(x: sw.x - 4, y: r.y, width: sw.width + 4, height: r.height), .toggle(t.key))
    }

    /// FlatSegmentedRow (`min-h-[32px]`): 11px grey label (rowLabel); options `gap-0.5`, each `px-1.5 py-1 text-[11px]
    /// border-b-2` (16.5 line + 8 + 2): the active one text-0 over a 2px accent underline, the rest text-4
    /// (hover text-2) over a transparent one. No container.
    func drawSegmented(_ c: CanvasContext, _ r: CanvasRect, _ s: InspectorRow.Segmented) {
        let font = PanelTheme.font(11)
        PanelDraw.text(c, s.label, in: CanvasRect(x: r.x, y: r.midY - 8.25, width: r.width, height: 16.5), font: font, color: PanelTheme.rowLabel)
        var x = r.maxX
        let bh = 26.5
        for o in s.options.reversed() {
            let w = c.measureText(o.label, font: font).width + 12
            let or = CanvasRect(x: x - w, y: r.midY - bh / 2, width: w, height: bh)
            let hov = hovered == .segment(s.key, o.key)
            PanelDraw.text(c, o.label, in: CanvasRect(x: or.x, y: or.y + 4, width: w, height: 16.5), font: font,
                           color: o.active ? PanelTheme.text0 : (hov ? PanelTheme.text2 : PanelTheme.text4), align: .center)
            if o.active { c.fillRect(CanvasRect(x: or.x, y: or.maxY - 2, width: w, height: 2), PanelTheme.accent) }
            hits.add(or, .segment(s.key, o.key))
            x = or.x - 2
        }
    }

    func drawButton(_ c: CanvasContext, _ r: CanvasRect, _ b: InspectorRow.Button, plain: Bool) {
        let hov = hovered == .button(b.key)
        let font = PanelTheme.font(plain ? 10 : 11, .medium)
        switch b.style {
        case .accent: PanelDraw.text(c, b.label, in: r, font: font, color: PanelTheme.accent.withAlpha(hov ? 1 : 0.9), align: .center)
        case .muted: PanelDraw.text(c, b.label, in: r, font: font, color: hov ? PanelTheme.text1 : PanelTheme.text3, align: .center)
        case .danger: PanelDraw.text(c, b.label, in: r, font: font, color: PanelTheme.red400, align: .center)
        case .chip, .chipActive:
            let active = b.style == .chipActive
            c.fillRoundedRect(r, radius: PanelTheme.radiusMd, active ? PanelTheme.accent.withAlpha(0.18) : (hov ? PanelTheme.panelHover : PanelTheme.panelInput))
            c.strokeRoundedRect(r.insetBy(0.5), radius: PanelTheme.radiusMd - 0.5, active ? PanelTheme.accent.withAlpha(0.5) : PanelTheme.panelBorderInput, width: 1)
            PanelDraw.text(c, b.label, in: r.insetBy(4), font: PanelTheme.font(10, .medium), color: active ? PanelTheme.text0 : PanelTheme.text2, align: .center)
        }
        if !b.disabled { hits.add(r, .button(b.key)) }
    }

    /// FX rack row: bypass dot, name, type, remove ×.
    func drawFxNode(_ c: CanvasContext, _ r: CanvasRect, _ n: InspectorRow.FxNode) {
        let dot = CanvasRect(x: r.x, y: r.y + (r.height - 14) / 2, width: 24, height: 14)
        c.fillRoundedRect(dot, radius: 7, n.enabled ? PanelTheme.accent.withAlpha(0.35) : PanelTheme.panelHover)
        c.fillRoundedRect(CanvasRect(x: n.enabled ? dot.maxX - 12 : dot.x + 2, y: dot.y + 2, width: 10, height: 10), radius: 5,
                          n.enabled ? PanelTheme.accent : PanelTheme.text4)
        hits.add(dot.insetBy(-3), .fxToggle(n.key))
        let rm = CanvasRect(x: r.maxX - 14, y: r.y + (r.height - 14) / 2, width: 14, height: 14)
        PanelIcon.close.draw(c, in: rm.insetBy(2), color: hovered == .fxRemove(n.key) ? PanelTheme.red400 : PanelTheme.text4)
        hits.add(rm.insetBy(-3), .fxRemove(n.key))
        let tx = dot.maxX + 8
        let ls = PanelDraw.text(c, n.label, in: CanvasRect(x: tx, y: r.y, width: max(0, rm.x - tx - 8) * 0.6, height: r.height),
                                font: PanelTheme.font(11, .medium), color: n.enabled ? PanelTheme.text1 : PanelTheme.text4)
        if n.detail != n.label {
            PanelDraw.text(c, n.detail, in: CanvasRect(x: tx + ls.width + 6, y: r.y + 1, width: max(0, rm.x - tx - ls.width - 14), height: r.height),
                           font: PanelTheme.mono(9), color: PanelTheme.text5)
        }
    }

    // MARK: Row lookup

    func allRows() -> [InspectorRow] {
        let open = showsComposition ? Self.compositionGroupId : openGroupId
        return buildGroups().first { $0.id == open }?.addressableRows ?? []
    }

    func number(_ key: String) -> InspectorRow.Number? {
        for r in allRows() {
            switch r.kind {
            case .number(let n) where n.key == key: return n
            case .pair(_, let a, let b): if a.key == key { return a }; if b.key == key { return b }
            case .quad(let ns): if let n = ns.first(where: { $0.key == key }) { return n }
            default: continue
            }
        }
        return nil
    }
    func slider(_ key: String) -> InspectorRow.Slider? {
        for r in allRows() { if case .slider(let s) = r.kind, s.key == key { return s } }
        return nil
    }
    func keyframe(_ key: String) -> InspectorRow.Keyframe? { number(key)?.keyframe ?? slider(key)?.keyframe }
    func reset(_ key: String) -> (() -> Void)? { number(key)?.reset ?? slider(key)?.reset }
    func toggle(_ key: String) -> InspectorRow.Toggle? {
        for r in allRows() { if case .toggle(let t) = r.kind, t.key == key { return t } }
        return nil
    }
    func segmented(_ key: String) -> InspectorRow.Segmented? {
        for r in allRows() { if case .segmented(let s) = r.kind, s.key == key { return s } }
        return nil
    }
    func button(_ key: String) -> InspectorRow.Button? {
        for r in allRows() {
            switch r.kind {
            case .buttons(let bs): if let b = bs.first(where: { $0.key == key }) { return b }
            case .subheader(_, let bs): if let b = bs.first(where: { $0.key == key }) { return b }
            default: continue
            }
        }
        return nil
    }
    func customRow(_ id: String) -> InspectorCustomRow? {
        for r in allRows() { if case .custom(let c) = r.kind, c.id == id { return c } }
        return nil
    }
    func fxNode(_ key: String) -> InspectorRow.FxNode? {
        for r in allRows() { if case .fxNode(let n) = r.kind, n.key == key { return n } }
        return nil
    }

    // MARK: Input

    /// Commits a focused field (blur), returns whether one was open.
    @discardableResult
    public func commitField() -> Bool {
        guard let f = field else { return false }
        field = nil
        if f.draft != f.original { number(f.key)?.commit(f.draft) }
        return true
    }

    public func pointerDown(_ p: CanvasPoint) -> Bool {
        focus.pointerPressed()
        // A press ends any audition first, so a pick commits on top of the stored chain, never the auditioned one.
        endAudition()
        guard lastRect.contains(p) else { commitField(); return false }
        let hit = hits.hit(p)
        if case .field(let k)? = hit, field?.key == k { return true }
        commitField()
        guard let hit else { return true }
        switch hit {
        case .group(let id):
            toggleGroup(id)
        case .groupReset(let id): buildGroups().first { $0.id == id }?.reset?()
        case .field(let k): if let n = number(k) { field = PanelTextField(key: k, value: n.text) }
        case .scrub(let k): if let s = number(k)?.scrub { scrub = Scrub(key: k, startX: p.x, value: s.value, current: s.value, moved: false) }
        case .keyframe(let k): if let st = slider(k)?.settings { st.toggle() } else { keyframe(k)?.toggle() }
        case .kfPrev(let k): keyframe(k)?.prev?()
        case .kfNext(let k): keyframe(k)?.next?()
        case .stopwatch(let k): keyframe(k)?.stopwatch()
        case .reset(let k): reset(k)?()
        case .slider(let k):
            if let s = slider(k), let tr = hits.rect(where: { $0 == .slider(k) }) {
                sliderDrag = SliderDrag(key: k, track: tr, min: s.min, max: s.max, current: s.position, vertical: s.vertical)
                sliderMove(p)
            }
        case .toggle(let k): if let t = toggle(k) { t.set(!t.on) }
        case .segment(let k, let o): segmented(k)?.select(o)
        case .button(let k): button(k)?.action()
        case .fxToggle(let k): fxNode(k)?.toggle()
        case .fxRemove(let k): fxNode(k)?.remove()
        case .headerClear: audioGroupId = nil; onClearSelection?()
        case .headerReset: if let editor, let s = selected(), editor.resetDesign(clipId: s.id) { onEdited?() }
        case .body: break
        case .scrollbar:
            if let t = PanelScrollbar.thumb(track: bodyRect, offset: bodyScroll, content: bodyContentHeight) {
                if !t.contains(p) {   // a press on the track pages the thumb there
                    bodyScroll = PanelScrollbar.offset(forThumbTop: p.y - t.height / 2, track: bodyRect, content: bodyContentHeight)
                    scrollbarGrab = t.height / 2
                } else { scrollbarGrab = p.y - t.y }
                onEdited?()
            }
        case .custom(let id, let part):
            if let row = customRow(id) { customDrag = (id, part); row.pointer(part, p, 0); onEdited?() }
        }
        return true
    }

    func sliderMove(_ p: CanvasPoint) {
        guard var d = sliderDrag else { return }
        let pct = d.vertical ? max(0, min(1, (d.track.maxY - p.y) / max(1, d.track.height)))
            : max(0, min(1, (p.x - d.track.x) / max(1, d.track.width)))
        d.current = d.min + pct * (d.max - d.min)
        sliderDrag = d
    }

    /// Returns true when a redraw is needed.
    public func pointerMove(_ p: CanvasPoint) -> Bool {
        if let g = scrollbarGrab {
            bodyScroll = PanelScrollbar.offset(forThumbTop: p.y - g, track: bodyRect, content: bodyContentHeight); return true
        }
        if sliderDrag != nil { sliderMove(p); return true }
        if let (id, part) = customDrag { customRow(id)?.pointer(part, p, 1); return true }
        if var s = scrub, let n = number(s.key)?.scrub {
            let dx = p.x - s.startX
            if abs(dx) > 2 { s.moved = true }
            s.current = s.value + (dx * n.step).rounded(toPlaces: n.step < 1 ? 3 : 0)
            scrub = s
            return true
        }
        let h = lastRect.contains(p) ? hits.hit(p) : nil
        // Hover unchanged still re-checks the audition: a shelf reopened under a resting pointer starts it again.
        guard h != hovered else { updateAudition(); return false }
        hovered = h
        updateAudition()
        return true
    }

    public func pointerUp(_ p: CanvasPoint) {
        if scrollbarGrab != nil { scrollbarGrab = nil; onEdited?() }
        if let (id, part) = customDrag { customDrag = nil; customRow(id)?.pointer(part, p, 2); onEdited?() }
        if let d = sliderDrag { sliderDrag = nil; slider(d.key)?.commit(d.current); onEdited?() }
        if let s = scrub {
            scrub = nil
            if s.moved { number(s.key)?.scrub?.apply(s.current) }
            else if let n = number(s.key) { field = PanelTextField(key: s.key, value: n.text) }   // click on label focuses
            onEdited?()
        }
    }

    /// `dy` in points from the host: precise (trackpad) deltas move 1:1, wheel line steps glide (PanelScroller).
    public func scroll(_ p: CanvasPoint, dy: Double, precise: Bool = false) -> Bool {
        guard lastRect.contains(p) else { return false }
        if bodyScroller.scroll(by: dy, precise: precise, max: bodyMaxScroll) { onAnimate?() }
        return true
    }

    /// Keys go to a focused field first. Tab moves to the next field of the open group.
    public func keyDown(_ k: EditorKey) -> Bool {
        if k.code == .tab {   // Tab from a field commits it, then focus moves on
            if field != nil { commitField(); onEdited?() }
            let moved = focus.move(hits, forward: !k.shift, Self.focusable)
            if moved { revealFocus() }
            onEdited?(); return moved
        }
        guard var f = field else {
            if focus.visible, let cur = focus.current, k.code == .enter || k.code == .space || k.code == .escape {
                if k.code == .escape { focus.visible = false; onEdited?(); return true }
                return press(cur)
            }
            return gradeKey(k)
        }
        switch f.key(k) {
        case .commit: field = f; commitField(); onEdited?(); return true
        case .cancel: field = nil; onEdited?(); return true
        case .editing: field = f; onEdited?(); return true
        case .none: return false
        }
    }
}

extension PropertyValueTier: Comparable {
    var rank: Int { switch self { case .default: 0; case .explicitDefault: 1; case .explicitCustom: 2 } }
    public static func < (a: PropertyValueTier, b: PropertyValueTier) -> Bool { a.rank < b.rank }
}

extension Double {
    func rounded(toPlaces n: Int) -> Double { let m = pow(10, Double(n)); return (self * m).rounded() / m }
}

extension InspectorPanel {
    /// What Tab stops on: buttons, toggles, segments, headers, fields, the effect controls and bespoke-row parts.
    static func focusable(_ h: Hit) -> Bool {
        switch h {
        case .body, .scrollbar, .scrub, .slider: false
        default: true
        }
    }

    /// Enter / Space on the focused control: a press at its centre (and release, for drags and bespoke rows).
    func press(_ h: Hit) -> Bool {
        guard let r = hits.rect(where: { $0 == h }) else { return false }
        let visible = focus.visible
        let c = CanvasPoint(r.midX, r.midY)
        _ = pointerDown(c)
        if case .field = h {} else { pointerUp(c) }
        focus.visible = visible; focus.current = h
        onEdited?()
        return true
    }

    /// Scrolls the body so the focused control is inside it.
    func revealFocus() {
        guard let cur = focus.current, let r = hits.rect(where: { $0 == cur }), bodyRect.height > 0 else { return }
        if cur == .headerClear || cur == .headerReset { return }   // the clip header does not scroll
        if r.y < bodyRect.y { bodyScroll = max(0, bodyScroll - (bodyRect.y - r.y) - 8) }
        else if r.maxY > bodyRect.maxY { bodyScroll = min(bodyMaxScroll, bodyScroll + (r.maxY - bodyRect.maxY) + 8) }
    }
}
