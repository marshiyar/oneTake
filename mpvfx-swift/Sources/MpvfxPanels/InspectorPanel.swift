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
        case headerClear, headerReset, body, groupReset(String), groupEnabled(String), scrollbar
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
    /// Whether the timeline currently holds a copied grade. Selection compatibility is checked by the panel.
    public var gradeClipboardAvailable = false
    /// Called after a header click opened or closed a group (the host redraws); saving is done by `openGroupId`.
    public var onOpenGroupChanged: ((String) -> Void)?

    // Interaction state
    public private(set) var hits = HitMap<Hit>()

    /// Header bypasses exposed to the native canvas host after layout has populated `hits`.
    public var accessibilityControls: [CanvasAccessibilityControl] {
        buildGroups().compactMap { group in
            guard let label = group.accessibilityLabel, let value = group.enabled,
                  let frame = hits.rect(where: { $0 == .groupEnabled(group.id) }) else { return nil }
            return CanvasAccessibilityControl(label: label, value: value, frame: frame) { group.setEnabled?(!value) }
        }
    }
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
    var cropActive: String?
    /// The open colour picker (InspectorPanel+ColorPicker.swift), nil when closed.
    public internal(set) var colorPicker: ColorPickerState?
    /// The colour field whose last typed value was refused; its format hint shows until the next edit.
    public internal(set) var colorFieldError: String?
    /// Colours picked in this session, newest first (the picker's recent colours lead with them).
    public var recentColors: [String] = []
    /// Host hook: the composited stage frame at about this size, for the colour picker's eyedropper.
    public var stageFrame: ((_ pixelWidth: Int, _ pixelHeight: Int) -> PresetPreviewState)?
    var cropBefore: NativeClipCrop?
    var cropLinkAll = false
    struct Scrub { var key: String; var startX: Double; var value: Double; var current: Double; var moved: Bool }
    var scrub: Scrub?
    struct SliderDrag { var key: String; var track: CanvasRect; var min: Double; var max: Double; var current: Double; var vertical = false }
    var sliderDrag: SliderDrag?
    var lastRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    /// Custom-row drag in flight (row id, part).
    var customDrag: (String, Int)?
    /// Keyframes selected on the timeline (synced before each paint): the easing block's "Easing…" opens the panel
    /// on these when any are on the selected clip's eased channels, else on the keys at/before the playhead.
    public var selectedKeyframes: Set<TimelineKeyframeRef> = []
    /// "Easing…": open the Keyframe Easing panel on these keys of this clip (RightPanel shows its Easing tab).
    public var onOpenEasing: ((String, Set<TimelineKeyframeRef>) -> Void)?
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
    /// Host hook: the composited program frame at the playhead for the Grade scopes' Program mode, at most w x h.
    public var programScopeFrame: ((_ pixelWidth: Int, _ pixelHeight: Int) -> PresetPreviewState)?
    /// What the Grade scopes read (the Scopes row's Clip / Program switch). Every change is saved as
    /// `PanelPreferences.scopeSource`; `RightPanel.init` restores it.
    public var scopeSource: ColorScopes.Source = .clip {
        didSet { if scopeSource != oldValue, let layout { layout.update { $0.scopeSource = scopeSource } } }
    }
    /// Analyses scope frames off the draw thread; the host sets its `onReady` to redraw.
    public let scopeWorker = ScopeWorker()
    public var lutAssets: () -> [String] = { [] }
    /// Opens a select popover under `anchor` (the right panel's PanelDropdown); `pick` gets the chosen value.
    public var onOpenDropdown: ((_ key: String, _ options: [PanelDropdown.Option], _ selected: String?, _ anchor: CanvasRect,
                                 _ pick: @escaping (String) -> Void) -> Void)?
    /// The Composition section's preset select, from the last draw (the popover opens under it).
    var compositionPresetField: CanvasRect?
    /// The inline tab bars of the last draw, by bespoke row id (InspectorPanel+Tabs.swift).
    var tabBars: [String: InlineTabBar] = [:]

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
        hits.reset(); tabBars = [:]
        // The shelf went away (closed, the rack's owner changed, the selection or group moved on): the audition ends.
        defer { if let k = auditionKey, hits.rect(where: { $0 == .button(k) }) == nil { endAudition() } }
        c.fillRect(r, PanelTheme.panelBg)
        guard let editor, let headerH = drawSelectionHeader(c, r, editor) else { return }
        let groups = buildGroups().map { laidOut($0, c, width: r.width) }
        if !groups.contains(where: { $0.id == openGroupId }), let first = groups.first { openGroupId = first.id }
        // `data-flat-panel-body`: closed headers, the open group (header + its whole body), more closed headers, in
        // one column that scrolls as a whole.
        let body = CanvasRect(x: r.x, y: r.y + headerH, width: r.width, height: max(0, r.height - headerH))
        let total = groups.reduce(0.0) { $0 + Self.groupHeaderHeight + ($1.id == openGroupId ? Self.openBodyHeight($1, Self.groupHeaderHeight) : 0) }
        bodyMaxScroll = max(0, total - body.height)
        scrollForOpenGroup(groups, body: body)
        bodyScroller.clamp(max: bodyMaxScroll)
        bodyRect = body; bodyContentHeight = total
        c.withState {
            c.clip(body)
            drawGroups(c, groups, in: body)
        }
        drawFocusAndScrollbar(c, body: body, content: total)
    }

    /// Five grid steps: closed headers stack on the grid below the 48 pt clip header.
    static let groupHeaderHeight = 40.0

    /// The header for what is selected; returns its height, or nil when the panel shows no groups (several clips,
    /// the composition, or a selection the document no longer has).
    func drawSelectionHeader(_ c: CanvasContext, _ r: CanvasRect, _ editor: TimelineEditor) -> Double? {
        if !selection.isEmpty { audioGroupId = nil }
        if selection.count > 1 { drawMultiSelect(c, r); return nil }
        if let s = selected() {
            retireStaleEditors(editor, s)
            return drawHeader(c, r, s)
        }
        if let g = selectedBus() { return drawBusHeader(c, r, g) }
        if showsComposition { drawComposition(c, r, editor) }
        return nil
    }

    /// The scroll a group opening asked for, applied once against this layout.
    func scrollForOpenGroup(_ groups: [InspectorGroup], body: CanvasRect) {
        guard let i = groups.firstIndex(where: { $0.id == openGroupId }) else { return }
        if scrollOpenGroupToStart {
            bodyScroll = Double(i) * Self.groupHeaderHeight
            scrollOpenGroupToStart = false
        }
    }

    /// The column of group headers with the open group's body, scrolled, with the accordion entrance.
    func drawGroups(_ c: CanvasContext, _ groups: [InspectorGroup], in body: CanvasRect) {
        let p = enterProgress, headerH = Self.groupHeaderHeight
        var y = body.y - bodyScroll
        for g in groups {
            let open = g.id == openGroupId
            let slotH = headerH + (open ? Self.openBodyHeight(g, headerH) : 0)
            let entering = p < 1 && enteringGroups.contains(g.id)
            c.withState {
                if entering { c.translate(0, -4 * (1 - p)) }
                drawGroupHeader(c, CanvasRect(x: body.x, y: y, width: body.width, height: headerH), g, open: open)
                if open { drawGroupBody(c, CanvasRect(x: body.x, y: y + headerH, width: body.width, height: slotH - headerH), g) }
                // Opacity p over the column's uniform panel-bg: the backdrop laid over at 1 - p is the same blend.
                if entering { c.fillRect(CanvasRect(x: body.x, y: y, width: body.width, height: slotH), PanelTheme.panelBg.withAlpha(1 - p)) }
            }
            y += slotH
        }
    }

    /// The keyboard focus ring (body controls clip to the scrolling body; header ones draw as they are) and the
    /// overlay scrollbar while the column overflows.
    func drawFocusAndScrollbar(_ c: CanvasContext, body: CanvasRect, content: Double) {
        if let ring = focus.ringRect(hits) {
            c.withState {
                if ring.y >= body.y - 2 { c.clip(body) }
                PanelDraw.focusRing(c, ring)
            }
        }
        guard bodyMaxScroll > 0 else { return }
        hits.add(PanelScrollbar.zone(track: body), .scrollbar)
        PanelScrollbar.draw(c, track: body, offset: bodyScroll, content: content, hovered: hovered == .scrollbar || scrollbarGrab != nil,
                            opacity: bodyScroller.barOpacity)
    }

    /// The smallest open group (header and body), on the grid.
    static let minOpenGroupHeight = 176.0

    /// The open body: `PanelGrid.bodyPadding` above and below the rows' slots (its closing hairline sits in the bottom
    /// padding), and at least what makes the open group `minOpenGroupHeight`.
    static func openBodyHeight(_ g: InspectorGroup, _ headerH: Double) -> Double {
        let rows = g.rows.reduce(0) { $0 + $1.slotHeight } + g.spacing * Double(max(0, g.rows.count - 1))
        return max(minOpenGroupHeight - headerH, PanelGrid.bodyPadding * 2 + rows)
    }

    /// The layout pass before a group is measured and drawn: a row whose controls do not fit in the control column
    /// at this width (a segmented row's options, a slider's track, a number's field beside its keyframe gutter) stacks
    /// its label over them (issue #154).
    func laidOut(_ g: InspectorGroup, _ c: CanvasContext, width: Double) -> InspectorGroup {
        var g = g
        let content = max(0, width - 2 * PanelGrid.gutter)
        for i in g.rows.indices {
            let inset = g.rows[i].rail ? 12.0 : 0
            let row = CanvasRect(x: inset, y: 0, width: max(0, content - inset), height: PanelGrid.rowHeight)
            g.rows[i].stacked = Self.needsStacking(c, g.rows[i].kind, row: row)
        }
        return g
    }

    /// PropertyPanelFlatHeader: `px-4 py-3` row (43.5 + border-b): 15px Phosphor kind icon, gap-2.5, name
    /// (13 semibold, 19.5 line), trailing reset ↺ and clear × at 13px (`gap-2.5 text-panel-text-3`).
    func drawHeader(_ c: CanvasContext, _ r: CanvasRect, _ s: Selected) -> Double {
        let h = Self.clipHeaderHeight - 1
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
        hits.add(Self.target(clear), .headerClear)
        ax = clear.x - 11
        if let editor, editor.clip(s.id).map({ $0.clip.staticParameters != nil || !$0.clip.parameterTracks.isEmpty || $0.clip.crop != nil }) == true {
            let reset = CanvasRect(x: ax - 13, y: row.y + (h - 13) / 2, width: 13, height: 13)
            PanelIcon.reset.draw(c, in: reset, color: hovered == .headerReset ? PanelTheme.text1 : PanelTheme.text3)
            hits.add(Self.target(reset), .headerReset)
            ax = reset.x - 11
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
        let h = Self.clipHeaderHeight - 1
        let row = CanvasRect(x: r.x + 16, y: r.y, width: r.width - 32, height: h)
        PanelIcon.music.draw(c, in: CanvasRect(x: row.x, y: row.y + (h - 14) / 2, width: 14, height: 14), color: PanelTheme.audioViolet)
        let clear = CanvasRect(x: row.maxX - 16, y: row.y + (h - 16) / 2, width: 16, height: 16)
        PanelIcon.close.draw(c, in: clear.insetBy(2), color: hovered == .headerClear ? PanelTheme.text1 : PanelTheme.text3)
        hits.add(Self.target(clear), .headerClear)
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
        if let on = g.enabled {
            let target = CanvasRect(x: inner.maxX - 58, y: r.midY - 12, width: 28, height: 24)
            let track = CanvasRect(x: target.x + 3, y: target.midY - 6, width: 22, height: 12)
            c.fillRoundedRect(track, radius: 6, on ? PanelTheme.accent : PanelTheme.panelBorderInput)
            c.fillRoundedRect(CanvasRect(x: on ? track.maxX - 10 : track.x + 2, y: track.y + 2, width: 8, height: 8), radius: 4, PanelTheme.white)
            hits.add(target, .groupEnabled(g.id))
        }
        if open {
            let t = PanelDraw.text(c, g.title, in: inner, font: PanelTheme.font(12, .semibold), color: PanelTheme.text0)
            if g.enabled == false {   // a bypassed group says so beside its title, not only by the switch position
                let x = inner.x + t.width + 8
                PanelDraw.text(c, g.summary, in: CanvasRect(x: x, y: inner.y + 1, width: max(0, inner.maxX - 90 - x), height: inner.height),
                               font: PanelTheme.mono(9), color: PanelTheme.text4)
            }
            PanelIcon.groupCaretDown.draw(c, in: CanvasRect(x: inner.maxX - 12, y: r.y + (r.height - 12) / 2, width: 12, height: 12), color: PanelTheme.text3)
            if g.reset != nil {
                let offset = g.enabled == nil ? 34.0 : 78.0
                let rr = CanvasRect(x: inner.maxX - offset, y: r.y + (r.height - 12) / 2, width: 12, height: 12)
                PanelIcon.reset.draw(c, in: rr, color: hovered == .groupReset(g.id) ? PanelTheme.text1 : PanelTheme.text3)
                hits.add(Self.target(rr), .groupReset(g.id))
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

    /// Open body: `bg-panel-bg-inset` with the `PanelGrid` gutter and padding and a closing hairline; each row in its
    /// grid slot, rows `g.spacing` apart.
    func drawGroupBody(_ c: CanvasContext, _ box: CanvasRect, _ g: InspectorGroup) {
        c.fillRect(box.snapped, PanelTheme.panelBgInset)
        c.fillRect(CanvasRect(x: box.x, y: box.maxY - 1, width: box.width, height: 1).snapped, PanelTheme.panelHairline)
        hits.add(box, .body)
        for (row, slot) in zip(g.rows, Self.rowSlots(g, in: box)) {
            let inset = row.rail ? 12.0 : 0
            let rr = CanvasRect(x: slot.x + inset, y: slot.y + row.padY, width: slot.width - inset, height: row.height - 2 * row.padY)
            if row.rail { c.fillRect(CanvasRect(x: slot.x, y: slot.y, width: 2, height: row.height).snapped, PanelTheme.panelBorderInput) }
            if rr.maxY > lastRect.y && rr.y < lastRect.maxY { drawRow(c, rr, row) }
        }
    }

    /// Each row's grid slot inside an open body `box`: the gutter on both sides, the body padding on top, slots
    /// `g.spacing` apart. The layout audit (`PanelLayoutAuditTests`) checks these against the grid.
    static func rowSlots(_ g: InspectorGroup, in box: CanvasRect) -> [CanvasRect] {
        var y = box.y + PanelGrid.bodyPadding
        let x = box.x + PanelGrid.gutter, w = max(0, box.width - 2 * PanelGrid.gutter)
        return g.rows.map { row in
            defer { y += row.slotHeight + g.spacing }
            return CanvasRect(x: x, y: y, width: w, height: row.slotHeight)
        }
    }

    /// The clip, bus and composition headers' height with their closing hairline: on the grid, so the group headers
    /// below them are too.
    static let clipHeaderHeight = 48.0

    /// A pointer target around a small glyph: its box grown to at least `PanelGrid.minTarget` each way, same centre.
    static func target(_ glyph: CanvasRect) -> CanvasRect {
        let w = max(glyph.width, PanelGrid.minTarget), h = max(glyph.height, PanelGrid.minTarget)
        return CanvasRect(x: glyph.midX - w / 2, y: glyph.midY - h / 2, width: w, height: h)
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
    /// Hit key suffix of a slider's settings gear (`.keyframe("<slider key>#gear")`).
    static let gearSuffix = "#gear"
    /// A slider's settings gear shares the hit kind under its own key (Vignette and Grain also keyframe).
    func keyframeOrGearHit(_ k: String) {
        if k.hasSuffix(Self.gearSuffix), let st = slider(String(k.dropLast(Self.gearSuffix.count)))?.settings { st.toggle() } else { keyframe(k)?.toggle() }
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
        case .groupEnabled(let id): if let g = buildGroups().first(where: { $0.id == id }), let on = g.enabled { g.setEnabled?(!on) }
        case .field(let k): if let n = number(k) { field = PanelTextField(key: k, value: n.text) }
        case .scrub(let k): if let s = number(k)?.scrub { scrub = Scrub(key: k, startX: p.x, value: s.value, current: s.value, moved: false) }
        case .keyframe(let k): keyframeOrGearHit(k)
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
            let moved = focus.move(hits, forward: !k.shift) { [unowned self] in self.isFocusable($0) }
            if moved { revealFocus() }
            onEdited?(); return moved
        }
        guard var f = field else { return unfocusedKey(k) }
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

    /// A crop session or colour picker opened on another clip ends when the selection moves on.
    func retireStaleEditors(_ editor: TimelineEditor, _ s: Selected) {
        if cropActive != nil && cropActive != s.id { cropActive = nil }
        if cropActive == s.id && cropBefore == nil { cropBefore = editor.crop(clipId: s.id) ?? NativeClipCrop() }
        if let cp = colorPicker, cp.clipId != s.id { colorPicker = nil }
    }

    /// Keys with no field open: the colour picker's first, then Enter / Space / Esc on the focused control, then the
    /// Grade's own keys.
    func unfocusedKey(_ k: EditorKey) -> Bool {
        if let handled = pickerKey(k) { return handled }
        if focus.visible, case .custom(let id, let part)? = focus.current, let handler = customRow(id)?.keyPress {
            if handler(part, k) { onEdited?(); return true }
        }
        if focus.visible, let cur = focus.current, k.code == .enter || k.code == .space || k.code == .escape {
            if k.code == .escape { focus.visible = false; onEdited?(); return true }
            return press(cur)
        }
        return bodyKey(k)
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
