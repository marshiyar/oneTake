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
import MpvfxTheme

/// The timeline card's content: the toolbar strip on top and the
/// tracks below it. Hosts hand the whole region one canvas and forward its events here in region
/// coordinates; the toolbar takes the top `TimelineToolbar.height` pixels and the controller gets the rest
/// shifted up, so the controller and view keep their own coordinate space.
public final class TimelineRegion {
    public let controller: TimelineController
    public let toolbar: TimelineToolbar
    public let preferences: TimelineUIPreferencesStore?
    public var needsDisplay: (() -> Void)? {
        get { controller.needsDisplay }
        set { controller.needsDisplay = newValue }
    }
    /// The pointer went down on the toolbar, so moves/up stay there until release.
    var toolbarCapture = false
    public private(set) var size = CanvasSize(0, 0)
    /// Filmstrips and waveforms for the clips (asked for before each paint).
    public var media: TimelineMediaFeeder?
    var top: Double { TimelineToolbar.height }
    /// Status-line text for what is under the pointer: the track header control's action (nil elsewhere).
    public var hint: String? { controller.headerHint }

    public init(controller: TimelineController, preferences: TimelineUIPreferencesStore? = nil) {
        self.controller = controller
        self.toolbar = TimelineToolbar(controller: controller)
        self.preferences = preferences
        guard let store = preferences else { return }
        let p = store.load()
        if let h = p.timelineTrackHeight { controller.view.trackHeight = h }
        if let snap = p.timelineSnapEnabled { controller.snapEnabled = snap }
        if let mode = p.thumbnailMode { controller.view.thumbnailsEnabled = mode != "hidden" }
        if let mode = p.timelineZoomMode { controller.restoreZoom(mode: mode, manualPercent: p.timelineManualZoomPercent ?? 100) }
        // Each change writes its own key (writeStudioUiPreferences patch).
        controller.onTrackHeightChange = { [weak store] h in
            guard let store else { return }
            var p = store.load(); p.timelineTrackHeight = h; store.save(p)
        }
        controller.onZoomChange = { [weak store] mode, pct in
            guard let store else { return }
            var p = store.load(); p.timelineZoomMode = mode; p.timelineManualZoomPercent = pct; store.save(p)
        }
        controller.onThumbnailModeChange = { [weak store] on in
            guard let store else { return }
            var p = store.load(); p.thumbnailMode = on ? "adaptive" : "hidden"; store.save(p)
        }
        controller.onSnapChange = { [weak store] on in
            guard let store else { return }
            var p = store.load(); p.timelineSnapEnabled = on; store.save(p)
        }
    }

    // MARK: Geometry

    public func resized(_ size: CanvasSize) {
        self.size = size
        controller.viewport = CanvasSize(size.width, max(0, size.height - top))
    }

    // MARK: Draw

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        if size != self.size { resized(size) }
        media?.update()
        toolbar.draw(c, width: size.width)
        c.withState {
            c.clip(CanvasRect(x: 0, y: top, width: size.width, height: max(0, size.height - top)))
            c.translate(0, top)
            controller.view.draw(c, size: CanvasSize(size.width, max(0, size.height - top)))
        }
        drawTooltip(c, size: size)
    }

    /// The TSX Tooltip (neutral-900 bubble, neutral-200 11px text) under the hovered toolbar button.
    func drawTooltip(_ c: CanvasContext, size: CanvasSize) {
        guard let item = toolbar.hovered, toolbar.draggingSlider == nil,
              let r = toolbar.layout(width: size.width).first(where: { $0.item == item })?.rect else { return }
        let text = toolbar.tooltip(item), f = CanvasFont(family: TimelineView.uiFontFamily, size: 11)
        let w = c.measureText(text, font: f).width + 16, h = 22.0
        let x = max(4, min(size.width - w - 4, r.centerX - w / 2)), y = r.maxY + 6
        c.fillRoundedRect(CanvasRect(x: x, y: y, width: w, height: h), radius: 4, CanvasColor(ThemeTokens.neutral900))
        c.strokeRoundedRect(CanvasRect(x: x + 0.5, y: y + 0.5, width: w - 1, height: h - 1), radius: 4, CanvasColor(ThemeTokens.neutral700), width: 1)
        c.drawText(text, at: .init(x + 8, y + 5), font: f, color: CanvasColor(ThemeTokens.neutral200))
    }

    // MARK: Input (region coordinates)

    /// Hosts that do not report click counts: a second press on the same toolbar item within this window is a double-click.
    public static let doubleClickInterval = 0.4
    var lastToolbarPress: (item: TimelineToolbar.Item, at: Double)?
    public var now: () -> Double = { Date().timeIntervalSinceReferenceDate }

    public func pointerDown(x: Double, y: Double, shift: Bool = false, alt: Bool = false, clickCount: Int = 1) {
        if y < top {
            toolbarCapture = true
            var clicks = clickCount
            let item = toolbar.item(atX: x, y: y, width: size.width), t = now()
            if clicks == 1, let item, let last = lastToolbarPress, last.item == item, t - last.at <= Self.doubleClickInterval { clicks = 2 }
            lastToolbarPress = item.map { ($0, t) }
            toolbar.pointerDown(x: x, y: y, width: size.width, clickCount: clicks)
            controller.needsDisplay?()
            return
        }
        controller.pointerDown(x: x, y: y - top, shift: shift, alt: alt)
    }

    public func pointerMove(x: Double, y: Double) {
        if toolbarCapture || (y < top && controller.gesture == nil) {
            if controller.view.hoveredHeader != nil { controller.view.hoveredHeader = nil; controller.needsDisplay?() }
            toolbar.pointerMove(x: x, y: y, width: size.width)
            return
        }
        if toolbar.hovered != nil { toolbar.hovered = nil; controller.needsDisplay?() }
        controller.pointerMove(x: x, y: y - top)
    }

    public func pointerUp(x: Double, y: Double) {
        if toolbarCapture { toolbarCapture = false; toolbar.pointerUp(); controller.needsDisplay?(); return }
        controller.pointerUp(x: x, y: y - top)
    }

    public func secondaryClick(x: Double, y: Double) {
        guard y >= top else { return }
        controller.secondaryClick(x: x, y: y - top)
    }

    public func scroll(dx: Double, dy: Double, x: Double, y: Double = .infinity, ctrl: Bool, shift: Bool) {
        controller.scroll(dx: dx, dy: dy, x: x, ctrl: ctrl, shift: shift)
    }

    @discardableResult public func keyDown(_ k: EditorKey) -> Bool { controller.keyDown(k) }
}
