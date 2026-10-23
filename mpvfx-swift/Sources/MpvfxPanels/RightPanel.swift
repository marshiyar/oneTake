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

/// One render in the Renders tab, filled by the host from the export lane's jobs and history.
public struct RenderJobView: Equatable {
    public enum Status: String, Equatable { case queued, rendering, complete, failed, cancelled }
    public var id: String
    public var name: String
    public var status: Status
    public var stage: String
    public var progress: Double          // 0…1
    public var detail: String?           // "1080×1920 · 12.3 MB · 0:42"
    public var error: String?
    public var thumbnail: CanvasImage?
    /// Seconds since 1970 ("1h ago"), file size ("46 MB") and render time ("42s"); `detail` is the fallback line.
    public var createdAt: Double?
    public var sizeBytes: Double?
    public var durationMs: Double?
    public init(id: String, name: String, status: Status, stage: String = "", progress: Double = 0, detail: String? = nil, error: String? = nil, thumbnail: CanvasImage? = nil,
                createdAt: Double? = nil, sizeBytes: Double? = nil, durationMs: Double? = nil) {
        self.id = id; self.name = name; self.status = status; self.stage = stage; self.progress = progress; self.detail = detail; self.error = error; self.thumbnail = thumbnail
        self.createdAt = createdAt; self.sizeBytes = sizeBytes; self.durationMs = durationMs
    }
}

/// Export settings the Renders tab edits (PersistedRenderSettings).
public struct RenderSettingsModel: Equatable, Codable {
    public var format: String = "mp4"
    public var quality: String = "standard"
    public var fps: Double = 30
    public var resolution: String = "auto"
    public var customWidth: Double = 1920
    public var customHeight: Double = 1080
    public init() {}
}

public enum RenderAction: Equatable { case start(RenderSettingsModel), cancel(String), delete(String), reveal(String), retry(String), hideFinished, publish(String) }

/// The right panel: the tab strip (Design · Easing · Renders (n), then hide and the panel menu), the Design tab (the
/// flat inspector), the Easing tab (KeyframeEasingPanel) and the Renders tab. Collapsed: the 40px rail with the show button.
public final class RightPanel {
    public enum Hit: Equatable {
        case hide, show, design, easing, renders, showRenders, panelMenu, tabOverflow
        case format, resolution, fps, quality, customW, customH, export, formatInfo
        case preset, presetName, savePreset, deletePreset
        case job(String), cancel(String), delete(String), reveal(String), retry(String), hideFinished, dismissError
        case confirmDelete(String), keep(String), thumb(String), listScrollbar
        case content
        /// The render row this hit belongs to.
        var jobId: String? {
            switch self {
            case .job(let id), .cancel(let id), .delete(let id), .reveal(let id), .retry(let id), .confirmDelete(let id), .keep(let id), .thumb(let id): id
            default: nil
            }
        }
    }
    public let layout: PanelLayoutState
    public let inspector = InspectorPanel()
    public let easing = KeyframeEasingPanel()
    public let dropdown = PanelDropdown()
    public var jobs: [RenderJobView] = []
    public var settings = RenderSettingsModel()
    public var renderPresets: [RenderPreset] = []
    public var presetName = ""
    public var onSavePreset: ((String, RenderSettingsModel) -> Void)?
    public var onDeletePreset: ((String) -> Void)?
    public var canvasSize = CanvasSize(1920, 1080)
    public var lastRenderSeconds: Double?
    public var actionError: String?
    public var onRender: ((RenderAction) -> Void)?
    public var onSettingsChanged: ((RenderSettingsModel) -> Void)?
    public var onChange: (() -> Void)?
    /// In the dock, each tab is its own panel: this instance shows only that tab, over its whole rect, without the
    /// strip (the dock's tab bar is its header). nil: the Design · Renders strip with both tabs.
    public var dockedTab: RightPanelTab?
    /// The tab on show: the docked one, else the strip's choice.
    var shownTab: RightPanelTab { dockedTab ?? layout.rightPanelTab }
    /// The row whose × was pressed: it shows "Delete?" / "Keep" until answered or the pointer leaves it.
    public var confirmingDelete: String?
    /// Wall clock for "1h ago" (seconds since 1970); tests pin it.
    public var now: () -> Double = { Date().timeIntervalSince1970 }
    /// Keyboard focus on the Renders tab and the panel header (the inspector keeps its own on the Design tab).
    public var focus = PanelFocus<Hit>()

    public internal(set) var hits = HitMap<Hit>()
    public var hovered: Hit?
    var size = CanvasSize(0, 0)
    var contentRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    var field: PanelTextField?
    var listScroller = PanelScroller()
    var listScroll: Double { get { listScroller.offset } set { listScroller.set(newValue, max: .infinity) } }
    var listMax = 0.0
    /// Asks the host to call `tick` (~60 Hz) until it returns false (wheel glides, scrollbar fades, the accordion).
    public var onAnimate: (() -> Void)? { didSet { inspector.onAnimate = onAnimate; easing.onAnimate = onAnimate } }
    var listRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    var pressedInInspector = false
    var pressedInEasing = false
    /// The tab strip as the last draw laid it out (the overflow menu lists its hidden tabs).
    var tabLayout = PanelTabBar.Layout.empty

    public init(layout: PanelLayoutState) {
        self.layout = layout
        // The group the user left open last time; Transform when nothing was saved.
        inspector.openGroupId = layout.prefs.openInspectorGroup ?? "layout"
        inspector.scopeSource = layout.prefs.scopeSource ?? .clip
        if let order = layout.prefs.designGroupOrder { inspector.designOrder = DesignGroups.sanitized(order: order) }
        inspector.layout = layout
        inspector.onOpenEasing = { [weak self] clipId, refs in
            guard let self else { return }
            self.showKeyframeEasing(clipId: clipId, refs: refs)
            self.onChange?()
        }
        // The inspector's selects (the Composition preset) open this panel's popover, drawn over both tabs.
        inspector.onOpenDropdown = { [weak self] key, options, selected, anchor, pick in
            guard let self else { return }
            let bounds = CanvasRect(x: 0, y: 0, width: self.size.width, height: self.size.height)
            self.dropdown.open(key: key, options: options, selected: selected, anchor: anchor, bounds: bounds) { [weak self] v in
                pick(v); self?.onChange?()
            }
        }
    }

    public var isRendering: Bool { jobs.contains { $0.status == .rendering || $0.status == .queued } }
    public var rendersLabel: String { jobs.isEmpty ? "Renders" : "Renders (\(jobs.count))" }

    /// What the status line says for the control under the pointer.
    public var hint: String? {
        switch hovered {
        case .hide?: "Hide the panel"
        case .show?: "Show the panel"
        case .panelMenu?: "Panel menu"
        case .design?: "Properties of the selection, or of the composition"
        case .easing?: "Keyframe easing: graphs, curve and presets for the selected keys"
        case .renders?, .showRenders?: "Export settings and past renders"
        case .export?: "Render the composition with these settings"
        default: shownTab == .easing ? easing.hint : nil
        }
    }

    /// Opens the Easing tab on `refs` of `clipId` (the keyframe menu's "Edit Easing…", the inspector's "Easing…"):
    /// shows the panel, selects the clip and those keys, and picks their property. False when no key has easing
    /// (the panel is left as it was).
    @discardableResult
    public func showKeyframeEasing(clipId: String, refs: Set<TimelineKeyframeRef>) -> Bool {
        let keys = refs.filter { $0.clipId == clipId && KeyframeEasingTarget.easedParameterIds.contains($0.parameterId) }
        guard let first = keys.sorted(by: KeyframeEasingTarget.inTimeOrder).first else { return false }
        inspector.selection = [clipId]
        if let group = TimelineEditor.keyframeEasingGroup(first.parameterId) { inspector.openGroupId = group }
        easing.clipId = clipId
        easing.selectedKeyframes = keys
        easing.state.chosenProperty = first.parameterId
        easing.state.pinnedSelection = nil
        layout.setRightCollapsed(false)
        layout.setRightTab(.easing)
        return true
    }

    /// Native controls currently visible in the custom-drawn Design panel.
    public var accessibilityControls: [CanvasAccessibilityControl] {
        guard !layout.effectiveRightCollapsed, layout.rightPanelTab == .design else { return [] }
        return inspector.accessibilityControls
    }

    /// The dropdown key of the panel menu.
    static let menuKey = "panel-menu"

    // MARK: Draw

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        self.size = size
        hits.reset()
        let r = CanvasRect(x: 0, y: 0, width: size.width, height: size.height)
        if layout.effectiveRightCollapsed {   // the rail
            hits.add(PanelTabStrip.drawRail(c, r, icon: .sidebarHideLeft, hovered: hovered == .show), .show)
            return
        }
        c.fillRect(r, PanelTheme.panelBg)
        c.withState {
            c.clip(r)
            if dockedTab != nil { drawTab(c, r); return }
            let strip = CanvasRect(x: 0, y: 0, width: r.width, height: PanelTabStrip.height)
            PanelTabStrip.drawBackground(c, strip)
            let hide = PanelTabStrip.buttonRect(strip, index: 1), menu = PanelTabStrip.buttonRect(strip, index: 0)
            drawTabs(c, strip: strip, end: hide.x - PanelTabStrip.buttonGap)
            PanelTabStrip.iconButton(c, hide, icon: .sidebarShowLeft, hovered: hovered == .hide)
            hits.add(hide, .hide)
            PanelTabStrip.iconButton(c, menu, icon: .panelMenu, hovered: hovered == .panelMenu, open: dropdown.key == Self.menuKey)
            hits.add(menu, .panelMenu)
            drawTab(c, CanvasRect(x: 0, y: strip.maxY, width: r.width, height: max(0, r.height - strip.maxY)))
        }
        if let ring = focus.ringRect(hits) {
            c.withState {
                if listRect.height > 0, ring.y >= listRect.y - 2, shownTab == .renders { c.clip(listRect) }
                PanelDraw.focusRing(c, ring, radius: PanelTheme.radiusMd)
            }
        }
        dropdown.draw(c)
    }

    /// The shown tab's content in `rect`.
    func drawTab(_ c: CanvasContext, _ rect: CanvasRect) {
        contentRect = rect
        switch shownTab {
        case .design: inspector.draw(c, in: contentRect)
        case .easing: inspector.endAudition(); easing.draw(c, in: contentRect)   // the Design tab's shelf is gone
        case .renders: inspector.endAudition(); drawRenders(c, contentRect)
        }
    }

    /// What Tab stops on in the header and the Renders tab.
    static func focusable(_ h: Hit) -> Bool {
        switch h {
        case .content, .job, .listScrollbar: false
        default: true
        }
    }

    /// The tab bar is one Tab stop: the selected tab (arrows move between tabs).
    func isFocusable(_ h: Hit) -> Bool {
        guard Self.focusable(h) else { return false }
        switch h {
        case .design: return layout.rightPanelTab == .design
        case .easing: return layout.rightPanelTab == .easing
        case .renders: return layout.rightPanelTab == .renders
        default: return true
        }
    }

    /// The header's controls: the tabs, the overflow button, hide and the panel menu.
    static func isHeader(_ h: Hit) -> Bool {
        switch h {
        case .design, .easing, .renders, .tabOverflow, .hide, .panelMenu: true
        default: false
        }
    }

    // MARK: Renders

    /// The formats the media engine writes (formats.md). WebM is not offered: the engine cannot write it yet.
    static let formats: [PanelDropdown.Option] = [.init(value: "mp4", label: "MP4"), .init(value: "mov", label: "MOV (PNG, alpha)")]
    /// A saved setting may still name WebM (saved before it was withdrawn): it shows as "WebM (not supported yet)"
    /// and Export reports the engine's refusal ("WebM export is not supported yet.").
    static func formatLabel(_ value: String) -> String {
        formats.first { $0.value == value }?.label ?? formatInfoTitle[value] ?? value
    }
    static let qualities: [PanelDropdown.Option] = [
        .init(value: "draft", label: "Draft"), .init(value: "standard", label: "Standard"), .init(value: "high", label: "High Quality"),
    ]
    static let rates: [PanelDropdown.Option] = [.init(value: "24", label: "24 fps"), .init(value: "30", label: "30 fps"), .init(value: "60", label: "60 fps")]
    static let formatInfo: [String: String] = [
        "mp4": "Best for general use. H.264 video with lossless FLAC sound.",
        "mov": "Transparent video: lossless PNG frames with 8-bit alpha and 16-bit PCM sound. Very large files.",
        "webm": "The editor cannot write WebM yet. Choose MP4 or MOV.",
    ]

    /// The Renders tab's resolution choices for the composition (CompositionRenderResolution): its own size, then
    /// the short edges whose scaled size fits the 8K envelope, each with the size it renders at, then custom.
    func resolutionOptions() -> [PanelDropdown.Option] {
        CompositionRenderResolution.choices(compositionWidth: canvasSize.width, compositionHeight: canvasSize.height).map {
            PanelDropdown.Option(value: $0.storedValue, label: $0 == .custom ? "Custom width…" : resolutionText($0))
        }
    }

    /// The Resolution select's text for the current setting (a saved fixed preset reads as the scale it means).
    var resolutionLabel: String { resolutionText(CompositionRenderResolution(stored: settings.resolution)) }

    func resolutionText(_ r: CompositionRenderResolution) -> String {
        let w = canvasSize.width, h = canvasSize.height
        let d = r.dimensions(compositionWidth: w, compositionHeight: h, customWidth: settings.customWidth)
        let size = d.map { "\(Int($0.width))×\(Int($0.height))" } ?? "over the 8K limit"
        switch r {
        case .auto: return "Composition · \(size)"
        case .shortEdge(let n): return "\(n == 2160 ? "4K" : n == 4320 ? "8K" : "\(Int(n))p") · \(size)"
        case .custom: return "Custom · \(size)"
        }
    }

    static func ratio(_ w: Double, _ h: Double) -> String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let a = Int(w), b = Int(h), g = max(1, gcd(a, b))
        return "\(a / g):\(b / g)"
    }

    /// Quality changes the H.264 encode only (MOV frames are lossless PNG).
    var showQuality: Bool { settings.format == "mp4" }

    /// The Renders tab: the settings block (`px-3 py-3 border-b`, FormatExportButton `flex-col gap-3`), the action
    /// error strip, then the job list (`flex-1 overflow-y-auto`) with its "N renders · Hide finished" header.
    func drawRenders(_ c: CanvasContext, _ r: CanvasRect) {
        c.fillRect(r, PanelTheme.panelBg)
        var y = drawRenderPresets(c, r) + 12
        let x = r.x + 12, w = r.width - 24
        let gap = 8.0, colW = (w - gap) / 2
        let label = PanelTheme.font(10), lc = PanelTheme.text4
        func select(_ hit: Hit, _ title: String, _ value: String, _ rect: CanvasRect) {
            PanelDraw.text(c, title, in: CanvasRect(x: rect.x, y: rect.y, width: rect.width, height: 15), font: label, color: lc)
            let f = CanvasRect(x: rect.x, y: rect.y + 19, width: rect.width, height: 28)   // label 15 + gap-1
            PanelSelect.draw(c, f, text: value, hovered: hovered == hit, disabled: isRendering,
                             fill: isRendering ? PanelTheme.panelInput.withAlpha(0.5) : PanelTheme.panelInput)
            if !isRendering { hits.add(f, hit) }
        }
        select(.format, "Format", Self.formatLabel(settings.format), CanvasRect(x: x, y: y, width: colW, height: 47))
        // About video formats: the 12px circle-question after "Format" (gap-1), text-5 → text-3 on hover.
        let info = CanvasRect(x: x + c.measureText("Format", font: label).width + 4 + 2, y: y + 1.5, width: 12, height: 12)
        PanelIcon.help.draw(c, in: info, color: hovered == .formatInfo ? PanelTheme.text3 : PanelTheme.text5, lineWidth: 2)
        hits.add(info.target(in: CanvasRect(x: r.x, y: r.y, width: r.width, height: y + 19 - r.y)), .formatInfo)   // above the field
        // Scales the whole composition, aspect kept; the frame's shape is the composition size (Design tab).
        select(.resolution, "Output size", resolutionLabel, CanvasRect(x: x + colW + gap, y: y, width: colW, height: 47))
        y += 47 + gap
        select(.fps, "Frame rate", "\(Int(settings.fps)) fps", CanvasRect(x: x, y: y, width: colW, height: 47))
        if showQuality {
            select(.quality, "Quality", Self.qualities.first { $0.value == settings.quality }?.label ?? settings.quality,
                   CanvasRect(x: x + colW + gap, y: y, width: colW, height: 47))
        }
        y += 47 + 12
        if settings.resolution == "custom" {   // custom W×H (aspect locked): grid-cols-2 gap-2 rounded-md border bg-panel-input/40 p-2
            let box = CanvasRect(x: x, y: y, width: w, height: 85)
            c.fillRoundedRect(box, radius: PanelTheme.radiusMd, PanelTheme.panelInput.withAlpha(0.4))
            c.strokeRoundedRect(box.insetBy(0.5), radius: PanelTheme.radiusMd, PanelTheme.panelBorder, width: 1)
            let cw = (w - 18 - gap) / 2
            let customHeight = CompositionRenderResolution.customHeight(forWidth: settings.customWidth, compositionWidth: canvasSize.width,
                                                                        compositionHeight: canvasSize.height)
            for (i, (title, hit, v)) in [("Width", Hit.customW, settings.customWidth), ("Height", Hit.customH, customHeight)].enumerated() {
                let fx = box.x + 9 + Double(i) * (cw + gap)
                PanelDraw.text(c, title, in: CanvasRect(x: fx, y: box.y + 9, width: cw, height: 15), font: label, color: lc)
                let f = CanvasRect(x: fx, y: box.y + 28, width: cw, height: 28)
                c.fillRoundedRect(f, radius: PanelTheme.radiusMd, hovered == hit ? PanelTheme.panelHover : PanelTheme.panelInput)
                let editing = field?.key == (i == 0 ? "w" : "h")
                PanelDraw.text(c, editing ? field!.draft : "\(Int(v))", in: CanvasRect(x: f.x + 8, y: f.y, width: f.width - 16, height: f.height),
                               font: PanelTheme.font(11), color: editing ? PanelTheme.text0 : PanelTheme.text1)
                if editing { PanelDraw.focusRing(c, f, radius: PanelTheme.radiusMd) }
                hits.add(f, hit)
            }
            let ratio = canvasSize.width > 0 && canvasSize.height > 0 ? Self.ratio(canvasSize.width, canvasSize.height) : "—"
            PanelDraw.text(c, "Composition ratio \(ratio) kept. Maximum 8K.",
                           in: CanvasRect(x: box.x + 9, y: box.maxY - 23, width: box.width - 18, height: 13.5), font: PanelTheme.font(9), color: lc)
            y = box.maxY + 12
        }
        // Export: Button primary md (h-8, bg-white text-neutral-950, text-sm semibold), loading shows the spinner.
        let eb = CanvasRect(x: x, y: y, width: w, height: 32)
        let disabled = isRendering
        c.fillRect(eb, disabled ? PanelTheme.white.withAlpha(0.5) : (hovered == .export ? PanelTheme.neutral200 : PanelTheme.white))
        let title = isRendering ? "Rendering…" : "Export", tf = PanelTheme.font(14, .semibold)
        if isRendering {
            let tw = c.measureText(title, font: tf).width, sx = eb.midX - (tw + 21) / 2
            let sp = CanvasRect(x: sx, y: eb.midY - 7.7, width: 15.4, height: 15.4)
            PanelIcon.spinnerArc.draw(c, in: sp, color: PanelTheme.neutral950.withAlpha(0.25), lineWidth: 3)
            c.strokeSVG(["M22 12a10 10 0 1 1-20 0a10 10 0 1 1 20 0"], viewBox: 24, in: sp, PanelTheme.neutral950.withAlpha(0.25), width: 3)
            PanelIcon.spinnerArc.draw(c, in: sp, color: PanelTheme.neutral950, lineWidth: 3)
            PanelDraw.text(c, title, in: CanvasRect(x: sp.maxX + 5.5, y: eb.y + 6, width: tw + 2, height: 20), font: tf, color: PanelTheme.neutral950)
        } else {
            PanelDraw.text(c, title, in: CanvasRect(x: eb.x, y: eb.y + 6, width: eb.width, height: 20), font: tf, color: PanelTheme.neutral950, align: .center)
        }
        if !disabled { hits.add(eb, .export) }
        y = eb.maxY
        if let s = lastRenderSeconds, !isRendering {   // `-mt-1.5` under the button
            PanelDraw.text(c, "Last render took \(Self.eta(s))", in: CanvasRect(x: x, y: y + 6, width: w, height: 13.5), font: PanelTheme.font(9), color: PanelTheme.text5, align: .center)
            y += 6 + 13.5
        }
        y += 12
        PanelDraw.hline(c, x0: r.x, x1: r.maxX, y: y, PanelTheme.panelBorder)
        y += 1
        if let err = actionError {   // role=alert strip: px-3 py-2 border-b bg-red-500/10, 10px red-400, ✕ dismiss
            let lines = Array(InspectorPanel.wrap(err, perLine: max(12, Int((w - 24) / 5.2))).prefix(4))
            let er = CanvasRect(x: r.x, y: y, width: r.width, height: Double(lines.count) * 15 + 16)
            c.fillRect(er, PanelTheme.red500.withAlpha(0.1))
            for (i, line) in lines.enumerated() {
                PanelDraw.text(c, line, in: CanvasRect(x: x, y: er.y + 8 + Double(i) * 15, width: w - 16, height: 15), font: label, color: PanelTheme.red400)
            }
            let d = CanvasRect(x: x + w - 8.4, y: er.y + 8, width: 8.4, height: 15)
            PanelDraw.text(c, "✕", in: d, font: label, color: hovered == .dismissError ? PanelTheme.text2 : PanelTheme.text4, align: .right)
            hits.add(d.insetBy(-4), .dismissError)
            y = er.maxY
            PanelDraw.hline(c, x0: r.x, x1: r.maxX, y: y, PanelTheme.panelBorder)
            y += 1
        }
        // List
        let list = CanvasRect(x: r.x, y: y, width: r.width, height: max(0, r.maxY - y))
        listRect = list
        c.withState {
            c.clip(list)
            if jobs.isEmpty {   // 20px film-grid icon (stroke 1.5, text-5) over "No renders yet", gap-2, centered
                let ic = CanvasRect(x: list.midX - 10, y: list.midY - 19, width: 20, height: 20)
                c.strokeSVG(["M4.18 2h15.64A2.18 2.18 0 0 1 22 4.18v15.64A2.18 2.18 0 0 1 19.82 22H4.18A2.18 2.18 0 0 1 2 19.82V4.18A2.18 2.18 0 0 1 4.18 2z",
                             "M7 2v20M17 2v20M2 12h20M2 7h5M2 17h5M17 17h5M17 7h5"], viewBox: 24, in: ic, PanelTheme.text5, width: 1.5)
                PanelDraw.text(c, "No renders yet", in: CanvasRect(x: list.x, y: ic.maxY + 8, width: list.width, height: 15), font: label, color: PanelTheme.text5, align: .center)
                return
            }
            var cy = list.y - listScroll
            let finished = jobs.filter { $0.status != .rendering }.count
            if finished > 0 {   // px-3 py-1.5 border-b
                let hr = CanvasRect(x: list.x, y: cy, width: list.width, height: 27)
                PanelDraw.text(c, "\(jobs.count) render\(jobs.count == 1 ? "" : "s")", in: CanvasRect(x: x, y: hr.y + 6, width: w / 2, height: 15), font: label, color: lc)
                let hw = c.measureText("Hide finished", font: label).width
                let hb = CanvasRect(x: x + w - hw, y: hr.y + 6, width: hw, height: 15)
                PanelDraw.text(c, "Hide finished", in: hb, font: label, color: hovered == .hideFinished ? PanelTheme.text2 : lc)
                hits.add(hb, .hideFinished)
                PanelDraw.hline(c, x0: list.x, x1: list.maxX, y: hr.maxY, PanelTheme.panelBorder)
                cy += 28
            }
            for (i, j) in jobs.enumerated() {
                cy += drawJob(c, CanvasRect(x: list.x, y: cy, width: list.width, height: 0), j, last: i == jobs.count - 1)
            }
            listMax = max(0, cy + listScroll - list.maxY)
            listScroller.clamp(max: listMax)
        }
        drawListScrollbar(c, list)
        if dropdown.isOpen == false, hovered == .formatInfo {   // the format popover: w-52 p-2 bg-panel-input border-neutral-700
            // The current format (a withdrawn saved one included), then the formats the picker offers.
            let cur = Self.formatInfoTitle[settings.format] == nil ? Self.formats[0].value : settings.format
            let others = Self.formats.filter { $0.value != cur }
            var lines: [(String, CanvasFont, CanvasColor)] = [(Self.formatInfoTitle[cur] ?? cur, PanelTheme.font(10, .semibold), PanelTheme.text1)]
            for l in InspectorPanel.wrap(Self.formatInfo[cur] ?? "", perLine: 40) { lines.append((l, PanelTheme.font(9), PanelTheme.text3)) }
            let sepAt = lines.count
            for f in others {
                for l in InspectorPanel.wrap("\(Self.formatInfoTitle[f.value] ?? f.label) — \(Self.formatInfo[f.value] ?? "")", perLine: 40) {
                    lines.append((l, PanelTheme.font(9), PanelTheme.text4))
                }
            }
            let tip = CanvasRect(x: info.x - 2, y: info.maxY + 6, width: min(208, w), height: Double(lines.count) * 13.5 + 30)
            c.fillRoundedRect(tip, radius: PanelTheme.radius, PanelTheme.panelInput)
            c.strokeRoundedRect(tip.insetBy(0.5), radius: PanelTheme.radius, PanelTheme.neutral700, width: 1)
            var ty = tip.y + 8
            for (i, l) in lines.enumerated() {
                if i == sepAt { ty += 6; PanelDraw.hline(c, x0: tip.x + 8, x1: tip.maxX - 8, y: ty, PanelTheme.neutral800); ty += 7 }
                PanelDraw.text(c, l.0, in: CanvasRect(x: tip.x + 8, y: ty, width: tip.width - 16, height: 13.5), font: l.1, color: l.2)
                ty += 13.5
            }
        }
    }

    static let formatInfoTitle = ["mp4": "MP4 (H.264 + FLAC)", "mov": "MOV (PNG + PCM, alpha)", "webm": "WebM (not supported yet)"]

    /// The list's thin overlay scrollbar while it can scroll.
    func drawListScrollbar(_ c: CanvasContext, _ list: CanvasRect) {
        guard listMax > 0 else { return }
        hits.add(PanelScrollbar.zone(track: list), .listScrollbar)
        PanelScrollbar.draw(c, track: list, offset: listScroll, content: list.height + listMax, hovered: hovered == .listScrollbar,
                            opacity: listScroller.barOpacity)
    }

    static func eta(_ s: Double) -> String { s < 60 ? "\(Int(s.rounded()))s" : "\(Int(s) / 60)m \(Int(s) % 60)s" }

    /// formatDuration (RenderQueueItem): "850ms", "42s", "1m 5s".
    static func duration(ms: Double) -> String {
        if ms < 1000 { return "\(Int(ms))ms" }
        let s = Int((ms / 1000).rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    /// formatTimeAgo: "just now", "5m ago", "3h ago".
    static func timeAgo(_ created: Double, now: Double) -> String {
        let diff = (now - created) * 1000
        if diff < 60_000 { return "just now" }
        if diff < 3_600_000 { return "\(Int(diff / 60_000))m ago" }
        return "\(Int(diff / 3_600_000))h ago"
    }

    /// formatRenderProgress: 0…100 to one decimal, trailing zero dropped ("37.5", "40").
    static func progressText(_ p: Double) -> String {
        let v = ((max(0, min(1, p.isFinite ? p : 0)) * 100) * 10).rounded() / 10
        return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    /// RenderQueueItem: `px-3 py-2.5 border-b` (none on the last), an 80×45 rounded-md bg-panel-input thumbnail
    /// (the poster frame, or a status dot), name + duration, the stage/progress or status lines, then the actions:
    /// Cancel while rendering; else download (complete only) and ×, which asks "Delete?" / "Keep" first.
    func drawJob(_ c: CanvasContext, _ r: CanvasRect, _ j: RenderJobView, last: Bool = false) -> Double {
        let rendering = j.status == .rendering || j.status == .queued
        let statusLine = j.status == .failed || j.status == .cancelled
        let contentH = statusLine ? 56.0 : 45.0
        let h = 20 + contentH + (last ? 0 : 1)
        let row = CanvasRect(x: r.x, y: r.y, width: r.width, height: h)
        if hovered?.jobId == j.id { c.fillRect(row, PanelTheme.panelHover.withAlpha(0.3)) }
        hits.add(row, .job(j.id))
        let top = r.y + 10
        let thumb = CanvasRect(x: r.x + 12, y: top + (contentH - 45) / 2, width: 80, height: 45)
        c.fillRoundedRect(thumb, radius: PanelTheme.radiusMd, PanelTheme.panelInput)
        if j.status == .complete, let img = j.thumbnail {
            c.withState {
                c.clip(.roundedRect(thumb, radius: PanelTheme.radiusMd))
                let s = min(thumb.width / Double(img.width), thumb.height / Double(img.height))   // object-contain
                let iw = Double(img.width) * s, ih = Double(img.height) * s
                c.drawImage(img, in: CanvasRect(x: thumb.midX - iw / 2, y: thumb.midY - ih / 2, width: iw, height: ih))
            }
        } else if j.status != .complete {
            let dot: CanvasColor = rendering ? PanelTheme.accent : (j.status == .failed ? PanelTheme.red400 : PanelTheme.neutral600)
            c.fillRoundedRect(CanvasRect(x: thumb.midX - 4, y: thumb.midY - 4, width: 8, height: 8), radius: 4, dot)
        }
        if j.status == .complete { hits.add(thumb, .thumb(j.id)) }   // the thumbnail opens the render (reveal on desktop)
        // Actions (right, gap-1.5)
        var right = r.maxX - 12
        if rendering {   // Button sm secondary: h-7 px-2.5 text-xs medium, 1px border
            let f = PanelTheme.font(12, .medium), tw = c.measureText("Cancel", font: f).width
            let b = CanvasRect(x: right - tw - 22, y: top + (contentH - 28) / 2, width: tw + 22, height: 28)
            let hov = hovered == .cancel(j.id)
            if hov { c.fillRect(b, PanelTheme.panelHover) }
            c.strokeRect(b.insetBy(0.5), hov ? PanelTheme.white : PanelTheme.neutral200, width: 1)
            PanelDraw.text(c, "Cancel", in: CanvasRect(x: b.x, y: b.y + 6, width: b.width, height: 16), font: f, color: hov ? PanelTheme.white : PanelTheme.neutral300, align: .center)
            hits.add(b, .cancel(j.id)); right = b.x - 6
        } else if confirmingDelete == j.id {
            let f = PanelTheme.font(12, .medium)
            let kw = c.measureText("Keep", font: f).width + 20, dw = c.measureText("Delete?", font: f).width + 20
            let keep = CanvasRect(x: right - kw, y: top + (contentH - 28) / 2, width: kw, height: 28)
            let del = CanvasRect(x: keep.x - 6 - dw, y: keep.y, width: dw, height: 28)
            c.fillRect(del, hovered == .delete(j.id) ? PanelTheme.red600 : PanelTheme.red500)
            PanelDraw.text(c, "Delete?", in: CanvasRect(x: del.x, y: del.y + 6, width: del.width, height: 16), font: f, color: PanelTheme.white, align: .center)
            if hovered == .keep(j.id) { c.fillRect(keep, PanelTheme.panelHover) }
            PanelDraw.text(c, "Keep", in: CanvasRect(x: keep.x, y: keep.y + 6, width: keep.width, height: 16), font: f,
                           color: hovered == .keep(j.id) ? PanelTheme.white : PanelTheme.neutral400, align: .center)
            hits.add(del, .delete(j.id)); hits.add(keep, .keep(j.id)); right = del.x - 6
        } else {
            let complete = j.status == .complete
            let x = CanvasRect(x: right - 24, y: top + (contentH - 24) / 2, width: 24, height: 24)
            let dl = CanvasRect(x: x.x - 6 - 24, y: x.y, width: 24, height: 24)
            PanelIcon.download.draw(c, in: dl.insetBy(6), color: complete ? (hovered == .reveal(j.id) ? PanelTheme.accent : PanelTheme.text5) : PanelTheme.text5.withAlpha(0.3), lineWidth: 2)
            PanelIcon.close.draw(c, in: x.insetBy(6), color: hovered == .confirmDelete(j.id) ? PanelTheme.red400 : PanelTheme.text5)
            if complete { hits.add(dl, .reveal(j.id)) }
            hits.add(x, .confirmDelete(j.id)); right = dl.x - 6
        }
        // Info (flex-1, after the thumbnail's gap-2.5)
        let tx = thumb.maxX + 10, tw = max(0, right - tx - 4)
        let ny = rendering ? top + 2.5 : (statusLine ? top : top + 2.3)
        let nameFont = PanelTheme.font(11, .medium), small = PanelTheme.font(9)
        let durText = j.durationMs.flatMap { $0 > 0 ? Self.duration(ms: $0) : nil }
        let durW = durText.map { c.measureText($0, font: small).width + 6 } ?? 0
        let name = PanelDraw.truncate(c, j.name, font: nameFont, width: max(0, tw - durW))
        let nw = c.measureText(name, font: nameFont).width
        PanelDraw.text(c, name, in: CanvasRect(x: tx, y: ny, width: nw + 1, height: 16.5), font: nameFont, color: PanelTheme.text2)
        if let d = durText { PanelDraw.text(c, d, in: CanvasRect(x: tx + nw + 6, y: ny + 1.5, width: durW, height: 13.5), font: small, color: PanelTheme.text5) }
        if rendering {
            let stage = j.stage.replacingOccurrences(of: #"\s*\(\d+\s+workers?\)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            PanelDraw.text(c, stage.isEmpty ? "Rendering" : stage, in: CanvasRect(x: tx, y: ny + 20.5, width: tw - 40, height: 13.5), font: small, color: PanelTheme.text4)
            PanelDraw.text(c, "\(Self.progressText(j.progress))%", in: CanvasRect(x: tx, y: ny + 20.5, width: tw, height: 13.5), font: PanelTheme.mono(9), color: PanelTheme.accent, align: .right)
            let bar = CanvasRect(x: tx, y: ny + 36, width: tw, height: 4)
            c.fillRoundedRect(bar, radius: 2, PanelTheme.panelBorder)
            c.fillRoundedRect(CanvasRect(x: bar.x, y: bar.y, width: bar.width * max(0, min(1, j.progress)), height: 4), radius: 2, PanelTheme.accent)
        } else {
            var ly = ny + 25.5
            if statusLine {
                let text = j.status == .failed ? (j.error ?? "Failed") : "Cancelled"
                PanelDraw.text(c, text, in: CanvasRect(x: tx, y: ny + 18.5, width: tw, height: 13.5), font: small, color: j.status == .failed ? PanelTheme.red400 : PanelTheme.text4)
                ly = ny + 41
            }
            var meta: [String] = []
            if let t = j.createdAt { meta.append(Self.timeAgo(t, now: now())) }
            if let b = j.sizeBytes { meta.append(formatExportFileSize(b)) }
            let line = meta.isEmpty ? (j.detail ?? "") : meta.joined(separator: " · ")
            PanelDraw.text(c, line, in: CanvasRect(x: tx, y: ly, width: tw, height: 10), font: small, color: PanelTheme.text5)
        }
        if !last { PanelDraw.hline(c, x0: r.x, x1: r.maxX, y: r.y + h - 1, PanelTheme.panelBorder) }
        return h
    }

    // MARK: Input

    func commitField() {
        guard let f = field else { return }
        field = nil
        if f.key == "preset-name" { presetName = f.draft; return }
        // The other side follows the composition's aspect; the width is what is stored (CompositionRenderResolution).
        if let v = Double(f.draft.trimmingCharacters(in: .whitespaces)), v > 0 {
            let w = canvasSize.width, h = canvasSize.height
            let width = f.key == "w" ? v : CompositionRenderResolution.customWidth(forHeight: v, compositionWidth: w, compositionHeight: h)
            settings.customWidth = min(7680, max(2, (width / 2).rounded() * 2))
            settings.customHeight = CompositionRenderResolution.customHeight(forWidth: settings.customWidth, compositionWidth: w, compositionHeight: h)
            onSettingsChanged?(settings)
        }
    }

    public func pointerDown(_ p: CanvasPoint) -> Bool {
        focus.pointerPressed()
        if dropdown.pointerDown(p) { onChange?(); return true }
        if let r = contentPointerDown(p) { return r }
        inspector.commitField()
        if field != nil, hits.hit(p) != .customW, hits.hit(p) != .customH { commitField() }
        guard let hit = hits.hit(p) else { return false }
        func open(_ key: String, _ opts: [PanelDropdown.Option], _ sel: String, _ apply: @escaping (String) -> Void) {
            guard let a = hits.rect(where: { $0 == hit }) else { return }
            dropdown.open(key: key, options: opts, selected: sel, anchor: a, bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)) { [weak self] v in
                guard let self else { return }
                apply(v); self.onSettingsChanged?(self.settings); self.onChange?()
            }
        }
        if handlePresetHit(hit) { onChange?(); return true }
        switch hit {
        case .preset, .presetName, .savePreset, .deletePreset: break
        case .hide: layout.setRightCollapsed(true)
        case .show: layout.setRightCollapsed(false)
        case .panelMenu, .tabOverflow: openMenu(for: hit)
        case .design: layout.setRightTab(.design)
        case .easing: layout.setRightTab(.easing)
        case .renders, .showRenders: layout.setRightTab(.renders)
        case .format: open("format", Self.formats, settings.format) { [weak self] v in self?.settings.format = v }
        case .resolution:
            open("resolution", resolutionOptions(), CompositionRenderResolution(stored: settings.resolution).storedValue) { [weak self] v in
                self?.settings.resolution = v
            }
        case .fps: open("fps", Self.rates, "\(Int(settings.fps))") { [weak self] v in self?.settings.fps = Double(v) ?? 30 }
        case .quality: open("quality", Self.qualities, settings.quality) { [weak self] v in self?.settings.quality = v }
        case .customW: field = PanelTextField(key: "w", value: "\(Int(settings.customWidth))")
        case .customH:
            let h = CompositionRenderResolution.customHeight(forWidth: settings.customWidth, compositionWidth: canvasSize.width,
                                                             compositionHeight: canvasSize.height)
            field = PanelTextField(key: "h", value: "\(Int(h))")
        case .export: onRender?(.start(settings))
        case .cancel(let id): onRender?(.cancel(id))
        case .confirmDelete(let id): confirmingDelete = id
        case .keep: confirmingDelete = nil
        case .delete(let id): confirmingDelete = nil; onRender?(.delete(id))
        case .reveal(let id), .thumb(let id): onRender?(.reveal(id))
        case .retry(let id): onRender?(.retry(id))
        case .hideFinished: onRender?(.hideFinished)
        case .dismissError: actionError = nil
        case .formatInfo, .job, .content, .listScrollbar: break
        }
        onChange?()
        return true
    }

    /// The panel menu: hide the finished renders (when there are any) and hide the panel.
    func openPanelMenu() {
        guard let a = hits.rect(where: { $0 == .panelMenu }) else { return }
        var options: [PanelDropdown.Option] = []
        if jobs.contains(where: { $0.status != .rendering && $0.status != .queued }) { options.append(.init(value: "hideFinished", label: "Hide finished renders")) }
        options.append(.init(value: "keyframe-easing", label: "Keyframe easing"))
        options.append(.init(value: "hide", label: "Hide panel"))
        dropdown.open(key: Self.menuKey, options: options, selected: nil, anchor: a, bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)) { [weak self] v in
            guard let self else { return }
            self.panelMenuPicked(v)
            self.onChange?()
        }
    }

    public func pointerMove(_ p: CanvasPoint) -> Bool {
        if dropdown.isOpen { return dropdown.pointerMove(p) }
        var changed = false
        changed = contentPointerMove(p)
        let h = hits.hit(p)
        if h != hovered { hovered = h; changed = true }
        if let id = confirmingDelete, h?.jobId != id { confirmingDelete = nil; changed = true }   // pointer left the row: Keep
        return changed
    }

    public func pointerUp(_ p: CanvasPoint) {
        if pressedInInspector { inspector.pointerUp(p); pressedInInspector = false; onChange?() }
        if pressedInEasing { easing.pointerUp(p); pressedInEasing = false; onChange?() }
    }

    /// `dy` in points from the host: precise (trackpad) deltas move 1:1, wheel line steps glide (PanelScroller).
    /// `zoom` (the command key held) zooms the Easing tab's graph instead of panning it.
    public func scroll(_ p: CanvasPoint, dy: Double, precise: Bool = false, zoom: Bool = false) -> Bool {
        if dropdown.isOpen { dropdown.scrollBy(dy); return true }
        if shownTab == .design { return inspector.scroll(p, dy: dy, precise: precise) }
        if shownTab == .easing { return easing.scroll(p, dy: dy, zoom: zoom) }
        guard listRect.contains(p) else { return false }
        if listScroller.scroll(by: dy, precise: precise, max: listMax) { onAnimate?() }
        return true
    }

    /// Advances wheel glides, scrollbar fades and the inspector's entrance; true while any still needs frames.
    @discardableResult
    public func tick(_ dt: Double) -> Bool {
        let a = listScroller.tick(dt), b = inspector.tick(dt), e = easing.tick(dt)
        return a || b || e
    }

    public var isEditingText: Bool { field != nil || inspector.isEditingText || easing.isEditingText }

    /// Release reaches the inspector even if a tab or field changed during a held arrow.
    public func keyUp(_ key: EditorKey) { inspector.keyUp(key) }

    /// Keys: the open popover, then a field being typed, then keyboard focus. On the Design tab the header (tabs,
    /// hide, panel menu) comes first in the Tab order and the inspector after it; on the Renders tab one focus covers
    /// the header and the tab's controls.
    public func keyDown(_ k: EditorKey) -> Bool {
        if dropdown.key(k) { onChange?(); return true }
        if field != nil { return fieldKey(k) }
        if shownTab == .design && !layout.effectiveRightCollapsed { return designKey(k) }
        if shownTab == .easing && !layout.effectiveRightCollapsed, !(focus.visible && focus.current.map(Self.isHeader) == true), easing.keyDown(k) {
            onChange?(); return true
        }
        return focusKey(k, forward: { [unowned self] in self.focus.move(self.hits, forward: $0) { self.isFocusable($0) } })
    }

    func fieldKey(_ k: EditorKey) -> Bool {
        guard var f = field else { return false }
        switch f.key(k) {
        case .commit: field = f; commitField()
        case .cancel: field = nil
        case .editing: field = f
        case .none: return false
        }
        onChange?(); return true
    }
}
