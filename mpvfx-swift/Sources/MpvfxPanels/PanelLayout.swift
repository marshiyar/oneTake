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

/// fitPanels: one place decides who yields when the window narrows. The preview gets its
/// floor first, panels shrink toward their minimums, then collapse to rails.
public enum PanelFit {
    public static let minPreviewWidth = 360.0, minPreviewHeight = 200.0
    public static let minLeft = 200.0, minRight = 280.0
    /// Rail footprint: the w-10 rail plus its 1px seam.
    public static let railWidth = 41.0
    public static let minTimelineHeight = 100.0
    /// The two 1px seams between the three top-row columns.
    public static let seamsWidth = 2.0
    public static let maxRatio = 0.4
    public static let railLeftBelow = 860.0, railRightBelow = 700.0

    public struct Widths: Equatable, Codable, Sendable { public var left, right: Double
        public init(left: Double, right: Double) { self.left = left; self.right = right } }
    public struct Sides: Equatable, Sendable { public var left, right: Bool
        public init(left: Bool = false, right: Bool = false) { self.left = left; self.right = right } }
    public struct Fitted: Equatable, Sendable {
        public var left, right, preview: Double
        public var autoCollapseLeft, autoCollapseRight: Bool
    }

    public static func railsEngaged(_ viewportWidth: Double) -> Bool { viewportWidth < railLeftBelow }

    public static func defaults(_ viewportWidth: Double) -> Widths {
        Widths(left: max(minLeft, min(384, (viewportWidth * 0.257).rounded())),
               right: max(minRight, min(424, (viewportWidth * 0.284).rounded())))
    }

    public static func fit(_ viewportWidth: Double, _ preferred: Widths, reopened: Sides = Sides()) -> Fitted {
        let vw = viewportWidth.isFinite ? max(0, viewportWidth) : 0
        guard vw > 0 else { return Fitted(left: preferred.left, right: preferred.right, preview: 0, autoCollapseLeft: false, autoCollapseRight: false) }
        let acl = vw < railLeftBelow && !reopened.left
        let acr = vw < railRightBelow && !reopened.right
        let cap = (vw * maxRatio).rounded(.down)
        let leftFloor = acl ? railWidth : minLeft
        let rightFloor = acr ? 0 : minRight
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }
        var left = acl ? railWidth : clamp(preferred.left, minLeft, max(minLeft, cap))
        var right = acr ? 0 : clamp(preferred.right, minRight, max(minRight, cap))
        let budget = vw - minPreviewWidth - seamsWidth
        if left + right > budget { right = max(rightFloor, budget - left) }
        if left + right > budget { left = max(leftFloor, budget - right) }
        return Fitted(left: left, right: right, preview: max(0, vw - left - right - seamsWidth), autoCollapseLeft: acl, autoCollapseRight: acr)
    }

    public static func fitTimelineHeight(_ containerHeight: Double, _ preferred: Double) -> Double {
        let h = containerHeight.isFinite ? containerHeight : 0
        let wanted = preferred.isFinite ? preferred : minTimelineHeight
        if h <= 0 { return max(minTimelineHeight, wanted) }
        return max(minTimelineHeight, min(max(minTimelineHeight, h - minPreviewHeight), wanted))
    }
}

/// `easing` is the Keyframe Easing panel, a tab until a docking model hosts it (KeyframeEasingPanel.dock).
public enum RightPanelTab: String, Codable, Sendable { case design, easing, renders }
public enum LeftSidebarTab: String, Codable, Sendable, CaseIterable { case assets, compositions, blocks }

/// The UI preferences and the sidebar tab key. Stored as JSON in the app's data directory.
public struct PanelPreferences: Codable, Equatable, Sendable {
    public var leftWidth: Double?
    public var rightWidth: Double?
    public var leftCollapsed: Bool?
    public var rightCollapsed: Bool?
    public var rightPanelTab: RightPanelTab?
    public var sidebarTab: LeftSidebarTab?
    /// Media bin view choices; defaults are omitted. These do not edit the project or its undo history.
    public var mediaFilter: MediaFilter?
    public var openInspectorGroup: String?
    /// The Design tab's order of its detachable groups (`DesignGroups` panel ids).
    public var designGroupOrder: [String]?
    /// Timeline section height (NLEContext / studioUiPreferences `timelineHeight`).
    public var timelineHeight: Double?
    /// What the Grade scopes read (`clip` | `program`); nothing saved is `clip`.
    public var scopeSource: ColorScopes.Source?
    public init() {}
}

public protocol PanelPreferencesStore: AnyObject {
    func load() -> PanelPreferences
    func save(_ p: PanelPreferences)
}

/// In-memory store (tests, and when no data directory is known).
public final class MemoryPanelPreferencesStore: PanelPreferencesStore {
    public var value: PanelPreferences
    public init(_ value: PanelPreferences = PanelPreferences()) { self.value = value }
    public func load() -> PanelPreferences { value }
    public func save(_ p: PanelPreferences) { value = p }
}

/// `<userData>/panel-layout.json`. Unreadable or malformed files fall back to defaults (like safeLocalStorage).
public final class FilePanelPreferencesStore: PanelPreferencesStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> PanelPreferences {
        guard let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(PanelPreferences.self, from: d) else { return PanelPreferences() }
        return p
    }
    public func save(_ p: PanelPreferences) {
        guard let d = try? JSONEncoder().encode(p) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

/// Panel layout: user intent (preferred widths, collapse) vs what the window allows.
public final class PanelLayoutState {
    public enum Side: Sendable { case left, right }
    public let store: PanelPreferencesStore
    public private(set) var prefs: PanelPreferences
    public private(set) var preferred: PanelFit.Widths
    public var viewportWidth: Double = 1496 { didSet { if !PanelFit.railsEngaged(viewportWidth) { reopened = PanelFit.Sides() } } }
    public private(set) var reopened = PanelFit.Sides()
    public private(set) var leftCollapsed: Bool
    public private(set) var rightCollapsed: Bool
    public private(set) var rightPanelTab: RightPanelTab
    struct Drag { var side: Side; var startX: Double; var startW: Double }
    private(set) var drag: Drag?

    public init(store: PanelPreferencesStore, viewportWidth: Double = 1496) {
        self.store = store
        let p = store.load()
        prefs = p
        self.viewportWidth = viewportWidth
        let d = PanelFit.defaults(viewportWidth)
        preferred = PanelFit.Widths(left: p.leftWidth ?? d.left, right: p.rightWidth ?? d.right)
        leftCollapsed = p.leftCollapsed ?? false
        rightCollapsed = p.rightCollapsed ?? false
        rightPanelTab = p.rightPanelTab ?? .design
    }

    /// What a docked side panel asks the dock for: its hide button and menu item close it, a reveal (a new text
    /// layer, Edit Easing…) opens and focuses it.
    public enum DockedRequest: Equatable, Sendable { case hide(Side), show(Side), showRightTab(RightPanelTab) }
    /// Set by a host that lays the panels out in the dock: hiding and showing go to it, and nothing collapses to a
    /// rail (the dock closes and reopens panels instead).
    public var docked: ((DockedRequest) -> Void)?

    public var fitted: PanelFit.Fitted { PanelFit.fit(viewportWidth, preferred, reopened: reopened) }
    public var effectiveLeftCollapsed: Bool { docked == nil && (leftCollapsed || fitted.autoCollapseLeft) }
    public var effectiveRightCollapsed: Bool { docked == nil && (rightCollapsed || fitted.autoCollapseRight) }
    public var isResizing: Bool { drag != nil }
    public var resizingSide: Side? { drag?.side }

    private func persist(_ edit: (inout PanelPreferences) -> Void) { edit(&prefs); store.save(prefs) }
    public func update(_ edit: (inout PanelPreferences) -> Void) { persist(edit) }

    /// Durable: what the window will actually allow, never a raw pointer delta.
    public func commitWidth(_ side: Side, _ width: Double) {
        var cand = preferred
        if side == .left { cand.left = max(0, width.rounded()) } else { cand.right = max(0, width.rounded()) }
        let fitted = PanelFit.fit(viewportWidth, cand)
        let settled = side == .left ? fitted.left : fitted.right
        if side == .left { preferred.left = settled; persist { $0.leftWidth = settled } }
        else { preferred.right = settled; persist { $0.rightWidth = settled } }
    }

    /// Keyboard nudge (ArrowLeft/Right ±16; the right panel is right-anchored so the caller flips the sign).
    public func adjustWidth(_ side: Side, _ delta: Double) {
        commitWidth(side, (side == .left ? preferred.left : preferred.right) + delta)
    }

    /// Toggle acts on what the user can see, not stored intent.
    public func toggleLeft() {
        if let docked { docked(.hide(.left)); return }
        let next = !effectiveLeftCollapsed
        leftCollapsed = next
        persist { $0.leftCollapsed = next }
        if !next { reopened.left = true }
    }

    public func setRightCollapsed(_ collapsed: Bool) {
        if let docked { docked(collapsed ? .hide(.right) : .show(.right)); return }
        rightCollapsed = collapsed
        persist { $0.rightCollapsed = collapsed }
        if !collapsed { reopened.right = true }
    }

    public func setRightTab(_ tab: RightPanelTab) {
        docked?(.showRightTab(tab))
        guard tab != rightPanelTab else { return }
        rightPanelTab = tab
        persist { $0.rightPanelTab = tab }
    }

    public func beginResize(_ side: Side, x: Double) {
        let f = fitted
        drag = Drag(side: side, startX: x, startW: side == .left ? f.left : f.right)
    }
    /// Transient: moves the panel without touching the stored preference.
    public func moveResize(x: Double) {
        guard let d = drag else { return }
        let delta = x - d.startX
        let w = max(0, (d.startW + (d.side == .left ? delta : -delta)).rounded())
        if d.side == .left { preferred.left = w } else { preferred.right = w }
    }
    public func endResize() {
        guard let d = drag else { return }
        drag = nil
        commitWidth(d.side, d.side == .left ? preferred.left : preferred.right)
    }
}

/// The top row's regions for one viewport size: `[left | seam | preview | seam | right]`.
public struct ShellRegions: Equatable, Sendable {
    public var left: CanvasRect
    public var leftSeam: CanvasRect?
    public var preview: CanvasRect
    public var rightSeam: CanvasRect?
    public var right: CanvasRect
    public var leftRail: Bool
    public var rightRail: Bool

    public static func compute(size: CanvasSize, layout: PanelLayoutState) -> ShellRegions {
        layout.viewportWidth = size.width
        let f = layout.fitted
        let h = size.height, seam = PanelTheme.seamWidth
        let leftRail = layout.effectiveLeftCollapsed
        let rightRail = layout.effectiveRightCollapsed
        let lw = leftRail ? PanelTheme.railBox : f.left
        let rw = rightRail ? PanelTheme.railBox : f.right
        let left = CanvasRect(x: 0, y: 0, width: lw, height: h)
        let preview = CanvasRect(x: lw + seam, y: 0, width: max(0, size.width - lw - rw - 2 * seam), height: h)
        let right = CanvasRect(x: preview.maxX + seam, y: 0, width: max(0, size.width - preview.maxX - seam), height: h)
        // A rail's seam is drawn like any other but does not resize, so only an open panel's seam is a handle.
        let leftSeam = leftRail ? nil : CanvasRect(x: left.maxX, y: 0, width: seam, height: h)
        let rightSeam = rightRail ? nil : CanvasRect(x: preview.maxX, y: 0, width: seam, height: h)
        return ShellRegions(left: left, leftSeam: leftSeam, preview: preview, rightSeam: rightSeam, right: right, leftRail: leftRail, rightRail: rightRail)
    }

    /// Seam pointer zones, centred on the seam.
    public var leftSeamHit: CanvasRect? { leftSeam.map(Self.hitZone) }
    public var rightSeamHit: CanvasRect? { rightSeam.map(Self.hitZone) }
    static func hitZone(_ seam: CanvasRect) -> CanvasRect {
        CanvasRect(x: seam.x - (PanelTheme.seamHitWidth - seam.width) / 2, y: seam.y, width: PanelTheme.seamHitWidth, height: seam.height)
    }
}
