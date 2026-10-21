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
import MpvfxTheme

/// The strip above the tracks: tool modes, editing actions, track
/// height, zoom. Drawn on a CanvasContext and hit-tested here; every action goes through the controller.
public final class TimelineToolbar {
    public enum Item: Hashable, Sendable {
        case select, razor, slip, roll, snap, keyframe, autoKeyframe, split, removeSilence, addBeat
        case trackHeight, trackSmall, trackMedium, trackLarge, zoomFit, zoomOut, zoomSlider, zoomIn, zoomPercent
    }
    /// The TSX keyframe button's three looks (useKeyframeToggle state).
    public enum KeyframeState: Equatable, Sendable { case active, inactive, none }

    public let controller: TimelineController
    /// Height of the strip: py-0.5 + h-7 buttons + the 1px border-b.
    public static let height = 33.0
    static let padX = 8.0, button = 28.0, gap = 2.0, iconSize = 16.0
    static let zoomSliderWidth = 96.0, percentWidth = 88.0
    static let thumb = 10.0

    /// Remove-silence button: shown only when the host wires it (the TSX renders it only with onRemoveSilence).
    public var onRemoveSilence: ((_ clipId: String) -> Void)?
    public var isRemovingSilence = false
    /// Beat analysis loaded for this clip (the analysed music); the add-beat button needs it.
    public var beatMusicClipId: String?
    /// Add a user beat at a composition time (beatEditActions.addBeatAtCompositionTime). Without it the beat
    /// only lands in the view's beat grid.
    public var onAddBeat: ((_ time: Double) -> Void)?
    public var hovered: Item?
    var draggingSlider: Item?

    public init(controller: TimelineController) { self.controller = controller }

    var view: TimelineView { controller.view }

    // MARK: State

    /// The single selected clip (playerStore selectedElementId).
    var selectedClip: TimelineClipModel? {
        guard view.selection.count == 1, let id = view.selection.first else { return nil }
        return controller.clip(id)?.clip
    }
    var selectedLocked: Bool {
        guard view.selection.count == 1, let id = view.selection.first, let row = controller.clip(id)?.row else { return false }
        return view.tracks[row].locked
    }

    public var keyframeState: KeyframeState {
        guard let c = selectedClip, c.kind != .audio, !selectedLocked, let e = controller.editor else { return .none }
        return e.positionKeyframeActive(clipId: c.id, time: controller.playback.currentTime) ? .active : .inactive
    }
    /// Mirrors the S gate: selected clip, splittable, playhead strictly inside it.
    public var canSplit: Bool {
        guard let c = selectedClip, !selectedLocked, c.duration > 0 else { return false }
        let t = controller.playback.currentTime
        return t > c.start && t < c.end
    }
    public var canRemoveSilence: Bool {
        guard !isRemovingSilence, let c = selectedClip, !selectedLocked else { return false }
        return c.kind == .video && c.assetId != nil
    }
    /// canAddBeatAt: analysis loaded and the playhead within the music clip.
    public var canAddBeat: Bool {
        guard let id = beatMusicClipId, let c = controller.clip(id)?.clip else { return false }
        let t = controller.playback.currentTime
        return t >= c.start && t <= c.end
    }
    public var zoomPercent: Double {
        TimelineZoom.percent(controller.zoomMode, manual: controller.manualZoomPercent, fit: controller.fitPixelsPerSecond)
    }

    public var tickReadout: String {
        let seconds = TimelineRuler.majorInterval(duration: view.duration, pps: view.pixelsPerSecond, frameRate: view.frameRate)
        if seconds < 1 { return "\(Int((seconds * view.frameRate).rounded())) f/tick" }
        if seconds >= 60 { return "\(Int(seconds / 60)) min/tick" }
        return "\(Int(seconds)) s/tick"
    }

    public func isEnabled(_ item: Item) -> Bool {
        switch item {
        case .keyframe: keyframeState != .none
        case .split: canSplit
        case .removeSilence: canRemoveSilence
        case .addBeat: canAddBeat
        case .zoomOut: zoomPercent > TimelineZoom.minPercent
        case .zoomFit: abs(zoomPercent - 100) > 0.01 || view.scrollX > 0
        case .zoomIn: zoomPercent < TimelineZoom.maxPercent(fit: controller.fitPixelsPerSecond)
        default: true
        }
    }
    public func isPressed(_ item: Item) -> Bool {
        switch item {
        case .select, .razor, .slip, .roll: controller.tool == Self.tool(for: item)
        case .trackSmall: view.trackHeight == 32
        case .trackMedium: view.trackHeight == 48
        case .trackLarge: view.trackHeight == 72
        case .snap: controller.snapEnabled
        case .autoKeyframe: controller.autoKeyframeEnabled
        default: false
        }
    }

    /// Tooltip text (the TSX Tooltip labels) for the host to show over `hovered`.
    public func tooltip(_ item: Item) -> String {
        switch item {
        case .select, .razor, .slip, .roll: return Self.toolTooltip(Self.tool(for: item))
        case .snap: return controller.snapEnabled ? "Snapping on (N)" : "Snapping off (N)"
        case .keyframe:
            switch keyframeState {
            case .none: return "Select an animated element to add keyframes"
            case .active: return "Remove position keyframe at playhead (K)"
            case .inactive: return "Add position keyframe at playhead (K)"
            }
        case .autoKeyframe:
            return controller.autoKeyframeEnabled
                ? "Auto-keyframe enabled: manual edits can start animation on static properties (click to turn off)"
                : "Auto-keyframe disabled: use a property diamond to start animation; existing native animation remains keyframed"
        case .split:
            return canSplit ? "Split at playhead (S)" : selectedClip != nil && !selectedLocked ? "Move the playhead inside the clip to split" : "Select a clip to split"
        case .removeSilence:
            return isRemovingSilence ? "Removing silence…" : canRemoveSilence ? "Remove silence from selected video" : "Select an editable video clip"
        case .addBeat:
            return beatMusicClipId == nil ? "Add a music track with beat analysis to place beats"
                : canAddBeat ? "Add beat at playhead" : "A beat already exists at the playhead"
        case .trackHeight: return "Track height"
        case .trackSmall: return "Small tracks (32 px)"
        case .trackMedium: return "Medium tracks (48 px)"
        case .trackLarge: return "Large tracks (72 px)"
        case .zoomFit: return "Zoom to fit (⇧Z)"
        case .zoomOut: return "Zoom out (⌘− / Ctrl−)"
        case .zoomSlider: return "Zoom about the playhead (double-click to fit)"
        case .zoomIn: return "Zoom in (⌘+ / Ctrl+)"
        case .zoomPercent: return "Each ruler tick spans \(tickReadout)"
        }
    }

    // MARK: Layout

    /// Hit boxes left to right. Sliders report their whole pointer box (h-6, 24px tall).
    public func layout(width: Double) -> [(item: Item, rect: CanvasRect)] {
        let midY = (Self.height - 1) / 2
        func box(_ x: Double, _ w: Double, _ h: Double = TimelineToolbar.button) -> CanvasRect { CanvasRect(x: x, y: midY - h / 2, width: w, height: h) }
        var out: [(Item, CanvasRect)] = []
        var x = Self.padX
        var left: [Item] = [.select, .razor, .slip, .roll, .snap, .keyframe, .autoKeyframe, .split]
        if onRemoveSilence != nil { left.append(.removeSilence) }
        left.append(.addBeat)
        for (i, item) in left.enumerated() {
            out.append((item, box(x, Self.button)))
            x += Self.button + Self.gap
            if i == 3 { x += 4 + 1 + 4 + Self.gap }     // divider after the tools: mx-1 h-4 w-px
        }
        // Track-height presets | Fit | − | zoom slider | + | time per major tick.
        let labelW = Self.iconSize + 4 + 3 * (Self.button + Self.gap)
        let zoomBoxW = 4 + Self.zoomSliderWidth + 4
        let total = labelW + 8 + Self.gap + 40 + Self.gap + Self.button + Self.gap + zoomBoxW + Self.gap + Self.button + Self.gap + 4 + Self.percentWidth
        var r = max(x, width - Self.padX - total)
        out.append((.trackHeight, box(r, Self.iconSize, 24))); r += Self.iconSize + 4
        for item in [Item.trackSmall, .trackMedium, .trackLarge] { out.append((item, box(r, Self.button))); r += Self.button + Self.gap }
        r += 8 + Self.gap
        out.append((.zoomFit, box(r, 40))); r += 40 + Self.gap
        out.append((.zoomOut, box(r, Self.button))); r += Self.button + Self.gap
        out.append((.zoomSlider, box(r, zoomBoxW, 24))); r += zoomBoxW + Self.gap
        out.append((.zoomIn, box(r, Self.button))); r += Self.button + Self.gap + 4
        out.append((.zoomPercent, box(r, Self.percentWidth, 16)))
        return out
    }

    /// The range input inside a slider's box: track rect and thumb travel.
    func sliderTrack(_ item: Item, in r: CanvasRect) -> CanvasRect {
        CanvasRect(x: r.x + 4, y: r.y, width: Self.zoomSliderWidth, height: r.height)
    }
    /// 0...1 position of a slider's thumb.
    func sliderFraction(_ item: Item) -> Double {
        return TimelineZoom.slider(percent: zoomPercent, fit: controller.fitPixelsPerSecond) / 100
    }

    public func item(atX x: Double, y: Double, width: Double) -> Item? {
        layout(width: width).first { x >= $0.rect.x && x <= $0.rect.maxX && y >= $0.rect.y && y <= $0.rect.maxY }?.item
    }

    // MARK: Pointer

    @discardableResult
    public func pointerDown(x: Double, y: Double, width: Double, clickCount: Int = 1) -> Item? {
        guard let item = item(atX: x, y: y, width: width), isEnabled(item) else { return nil }
        switch item {
        case .zoomSlider where clickCount >= 2: controller.zoomToFit()        // onDoubleClick → fit
        case .zoomSlider:
            draggingSlider = item; dragSlider(x: x, width: width)
        default: activate(item)
        }
        return item
    }

    public func pointerMove(x: Double, y: Double, width: Double) {
        if draggingSlider != nil { dragSlider(x: x, width: width); return }
        let h = item(atX: x, y: y, width: width)
        if h != hovered { hovered = h; controller.needsDisplay?() }
    }

    public func pointerUp() { draggingSlider = nil }

    func dragSlider(x: Double, width: Double) {
        guard let item = draggingSlider, let r = layout(width: width).first(where: { $0.item == item })?.rect else { return }
        let track = sliderTrack(item, in: r)
        let f = max(0, min(1, (x - track.x - Self.thumb / 2) / max(1, track.width - Self.thumb)))
        controller.setZoom(percent: TimelineZoom.percent(slider: f * 100, fit: controller.fitPixelsPerSecond))
    }

    /// Run a button (also used for keyboard / menu equivalents).
    public func activate(_ item: Item) {
        guard isEnabled(item) else { return }
        switch item {
        case .select, .razor, .slip, .roll: controller.tool = Self.tool(for: item)
        case .snap: controller.snapEnabled.toggle()
        case .keyframe: controller.togglePositionKeyframeOnSelection()
        case .autoKeyframe: controller.autoKeyframeEnabled.toggle()
        case .split: controller.splitSelectedAtPlayhead()
        case .removeSilence: if let id = selectedClip?.id { onRemoveSilence?(id) }
        case .addBeat:
            let t = controller.playback.currentTime
            if let onAddBeat { onAddBeat(t) } else { controller.addBeat(at: t) }
        case .trackSmall: controller.setTrackHeight(32)
        case .trackMedium: controller.setTrackHeight(48)
        case .trackLarge: controller.setTrackHeight(72)
        case .zoomFit: controller.zoomToFit()
        case .zoomOut: controller.zoom(in: false)
        case .zoomIn: controller.zoom(in: true)
        case .trackHeight, .zoomSlider, .zoomPercent: break
        }
        controller.needsDisplay?()
    }

    // MARK: Draw

    typealias T = ThemeTokens

    public func draw(_ c: CanvasContext, width: Double) {
        // border-b border-neutral-800/60 under a transparent strip on the shell background.
        c.fillRect(CanvasRect(x: 0, y: 0, width: width, height: Self.height), view.theme.shellBackground)
        c.fillRect(CanvasRect(x: 0, y: Self.height - 1, width: width, height: 1), CanvasColor(T.neutral800.alpha(0.6)))
        let items = layout(width: width)
        if let lastTool = items.first(where: { $0.item == .roll })?.rect {
            c.fillRect(CanvasRect(x: lastTool.maxX + Self.gap + 4, y: lastTool.centerY - 8, width: 1, height: 16), CanvasColor(T.neutral800))
        }
        if let r = items.first(where: { $0.item == .zoomFit })?.rect {
            c.fillRect(CanvasRect(x: r.x - 8, y: 8, width: 1, height: 16), view.theme.gutterBorder)
        }
        for (item, r) in items { drawItem(c, item, r) }
    }

    /// flatIdle / flatActive / flatDisabled and the per-button colour rules from the TSX.
    func colors(_ item: Item) -> (fg: ThemeColor, bg: ThemeColor?) {
        let hover = hovered == item
        if !isEnabled(item) { return (T.neutral700, nil) }
        switch item {
        case .keyframe:
            let fg: ThemeColor = switch keyframeState { case .active: T.studioAccent; case .inactive: hover ? T.studioAccent : T.neutral400; case .none: hover ? T.neutral400 : T.neutral600 }
            return (fg, hover ? T.white.alpha(0.06) : nil)
        case .autoKeyframe:
            let on = controller.autoKeyframeEnabled
            return (on ? (hover ? T.red300 : T.red400) : (hover ? T.neutral400 : T.neutral600), hover ? T.white.alpha(0.06) : nil)
        case .addBeat:
            return (hover ? T.green500 : T.neutral400, hover ? T.white.alpha(0.06) : nil)
        default:
            if isPressed(item) { return (T.neutral100, T.white.alpha(0.08)) }
            return (hover ? T.neutral200 : T.neutral400, hover ? T.white.alpha(0.06) : nil)
        }
    }

    func drawItem(_ c: CanvasContext, _ item: Item, _ r: CanvasRect) {
        let icon = CanvasRect(x: r.centerX - 8, y: r.centerY - 8, width: 16, height: 16)
        switch item {
        case .trackHeight, .zoomSlider:
            if item == .trackHeight {
                let ib = CanvasRect(x: r.x, y: r.centerY - 8, width: 16, height: 16)
                c.stroke(TimelineIconPath.parse("M3 2h10M3 14h10M8 4v8M6 6l2-2 2 2M6 10l2 2 2-2", viewBox: 16, into: ib),
                         CanvasColor(T.neutral400), StrokeStyle(width: 1.2))
            }
            if item == .trackHeight { return }
            drawSlider(c, track: sliderTrack(item, in: r), fraction: sliderFraction(item))
            return
        case .zoomPercent:
            let f = CanvasFont.mono(11), s = tickReadout
            let w = c.measureText(s, font: f).width
            c.drawText(s, at: .init(r.maxX - w, r.centerY - 6.5), font: f, color: view.theme.textSecondary)
            return
        default: break
        }
        let (fg, bg) = colors(item)
        if let bg { c.fillRoundedRect(r, radius: 6, CanvasColor(bg)) }
        let col = CanvasColor(fg)
        switch item {
        case .trackSmall, .trackMedium, .trackLarge, .zoomFit:
            let label = item == .trackSmall ? "S" : item == .trackMedium ? "M" : item == .trackLarge ? "L" : "Fit"
            let font = CanvasFont(size: 11, weight: .medium)
            c.drawText(label, at: .init(r.centerX - c.measureText(label, font: font).width / 2, r.centerY - 5.5), font: font, color: view.theme.textPrimary)
        case .select, .razor, .slip, .roll: Self.drawToolGlyph(c, item, icon, col)
        case .snap: Self.drawMagnet(c, icon, col)
        case .keyframe:
            if keyframeState == .active { c.fill(TimelineIconPath.parse("M5 0.5L9.5 5L5 9.5L0.5 5Z", viewBox: 10, into: icon), col) }
            else { c.stroke(TimelineIconPath.parse("M5 1.2L8.8 5L5 8.8L1.2 5Z", viewBox: 10, into: icon), col, StrokeStyle(width: 1.2 * 1.6)) }
        case .autoKeyframe:
            c.stroke(TimelineIconPath.parse("M5 0.7L9.3 5L5 9.3L0.7 5Z", viewBox: 10, into: icon), col, StrokeStyle(width: 1.6))
            let dot = TimelineIconPath.circle(.init(icon.centerX, icon.centerY), r: 1.8 * 1.6)
            if controller.autoKeyframeEnabled { c.fill(dot, col) }
            c.stroke(dot, col, StrokeStyle(width: 1.6))
        case .split:
            c.stroke(TimelineIconPath.parse("M5 3 L7 3 L7 13 L5 13", viewBox: 16, into: icon), col, StrokeStyle(width: 1.6))
            c.stroke(TimelineIconPath.parse("M11 3 L9 3 L9 13 L11 13", viewBox: 16, into: icon), col, StrokeStyle(width: 1.6))
        case .removeSilence: Self.drawWaveformGlyph(c, icon, isRemovingSilence ? col.withAlpha(col.a * 0.6) : col)
        case .addBeat:
            c.stroke(TimelineIconPath.parse("M21 10C21 12.2091 16.9706 14 12 14M21 10C21 7.79086 16.9706 6 12 6C7.02944 6 3 7.79086 3 10M21 10V16C21 18.2091 16.9706 20 12 20M12 14C7.02944 14 3 12.2091 3 10M12 14V20M3 10V16C3 18.2091 7.02944 20 12 20M7 19.3264V13.3264M17 19.3264V13.3264M12 10L20 4", viewBox: 24, into: icon),
                     col, StrokeStyle(width: 2 * 16 / 24))
        case .zoomOut, .zoomIn: Self.drawMagnifier(c, icon, col, plus: item == .zoomIn)
        default: break
        }
    }

    /// Range input: 2px neutral-700 rounded track, 10px white thumb with a 2px neutral-950 ring.
    func drawSlider(_ c: CanvasContext, track r: CanvasRect, fraction: Double) {
        c.fillRoundedRect(CanvasRect(x: r.x, y: r.centerY - 1, width: r.width, height: 2), radius: 1, CanvasColor(T.neutral700))
        let cx = r.x + Self.thumb / 2 + max(0, min(1, fraction)) * (r.width - Self.thumb)
        c.fill(TimelineIconPath.circle(.init(cx, r.centerY), r: Self.thumb / 2), CanvasColor(T.neutral950))
        c.fill(TimelineIconPath.circle(.init(cx, r.centerY), r: Self.thumb / 2 - 2), CanvasColor(T.white))
    }

    // Phosphor glyphs (Scissors, Magnet bold, Waveform bold, MagnifyingGlass±) on their 256 grid, scaled to 16.
    static func drawScissors(_ c: CanvasContext, _ b: CanvasRect, _ col: CanvasColor) {
        let s = b.width / 256, st = StrokeStyle(width: 16 * s)
        func p(_ x: Double, _ y: Double) -> CanvasPoint { .init(b.x + x * s, b.y + y * s) }
        c.stroke(TimelineIconPath.circle(p(64, 76), r: 28 * s), col, st)
        c.stroke(TimelineIconPath.circle(p(64, 180), r: 28 * s), col, st)
        var l = CanvasPath()
        l.move(to: p(87, 92)); l.line(to: p(232, 192))
        l.move(to: p(87, 164)); l.line(to: p(232, 64))
        c.stroke(l, col, st)
    }

    static func drawMagnet(_ c: CanvasContext, _ b: CanvasRect, _ col: CanvasColor) {
        let s = b.width / 256, st = StrokeStyle(width: 24 * s)
        func p(_ x: Double, _ y: Double) -> CanvasPoint { .init(b.x + x * s, b.y + y * s) }
        var u = CanvasPath()
        u.move(to: p(48, 40)); u.line(to: p(48, 128))
        u.curve(to: p(208, 128), c1: p(48, 236), c2: p(208, 236))
        u.line(to: p(208, 40))
        u.move(to: p(48, 88)); u.line(to: p(104, 88))
        u.move(to: p(152, 88)); u.line(to: p(208, 88))
        u.move(to: p(104, 40)); u.line(to: p(104, 128))
        u.curve(to: p(152, 128), c1: p(104, 160), c2: p(152, 160))
        u.line(to: p(152, 40))
        u.move(to: p(48, 40)); u.line(to: p(104, 40))
        u.move(to: p(152, 40)); u.line(to: p(208, 40))
        c.stroke(u, col, st)
    }

    static func drawWaveformGlyph(_ c: CanvasContext, _ b: CanvasRect, _ col: CanvasColor) {
        let s = b.width / 256, st = StrokeStyle(width: 24 * s)
        var p = CanvasPath()
        for (x, half) in [(56.0, 24.0), (96.0, 64.0), (136.0, 96.0), (176.0, 56.0), (216.0, 24.0)] {
            p.move(to: .init(b.x + x * s, b.y + (128 - half) * s)); p.line(to: .init(b.x + x * s, b.y + (128 + half) * s))
        }
        p.move(to: .init(b.x + 16 * s, b.y + 128 * s)); p.line(to: .init(b.x + 24 * s, b.y + 128 * s))
        c.stroke(p, col, st)
    }

    static func drawMagnifier(_ c: CanvasContext, _ b: CanvasRect, _ col: CanvasColor, plus: Bool) {
        let s = b.width / 256, st = StrokeStyle(width: 16 * s)
        func p(_ x: Double, _ y: Double) -> CanvasPoint { .init(b.x + x * s, b.y + y * s) }
        c.stroke(TimelineIconPath.circle(p(116, 116), r: 80 * s), col, st)
        var l = CanvasPath()
        l.move(to: p(172.6, 172.6)); l.line(to: p(224, 224))
        l.move(to: p(84, 116)); l.line(to: p(148, 116))
        if plus { l.move(to: p(116, 84)); l.line(to: p(116, 148)) }
        c.stroke(l, col, st)
    }
}
