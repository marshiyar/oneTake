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
import MpvfxScopes

/// The Grade group's Scopes row. Closed: "Scopes" / "Off" over a hairline. Open: the status and a refresh button;
/// a chip per scope (several can be on at once, up to four); the scale, target, zoom and gain controls; and the
/// shown scopes laid out by `ScopeLayout`. Frames are analysed off the draw thread by `scopeWorker`.
extension InspectorPanel {
    /// Longest side of the frame the host is asked for: dense enough that clipping and fine detail survive
    /// (`docs/SCOPES.md`), small enough that grading it for every playback frame stays cheap.
    public static let scopeFrameSide = 960
    static let scopeHead = 28.0, scopeChips = 22.0, scopeOptions = 22.0

    /// Pointer parts of `.custom("grade:scopes", part)`.
    enum ScopePart {
        static let toggle = 0, refresh = 1, kind = 2, percent = 10, code10 = 11, target75 = 12, target100 = 13
        static let zoom = 14, gainDown = 15, gainUp = 16
    }

    func scopesRow(_ clipId: String) -> InspectorCustomRow {
        let open = grade.scopesOpen, width = bodyContentWidth
        let tilesH = ScopeLayout.height(grade.scopes.kinds, width: width)
        let height = open ? Self.scopeHead + Self.scopeChips + Self.scopeOptions + 6 + tilesH + 7 : 35
        return InspectorCustomRow(id: "grade:scopes", height: height, draw: { [weak self] c, r, _ in
            guard let self else { return }
            let state: PresetPreviewState? = open ? (self.scopeFrame?(clipId, Self.scopeFrameSide, Self.scopeFrameSide) ?? .unavailable) : nil
            let top = r.y + Self.scopeHead + Self.scopeChips + Self.scopeOptions + 6
            let tiles = ScopeLayout.tiles(self.grade.scopes.kinds, x: r.x, y: top, width: r.width)
            var result: (result: ScopeResult?, current: Bool) = (nil, false)
            if case .ready(let frame)? = state {
                result = self.scopeWorker.result(for: frame, request: Self.scopeRequest(self.grade.scopes, tiles, scale: c.deviceScale))
            }
            self.drawScopesHead(c, r, status: self.scopeStatus(state, current: result.current))
            if open {
                self.drawScopeChips(c, CanvasRect(x: r.x, y: r.y + Self.scopeHead, width: r.width, height: Self.scopeChips))
                self.drawScopeOptions(c, CanvasRect(x: r.x, y: r.y + Self.scopeHead + Self.scopeChips, width: r.width, height: Self.scopeOptions))
                for tile in tiles {
                    ScopeTile(kind: tile.kind, rect: tile.rect, result: result.result, settings: self.grade.scopes).draw(c)
                }
            }
            c.fillRect(CanvasRect(x: r.x, y: r.maxY - 1, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0 else { return }
            self.scopePointer(part)
            self.onEdited?()
        })
    }

    /// The settings and, per tile, its trace's size in device pixels (the plot area times the canvas scale).
    static func scopeRequest(_ settings: ScopeSettings, _ tiles: [(kind: ScopeKind, rect: CanvasRect)], scale: Double) -> ScopeRequest {
        let k = max(1, scale)
        var sizes: [ScopeKind: PixelSize] = [:]
        for tile in tiles {
            guard let plot = ScopeTile.tracePlot(tile.kind, tile.rect) else { continue }
            sizes[tile.kind] = PixelSize(Int((plot.width * k).rounded()), Int((plot.height * k).rounded()))
        }
        return ScopeRequest(settings: settings, sizes: sizes)
    }

    /// "Off" closed; while open: the frame's state, then whether the scopes show it yet.
    func scopeStatus(_ state: PresetPreviewState?, current: Bool) -> String {
        switch state {
        case nil: return "Off"
        case .rendering?: return "loading"
        case .unavailable?, .failed?: return "unavailable"
        case .ready?:
            if scopeWorker.lastFailure != nil { return "unreadable frame" }
            return current ? "ready" : "analysing"
        }
    }

    func scopePointer(_ part: Int) {
        switch part {
        case ScopePart.toggle: grade.scopesOpen.toggle(); scopeWorker.reset()
        case ScopePart.refresh: scopeWorker.reset()
        default: Self.applyScopeOption(part, to: &grade.scopes)
        }
    }

    /// The setting each option part changes; the remaining parts are the scope chips.
    static let scopeOptionEdits: [Int: (inout ScopeSettings) -> Void] = [
        ScopePart.percent: { $0.scale = .percent }, ScopePart.code10: { $0.scale = .code10 },
        ScopePart.target75: { $0.targetAmplitude = 0.75 }, ScopePart.target100: { $0.targetAmplitude = 1 },
        ScopePart.zoom: { $0.cycleZoom() }, ScopePart.gainDown: { $0.stepGain(-1) }, ScopePart.gainUp: { $0.stepGain(1) },
    ]

    static func applyScopeOption(_ part: Int, to settings: inout ScopeSettings) {
        if let edit = scopeOptionEdits[part] { edit(&settings); return }
        let kinds = ScopeKind.allCases, i = part - ScopePart.kind
        if kinds.indices.contains(i) { settings.toggle(kinds[i]) }
    }

    func drawScopesHead(_ c: CanvasContext, _ r: CanvasRect, status: String) {
        let open = grade.scopesOpen
        let head = CanvasRect(x: r.x, y: r.y, width: r.width, height: Self.scopeHead)
        let toggle = CanvasRect(x: head.x, y: head.y, width: head.width - (open ? 26 : 0), height: Self.scopeHead)
        PanelDraw.text(c, "Scopes", in: CanvasRect(x: toggle.x, y: toggle.midY - 8.25, width: 80, height: 16.5),
                       font: PanelTheme.font(11), color: PanelTheme.text2)
        let sw = c.measureText(status, font: PanelTheme.font(9)).width
        PanelDraw.text(c, status, in: CanvasRect(x: toggle.maxX - sw - 0.5, y: toggle.midY - 6.75, width: sw + 1, height: 13.5),
                       font: PanelTheme.font(9), color: PanelTheme.text5)
        addHit(toggle, .custom("grade:scopes", ScopePart.toggle))
        guard open else { return }
        let rb = CanvasRect(x: head.maxX - 18, y: head.midY - 9, width: 18, height: 18)
        PanelIcon.phosphor(.arrowClockwise).draw(c, in: rb.insetBy(4),
                                                 color: hovered == .custom("grade:scopes", ScopePart.refresh) ? PanelTheme.text1 : PanelTheme.text4)
        addHit(rb, .custom("grade:scopes", ScopePart.refresh))
    }

    /// One chip per scope, accent-underlined when shown.
    func drawScopeChips(_ c: CanvasContext, _ r: CanvasRect) {
        var x = r.x
        for (i, kind) in ScopeKind.allCases.enumerated() {
            let chip = ScopeChip(text: kind.label, on: grade.scopes.kinds.contains(kind), part: ScopePart.kind + i)
            x = scopeLabel(c, chip, at: x, in: r) + 8
        }
    }

    /// `% | 10-bit`, `75% | 100%`, the zoom (cycles) and `Gain - 1x +`.
    func drawScopeOptions(_ c: CanvasContext, _ r: CanvasRect) {
        let s = grade.scopes
        var x = scopeLabel(c, ScopeChip(text: "%", on: s.scale == .percent, part: ScopePart.percent), at: r.x, in: r) + 6
        x = scopeLabel(c, ScopeChip(text: "10-bit", on: s.scale == .code10, part: ScopePart.code10), at: x, in: r) + 14
        x = scopeLabel(c, ScopeChip(text: "75%", on: s.targetAmplitude == 0.75, part: ScopePart.target75), at: x, in: r) + 6
        x = scopeLabel(c, ScopeChip(text: "100%", on: s.targetAmplitude == 1, part: ScopePart.target100), at: x, in: r) + 14
        x = scopeLabel(c, ScopeChip(text: "Zoom \(Int(s.zoom))x", on: false, part: ScopePart.zoom), at: x, in: r) + 14
        x = scopeLabel(c, ScopeChip(text: "−", on: false, part: ScopePart.gainDown), at: x, in: r) + 4
        let gain = s.gain < 1 ? String(format: "%.2gx", s.gain) : "\(Int(s.gain))x"
        let gw = c.measureText("Gain " + gain, font: PanelTheme.font(9)).width
        PanelDraw.text(c, "Gain " + gain, in: CanvasRect(x: x, y: r.y + 4, width: gw + 1, height: 13.5), font: PanelTheme.font(9), color: PanelTheme.text3)
        _ = scopeLabel(c, ScopeChip(text: "+", on: false, part: ScopePart.gainUp), at: x + gw + 4, in: r)
    }

    /// A 9px clickable label (text1 + accent underline when on, text2 on hover, text4 otherwise); returns its maxX.
    func scopeLabel(_ c: CanvasContext, _ chip: ScopeChip, at x: Double, in r: CanvasRect) -> Double {
        let font = PanelTheme.font(9), w = c.measureText(chip.text, font: font).width
        let hit = CanvasRect(x: x - 2, y: r.y, width: w + 4, height: r.height)
        let hov = hovered == .custom("grade:scopes", chip.part)
        PanelDraw.text(c, chip.text, in: CanvasRect(x: x, y: r.y + 4, width: w + 1, height: 13.5), font: font,
                       color: chip.on ? PanelTheme.text1 : (hov ? PanelTheme.text2 : PanelTheme.text4))
        if chip.on { c.fillRect(CanvasRect(x: x, y: r.maxY - 3, width: w, height: 2), PanelTheme.accent) }
        addHit(hit, .custom("grade:scopes", chip.part))
        return x + w
    }
}

/// A clickable label of the Scopes row: its text, whether it is the chosen one, and its pointer part.
struct ScopeChip {
    let text: String, on: Bool, part: Int
}
