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
import MpvfxPanels
import MpvfxTheme

/// The preview pane contains the tools bar, the zoomable composition stage with its overlays (grid, snap guides,
/// hover, marquee, selection,
/// group and crop chrome, zoom readout, fit button, canvas menu) and the transport row.
public final class PlayerView {
    public static let controlsHeight = 40.0            // h-10
    public static let controlsPaddingX = 12.0          // px-3
    /// Padding between the viewport and the composition stage.
    public static let stagePadding = 8.0
    /// Handle dot size and its square hit target (24 pt, at any zoom: the chrome is drawn in view px).
    public static let handleDot = 12.0, handleHit = 24.0
    /// How far beyond a corner's target the rotate zone reaches, and the shortest side that still shows its edge
    /// handle (shorter sides leave the room to the corners and the body).
    public static let rotateZone = 18.0, edgeHandleMinSide = 48.0
    /// The anchor's target radius: its drawn crosshair (16 pt), not a 24 pt square, because it sits in the middle of
    /// the box where a press moves the layer.
    public static let anchorHit = 8.0
    // Chrome colours follow the appearance (ThemeTokens); the stage canvas and the chrome drawn over the
    // picture (guides, handles, zoom readout) stay the same in both modes.
    public static var neutral100: CanvasColor { PanelStyle.neutral50 }
    public static var neutral200: CanvasColor { PanelStyle.neutral200 }
    public static var neutral400: CanvasColor { PanelStyle.neutral400 }
    public static var neutral500: CanvasColor { PanelStyle.neutral500 }
    public static var neutral600: CanvasColor { PanelStyle.neutral600 }
    public static var neutral700: CanvasColor { PanelStyle.neutral700 }
    public static var studioSurface: CanvasColor { CanvasColor(ThemeTokens.timelineSurface) }
    /// PREVIEW_PLAYER_SURFACE_COLOR (themed) / PREVIEW_CANVAS_SURFACE_COLOR (neutral in both modes).
    public static var viewportSurface: CanvasColor { CanvasColor(ThemeTokens.viewportPair.now) }
    public static let canvasSurface = CanvasColor(ThemeTokens.stageCanvas)
    /// Snap-guide colours.
    public static let guideColor = CanvasColor(ThemeTokens.guide.alpha(0.85)), spacingColor = CanvasColor(ThemeTokens.guide.alpha(0.6))
    public static let spacingBackground = CanvasColor(ThemeTokens.guide.alpha(0.15))
    static let zoomHudSeconds = 1.2, zoomSettleSeconds = 0.2, hudFadeSeconds = 0.2, morphSeconds = 0.28

    public var canvasSize = CanvasSize(1920, 1080)
    public var elements: [StageElement] = []
    /// Primary selection (the last one picked); `selectedIds` holds the whole multi-selection.
    public var selection: String? {
        get { selectedIds.last }
        set { selectedIds = newValue.map { [$0] } ?? [] }
    }
    public var selectedIds: [String] = []
    public var hoveredElement: String?
    public var hoveredButton: Button?
    public let playback: PlaybackState
    public var frameSource: FrameSource = PlaceholderFrameSource()
    public var isFullscreen = false
    public var theme = TimelineTheme.default
    /// Device pixels per point of the surface this view draws into. The canvas reports its own (Retina/HiDPI);
    /// a host may raise it further.
    public var backingScale = 1.0
    /// The host draws the volume, speed and shortcuts slots with their popovers (MpvfxPanels) on top.
    public var drawsPopoverSlots = true
    public let toolbar = PreviewToolbar()
    public var zoom = PreviewZoom.fit
    /// Live snap guides of the move in progress (view px).
    public var snapGuides: [SnapEngine.Guide] = []
    public var spacingGuides: [SnapEngine.SpacingGuide] = []
    /// Marquee drag rectangle and the elements it touches (view px).
    public var marquee: CanvasRect?
    public var marqueeCandidates: [String] = []
    public var contextMenu: StageContextMenu?
    /// Seconds clock for animations (zoom readout fade, play/pause morph).
    public var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Called at the end of a draw while an animation still runs; the host schedules another draw.
    public var requestAnimationFrame: (() -> Void)?

    /// Runs at the start of every draw (the controller samples a gesture recording and flushes settled edits here).
    public var beforeDraw: (() -> Void)?
    /// Elements being edited live (the controller's editingIds); the rest are drawn from the document.
    public var liveElementIds: (() -> Set<String>)?
    /// Keeps animation frames coming while it returns true (recording, a pending nudge or zoom save).
    public var keepAnimating: (() -> Bool)?
    /// Pointer trail of the gesture being recorded, in view pixels.
    public var recordingTrail: [CanvasPoint] = []
    /// Sibling stepped over by the last bring-forward / send-backward, and when.
    public var zOrderFlash: (id: String, start: Double)?
    static let zOrderFlashSeconds = 0.6
    /// A library or media asset is being dragged over the stage.
    public var assetDropActive = false
    /// Transient message over the stage.
    public var toast: (message: String, isError: Bool, start: Double)?
    static let toastSeconds = 3.0

    var zoomChangedAt: Double?
    var morph: (from: Double, to: Double, start: Double)?
    var lastPlaying: Bool?
    public var cropActive = false
    /// The transform box: anchors, hovered and dragged part, readout and cursor (PlayerView+TransformBox.swift).
    public var transformChrome = TransformChrome()

    public enum Button: Equatable, CaseIterable { case play, mute, speed, loop, fullscreen, shortcuts }

    public init(playback: PlaybackState) { self.playback = playback }

    // MARK: Geometry

    public var toolbarHeight: Double { isFullscreen ? 0 : PreviewToolbar.height }
    /// The preview viewport between the tools bar and the transport row.
    public func viewportRect(in size: CanvasSize) -> CanvasRect {
        CanvasRect(x: 0, y: toolbarHeight, width: size.width, height: max(0, size.height - Self.controlsHeight - toolbarHeight))
    }
    /// The composition fitted (contain) inside the viewport's inset, before zoom and pan.
    public func fittedRect(in size: CanvasSize) -> CanvasRect {
        let v = viewportRect(in: size), p = Self.stagePadding
        let aw = max(1, v.width - 2 * p), ah = max(1, v.height - 2 * p)
        let s = min(aw / max(canvasSize.width, 1), ah / max(canvasSize.height, 1))
        let w = canvasSize.width * s, h = canvasSize.height * s
        return CanvasRect(x: ((size.width - w) / 2).rounded(), y: (v.y + p + (ah - h) / 2).rounded(), width: w.rounded(), height: h.rounded())
    }
    /// The composition frame on screen: the fitted frame scaled about its centre by the zoom, then panned.
    public func frameRect(in size: CanvasSize) -> CanvasRect {
        let f = fittedRect(in: size)
        guard !zoom.isAtFit else { return f }
        let s = zoom.scale, w = f.width * s, h = f.height * s
        return CanvasRect(x: f.x + f.width / 2 - w / 2 + zoom.panX, y: f.y + f.height / 2 - h / 2 + zoom.panY, width: w, height: h)
    }
    public func scale(in size: CanvasSize) -> Double { frameRect(in: size).width / max(canvasSize.width, 1) }
    public func toView(_ r: CanvasRect, in size: CanvasSize) -> CanvasRect {
        let f = frameRect(in: size), s = scale(in: size)
        return CanvasRect(x: f.x + r.x * s, y: f.y + r.y * s, width: r.width * s, height: r.height * s)
    }

    /// Transport buttons. Right cluster, right to left: shortcuts, fullscreen, loop, speed, volume.
    public func buttonRect(_ b: Button, in size: CanvasSize) -> CanvasRect {
        let y = size.height - Self.controlsHeight
        if b == .play { return CanvasRect(x: (size.width - 32) / 2, y: y + 4, width: 32, height: 32) }   // h-8 w-8
        let order: [Button] = [.shortcuts, .fullscreen, .loop, .speed, .mute]
        var x = size.width - Self.controlsPaddingX
        for o in order {
            let w = o == .speed ? SpeedPopover.triggerSize.width : 28.0
            x -= w
            if o == b { return CanvasRect(x: x, y: y + 6, width: w, height: 28) }
        }
        return CanvasRect(x: 0, y: 0, width: 0, height: 0)
    }

    /// Zoom readout pill and the fit button, in view pixels.
    public func zoomHudRect(in size: CanvasSize, _ c: CanvasContext?) -> CanvasRect {
        let v = viewportRect(in: size)
        let tw = c?.measureText(zoom.label, font: .mono(14)).width ?? Double(zoom.label.count) * 8.4
        let w = tw + 32, h = 14.0 + 16 + 2
        return CanvasRect(x: v.x + (v.width - w) / 2, y: v.y + (v.height - h) / 2, width: w, height: h)
    }
    public func fitButtonRect(in size: CanvasSize, _ c: CanvasContext?) -> CanvasRect? {
        guard !zoom.isAtFit else { return nil }
        let v = viewportRect(in: size)
        let label = "\(Int(zoom.percent.rounded()))%"
        let tw = c?.measureText(label, font: CanvasFont(size: 11, weight: .medium)).width ?? Double(label.count) * 6.6
        let w = 12 + 6 + tw + 16 + 2, h = 11.0 + 8 + 2 + 2
        return CanvasRect(x: v.maxX - 12 - w, y: v.maxY - 12 - h, width: w, height: h)
    }

    public enum HandleCorner: CaseIterable, Equatable { case nw, ne, sw, se }
    public func handleCentre(_ h: HandleCorner, of r: CanvasRect) -> CanvasPoint {
        switch h { case .nw: .init(r.x, r.y); case .ne: .init(r.maxX, r.y); case .sw: .init(r.x, r.maxY); case .se: .init(r.maxX, r.maxY) }
    }

    /// Element mapped to view coordinates (rect and crop scaled; rotation unchanged).
    public func viewElement(_ e: StageElement, in size: CanvasSize) -> StageElement {
        let s = scale(in: size)
        return StageElement(id: e.id, name: e.name, rect: toView(e.rect, in: size), kind: e.kind, rotation: e.rotation,
                            crop: CropInsets(top: e.crop.top * s, right: e.crop.right * s, bottom: e.crop.bottom * s, left: e.crop.left * s),
                            opacity: e.opacity, scale: e.scale, locked: e.locked)
    }

    /// The element as it shows on screen: view coordinates with its uniform scale (transform.scale, live while a
    /// gesture records) applied about the box centre, as the preview paints the picture. Hit testing, handles,
    /// outlines and snapping use this box, so they sit on the picture for scaled clips too.
    public func chromeElement(_ e: StageElement, in size: CanvasSize) -> StageElement {
        var ve = viewElement(e, in: size)
        let k = Self.chromeScale(e)
        guard k != 1 else { return ve }
        let c = ve.centre, w = ve.rect.width * k, h = ve.rect.height * k
        ve.rect = CanvasRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        ve.crop = CropInsets(top: ve.crop.top * k, right: ve.crop.right * k, bottom: ve.crop.bottom * k, left: ve.crop.left * k)
        return ve
    }

    /// Magnitude of the element's uniform scale (1 when unset or degenerate).
    public static func chromeScale(_ e: StageElement) -> Double {
        guard let k = e.scale.map(abs), k.isFinite, k > 1e-6 else { return 1 }
        return k
    }

    /// Axis-aligned bounds of a view element's visible (cropped, rotated) box.
    public static func bounds(_ ve: StageElement) -> CanvasRect {
        let r = ve.visibleRect
        let pts = [CanvasPoint(r.x, r.y), CanvasPoint(r.maxX, r.y), CanvasPoint(r.x, r.maxY), CanvasPoint(r.maxX, r.maxY)]
            .map { rotate($0, about: ve.centre, ve.rotation) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CanvasRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Rotate `p` about `c` by `deg` (clockwise in y-down space).
    public static func rotate(_ p: CanvasPoint, about c: CanvasPoint, _ deg: Double) -> CanvasPoint {
        let r = deg * .pi / 180, dx = p.x - c.x, dy = p.y - c.y
        return CanvasPoint(c.x + dx * cos(r) - dy * sin(r), c.y + dx * sin(r) + dy * cos(r))
    }

    /// Rotate-handle centre: 12px below the visible bottom, 22px chip, in the rotated frame.
    public func rotateHandleCentre(_ ve: StageElement) -> CanvasPoint {
        let v = ve.visibleRect
        return Self.rotate(CanvasPoint(v.x + v.width / 2, v.maxY + 12 + 11), about: ve.centre, ve.rotation)
    }

    /// Union of the selected elements' bounds (group chrome), view px.
    public func groupBounds(in size: CanvasSize) -> CanvasRect? {
        let rs = elements.filter { selectedIds.contains($0.id) }.map { Self.bounds(chromeElement($0, in: size)) }
        guard let first = rs.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.maxX, maxY = first.maxY
        for r in rs.dropFirst() { minX = min(minX, r.x); minY = min(minY, r.y); maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY) }
        return CanvasRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Zoom readout

    /// Records a zoom change so the readout shows and fades (1.2 s after the gesture settles).
    public func zoomChanged() { zoomChangedAt = now() }

    /// Readout opacity now (fades out over 200 ms once 1.4 s have passed since the last change).
    public func zoomHudOpacity() -> Double {
        guard let t = zoomChangedAt else { return 0 }
        let since = now() - t, hold = Self.zoomSettleSeconds + Self.zoomHudSeconds
        if since < hold { return 1 }
        let k = (since - hold) / Self.hudFadeSeconds
        return k >= 1 ? 0 : 1 - k * k   // ease-in
    }

    // MARK: Drawing

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        beforeDraw?()
        c.fillRect(CanvasRect(x: 0, y: 0, width: size.width, height: size.height), theme.shellBackground)
        let viewport = viewportRect(in: size)
        let frame = frameRect(in: size)
        c.withState {
            c.clip(viewport)
            c.fillRect(viewport, Self.viewportSurface)
            c.withState {
                c.clip(Self.pixelAligned(frame, scale: c.deviceScale))   // square, pixel-exact stage edge
                c.fillRect(frame, Self.canvasSurface)
                let context = FrameDrawContext(backingScale: max(backingScale, c.deviceScale), isPlaying: playback.isPlaying,
                                               speed: playback.playbackRate * playback.direction, liveElementIds: liveElementIds?())
                frameSource.draw(c, in: frame, time: playback.currentTime, elements: elements.map { viewElement($0, in: size) },
                                 context: context)
            }
            Self.strokeSquare(c, frame, CanvasColor(ThemeTokens.white.alpha(0.10)), width: 1)   // border-white/10, square
            drawOverlays(c, size: size, frame: frame)
            drawStageFeedback(c, size: size, frame: frame)
            drawZoomChrome(c, size: size)
        }
        if !isFullscreen { toolbar.draw(c, width: size.width, cropAvailable: cropAvailable, cropActive: cropActive) }
        drawControls(c, size: size)
        if let menu = contextMenu { menu.draw(c, bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)) }
        if animating { requestAnimationFrame?() }
    }

    /// Crop is offered for one selected video or image (SnapToolbar "Crop").
    public var cropAvailable: Bool {
        guard selectedIds.count == 1, let e = elements.first(where: { $0.id == selection }) else { return false }
        return e.kind == .video || e.kind == .image
    }

    var animating: Bool {
        let t = now()
        if let m = morph, t - m.start < Self.morphSeconds { return true }
        if let z = zoomChangedAt, t - z < Self.zoomSettleSeconds + Self.zoomHudSeconds + Self.hudFadeSeconds { return true }
        if let f = zOrderFlash, t - f.start < Self.zOrderFlashSeconds { return true }
        if let m = toast, t - m.start < Self.toastSeconds { return true }
        return keepAnimating?() ?? false
    }

    func drawOverlays(_ c: CanvasContext, size: CanvasSize, frame: CanvasRect) {
        // Grid: 1px rgba(255,255,255,0.12) lines at each division.
        if toolbar.gridVisible {
            let edges = SnapEngine.gridEdges(frame: frame, divisions: toolbar.gridDivisions)
            for x in edges.x { c.fillRect(CanvasRect(x: x.rounded(.down), y: frame.y, width: 1, height: frame.height), PanelTheme.stageInk.withAlpha(0.12)) }
            for y in edges.y { c.fillRect(CanvasRect(x: frame.x, y: y.rounded(.down), width: frame.width, height: 1), PanelTheme.stageInk.withAlpha(0.12)) }
        }
        // Selection, hover and marquee chrome stand down while playing or recording.
        guard !playback.isPlaying else { return drawGuides(c, frame: frame) }
        // Hover: border-2 accent/80, square, in the element's rotated frame.
        if let h = hoveredElement, !selectedIds.contains(h), marquee == nil, let e = elements.first(where: { $0.id == h }) {
            let ve = chromeElement(e, in: size)
            rotated(c, ve) { Self.strokeSquare(c, ve.visibleRect, theme.accent.withAlpha(0.8), width: 2) }
        }
        // Selection: one element gets handles; several get member outlines and the group box.
        if selectedIds.count > 1, let gb = groupBounds(in: size) {
            for e in elements where selectedIds.contains(e.id) {
                let b = Self.bounds(chromeElement(e, in: size))
                Self.strokeSquare(c, b, theme.accent.withAlpha(0.7), width: 1)
            }
            Self.strokeSquare(c, gb, theme.accent, width: 2)
        } else if let sel = selection, let e = elements.first(where: { $0.id == sel }) {
            let ve = chromeElement(e, in: size)
            if cropActive { drawCrop(c, ve) } else { drawSelection(c, ve) }
        }
        // Marquee: candidates accent + accent/5 (square); the box accent + accent/10.
        for id in marqueeCandidates {
            guard let e = elements.first(where: { $0.id == id }) else { continue }
            let b = Self.bounds(chromeElement(e, in: size))
            Self.fillSquare(c, b, theme.accent.withAlpha(0.05))
            Self.strokeSquare(c, b, theme.accent, width: 1)
        }
        if let m = marquee {
            Self.fillSquare(c, m, theme.accent.withAlpha(0.10))
            Self.strokeSquare(c, m, theme.accent, width: 1)
        }
        drawGuides(c, frame: frame)
        drawTransformFeedback(c, size: size)
    }

    /// Snap guides: full-frame 1px lines and dashed equal-gap boxes with their size.
    func drawGuides(_ c: CanvasContext, frame: CanvasRect) {
        for g in snapGuides.prefix(6) {
            let r = g.axis == .x ? CanvasRect(x: g.position, y: frame.y, width: 1, height: frame.height)
                                 : CanvasRect(x: frame.x, y: g.position, width: frame.width, height: 1)
            Self.fillSquare(c, r, Self.guideColor)
        }
        for g in spacingGuides.prefix(4) {
            let dash = StrokeStyle(width: 1, dash: [3, 3])
            let box: CanvasRect
            if g.axis == .x {
                box = CanvasRect(x: g.position, y: g.from, width: g.size, height: g.to - g.from)
                var l = CanvasPath(); l.move(to: .init(box.x + 0.5, box.y)); l.line(to: .init(box.x + 0.5, box.maxY))
                var r = CanvasPath(); r.move(to: .init(box.maxX - 0.5, box.y)); r.line(to: .init(box.maxX - 0.5, box.maxY))
                c.stroke(l, Self.spacingColor, dash); c.stroke(r, Self.spacingColor, dash)
            } else {
                box = CanvasRect(x: g.from, y: g.position, width: g.to - g.from, height: g.size)
                var t = CanvasPath(); t.move(to: .init(box.x, box.y + 0.5)); t.line(to: .init(box.maxX, box.y + 0.5))
                var b = CanvasPath(); b.move(to: .init(box.x, box.maxY - 0.5)); b.line(to: .init(box.maxX, box.maxY - 0.5))
                c.stroke(t, Self.spacingColor, dash); c.stroke(b, Self.spacingColor, dash)
            }
            let label = "\(Int(g.size.rounded()))", font = CanvasFont.mono(10)
            let tw = c.measureText(label, font: font).width
            let pill = CanvasRect(x: box.x + (box.width - tw - 6) / 2, y: box.y + (box.height - 14) / 2, width: tw + 6, height: 14)
            c.fillRoundedRect(pill, radius: 2, Self.spacingBackground)
            c.drawText(label, at: .init(pill.x + 3, pill.y + 2), font: font, color: Self.guideColor)
        }
    }

    func rotated(_ c: CanvasContext, _ ve: StageElement, _ body: () -> Void) {
        c.withState {
            c.translate(ve.centre.x, ve.centre.y); c.rotate(ve.rotation * .pi / 180); c.translate(-ve.centre.x, -ve.centre.y)
            body()
        }
    }

    /// Zoom readout (rounded-lg border-white/15 bg-black, 14px mono white/90) and the fit button
    /// (rounded-md border-white/15 bg-black, 11px medium white/80, corner glyph + percentage).
    func drawZoomChrome(_ c: CanvasContext, size: CanvasSize) {
        let a = zoomHudOpacity()
        if a > 0 {
            let r = zoomHudRect(in: size, c)
            c.fillRoundedRect(r, radius: 8, PanelTheme.stageScrim.withAlpha(a))
            c.strokeRoundedRect(r.insetBy(0.5), radius: 7.5, PanelTheme.stageInk.withAlpha(0.15 * a), width: 1)
            c.drawText(zoom.label, at: .init(r.x + 16, r.y + 9), font: .mono(14), color: PanelTheme.stageInk.withAlpha(0.9 * a))
        }
        if let r = fitButtonRect(in: size, c) {
            let hovered = hoveredFit
            c.fillRoundedRect(r, radius: 6, hovered ? CanvasColor(ThemeTokens.neutralPairs[900]!.dark) : PanelTheme.stageScrim)
            c.strokeRoundedRect(r.insetBy(0.5), radius: 5.5, PanelTheme.stageInk.withAlpha(0.15), width: 1)
            let color: CanvasColor = hovered ? PanelTheme.stageInk : PanelTheme.stageInk.withAlpha(0.8)
            PlayerIcons.stroke(c, PlayerIcons.fitCorners, in: CanvasRect(x: r.x + 9, y: r.y + (r.height - 12) / 2, width: 12, height: 12),
                               box: 16, color: color, width: 1.5)
            c.drawText("\(Int(zoom.percent.rounded()))%", at: .init(r.x + 9 + 12 + 6, r.y + (r.height - 11) / 2),
                       font: CanvasFont(size: 11, weight: .medium), color: color)
        }
    }
    public var hoveredFit = false

    /// Crop handles: 1px accent outline on the crop rect, accent edge lines extended 12px, 10px white
    /// square knobs with an accent border at each edge midpoint.
    func drawCrop(_ c: CanvasContext, _ ve: StageElement) {
        let r = ve.visibleRect
        rotated(c, ve) {
            Self.strokeSquare(c, r, theme.accent, width: 1)
            let a = Self.pixelAligned(r, scale: c.deviceScale), px = 1 / max(c.deviceScale, 1)
            for edge in CropEdge.allCases {
                let ext = 12.0
                switch edge {
                case .top, .bottom:
                    let y = edge == .top ? a.y : a.maxY - px
                    c.fillRect(CanvasRect(x: a.x - ext, y: y, width: a.width + 2 * ext, height: px), theme.accent)
                    knob(c, CanvasPoint(r.x + r.width / 2, y + px / 2))
                case .left, .right:
                    let x = edge == .left ? a.x : a.maxX - px
                    c.fillRect(CanvasRect(x: x, y: a.y - ext, width: px, height: a.height + 2 * ext), theme.accent)
                    knob(c, CanvasPoint(x + px / 2, r.y + r.height / 2))
                }
            }
        }
    }
    func knob(_ c: CanvasContext, _ p: CanvasPoint) {
        let k = CanvasRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        c.fillRect(k, PanelTheme.stageInk); c.strokeRect(k.insetBy(0.5), theme.accent, width: 1)
    }

    /// Play/pause morph progress (0 play … 1 pause), tweened over 280 ms with power2.inOut on each toggle.
    public func playMorph() -> Double {
        let playing = playback.isPlaying, target = playing ? 1.0 : 0.0
        let t = now()
        if lastPlaying == nil { lastPlaying = playing; morph = nil; return target }
        if lastPlaying != playing {
            let from = morph.map { m in Self.ease(m, at: t) } ?? (playing ? 0 : 1)
            morph = (from, target, t); lastPlaying = playing
        }
        guard let m = morph else { return target }
        return Self.ease(m, at: t)
    }
    static func ease(_ m: (from: Double, to: Double, start: Double), at t: Double) -> Double {
        let k = max(0, min(1, (t - m.start) / morphSeconds))
        let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
        return m.from + (m.to - m.from) * e
    }

    func drawControls(_ c: CanvasContext, size: CanvasSize) {
        let y = size.height - Self.controlsHeight
        c.fillRect(CanvasRect(x: 0, y: y, width: size.width, height: Self.controlsHeight), theme.shellBackground)
        // Time: font-mono 11px tabular, neutral-400 current, mx-1 neutral-700 "/", neutral-500 duration.
        let font = CanvasFont.mono(11)
        let cur = TimelineRuler.formatTime(playback.currentTime), sep = "/", dur = TimelineRuler.formatTime(playback.duration)
        var x = Self.controlsPaddingX
        let ty = y + (Self.controlsHeight - 11) / 2
        c.drawText(cur, at: .init(x, ty), font: font, color: Self.neutral400); x += c.measureText(cur, font: font).width + 4
        c.drawText(sep, at: .init(x, ty), font: font, color: Self.neutral700); x += c.measureText(sep, font: font).width + 4
        c.drawText(dur, at: .init(x, ty), font: font, color: Self.neutral500)

        // Play / pause: 12px glyph, viewBox "46 21 54 56", fill #FAFAFA (white on hover), morphing on toggle.
        let pr = buttonRect(.play, in: size)
        c.withState {
            c.translate(pr.x + (pr.width - 12) / 2, pr.y + (pr.height - 12) / 2)
            c.scale(12 / 54, 12 / 56); c.translate(-46, -21)
            c.fill(PlayerIcons.playPause(playMorph()), hoveredButton == .play ? PanelTheme.white : PanelTheme.neutral50)
        }

        func iconColor(_ b: Button, active: Bool) -> CanvasColor {
            active ? theme.accent : hoveredButton == b ? Self.neutral200 : Self.neutral500
        }
        func icon(_ b: Button, active: Bool, _ paths: [CanvasPath], width: Double = 2, glyph: Double = 13) {
            let r = buttonRect(b, in: size)
            PlayerIcons.stroke(c, paths, in: CanvasRect(x: r.x + (r.width - glyph) / 2, y: r.y + (r.height - glyph) / 2, width: glyph, height: glyph),
                               box: 24, color: iconColor(b, active: active), width: width)
        }
        icon(.loop, active: playback.loopEnabled, PlayerIcons.loop)
        icon(.fullscreen, active: isFullscreen, PlayerIcons.fullscreen(exit: isFullscreen))
        guard drawsPopoverSlots else { return }
        icon(.mute, active: false, PlayerIcons.volume(silent: playback.audioMuted, level: 1))
        let sr = buttonRect(.speed, in: size)
        let speed = "\(playback.playbackRate == playback.playbackRate.rounded() ? String(Int(playback.playbackRate)) : String(playback.playbackRate))x"
        let sm = c.measureText(speed, font: .mono(11))
        c.drawText(speed, at: .init(sr.x + (sr.width - sm.width) / 2, sr.y + (sr.height - 11) / 2), font: .mono(11), color: iconColor(.speed, active: false))
        // Shortcuts: 11px keyboard, stroke 1.75, neutral-600 (neutral-300 on hover).
        let kr = buttonRect(.shortcuts, in: size)
        let g = CanvasRect(x: kr.x + (kr.width - 11) / 2, y: kr.y + (kr.height - 11) / 2, width: 11, height: 11)
        let kc = hoveredButton == .shortcuts ? PanelStyle.neutral300 : Self.neutral600
        PlayerIcons.stroke(c, PlayerIcons.keyboard, in: g, box: 24, color: kc, width: 1.75)
        PlayerIcons.fill(c, PlayerIcons.keyboardDots.map { CanvasPath.roundedRect(CanvasRect(x: $0.x - 0.875, y: $0.y - 0.875, width: 1.75, height: 1.75), radius: 0.875) },
                         in: g, box: 24, color: kc)
    }

    // MARK: Input

    public func button(at p: CanvasPoint, in size: CanvasSize) -> Button? {
        Button.allCases.first { b in let r = buttonRect(b, in: size); return p.x >= r.x && p.x <= r.maxX && p.y >= r.y && p.y <= r.maxY }
    }
}
