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

/// One channel strip per audio track. Meter values come from rendered playback blocks, post-fader/pre-bus.
public final class MixerPanel: DockedPanelView {
    public var editor: TimelineEditor?
    public var meters: [String: (peak: Double, rms: Double)] = [:]
    public private(set) var selected = 0
    private var list = PanelRowList(rowHeight: 112)
    private var drag: (id: String, pan: Bool, value: Double)?
    public init() {}
    public var tracks: [NativeProjectTrack] { editor?.document.sequence.tracks.filter { $0.kind == .audio } ?? [] }
    public var hint: String? { "Click or drag gain/pan; arrows: gain ±1 dB; Shift-arrows: pan; Up/Down: track; M: mute; S: solo" }

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        DockedPanelDraw.background(c, size: size)
        let tracks = self.tracks
        list.layout(viewport: CanvasRect(x: 0, y: 0, width: size.width, height: size.height), count: tracks.count)
        guard !tracks.isEmpty else {
            DockedPanelDraw.empty(c, size: size, title: "No audio tracks", detail: "Add an audio track to mix its sound."); return
        }
        c.save(); c.clip(list.viewport)
        for i in list.visibleRows {
            let t = tracks[i], r = list.rect(of: i)
            DockedPanelDraw.rowFill(c, r, selected: i == selected, hovered: false)
            let gain = drag.flatMap { $0.id == t.id && !$0.pan ? $0.value : nil } ?? t.mixerGainDB ?? 0
            let pan = drag.flatMap { $0.id == t.id && $0.pan ? $0.value : nil } ?? t.mixerPan ?? 0
            let muted = editor?.isTrackMuted(t.id) == true
            func text(_ s: String, _ y: Double) {
                PanelDraw.text(c, s, in: CanvasRect(x: 12, y: r.y + y, width: r.width - 24, height: 22), font: PanelTheme.mono(11), color: PanelTheme.text0)
            }
            PanelDraw.text(c, t.id, in: CanvasRect(x: 12, y: r.y, width: max(0, r.width - 124), height: 22), font: PanelTheme.mono(11), color: PanelTheme.text0)
            PanelDraw.text(c, muted ? "M ●" : "M", in: CanvasRect(x: r.width - 100, y: r.y, width: 44, height: 22), font: PanelTheme.mono(11), color: PanelTheme.text0)
            PanelDraw.text(c, t.soloed == true ? "S ●" : "S", in: CanvasRect(x: r.width - 52, y: r.y, width: 40, height: 22), font: PanelTheme.mono(11), color: PanelTheme.text0)
            text(String(format: "Gain %+.1f dB", gain), 24)
            text(String(format: "Pan %+.2f", pan), 50)
            let w = max(1, r.width - 24)
            c.fillRect(CanvasRect(x: 12, y: r.y + 46, width: w, height: 3), PanelTheme.panelHover)
            c.fillRect(CanvasRect(x: 12, y: r.y + 46, width: w * (gain + 60) / 72, height: 3), PanelTheme.accent)
            c.fillRect(CanvasRect(x: 12, y: r.y + 72, width: w, height: 3), PanelTheme.panelHover)
            c.fillRect(CanvasRect(x: 12 + w * (pan + 1) / 2 - 2, y: r.y + 70, width: 4, height: 7), PanelTheme.accent)
            let meter = meters[t.id] ?? (peak: 0, rms: 0)
            func db(_ v: Double) -> Double { v > 0 ? max(-60, 20 * log10(v)) : -60 }
            text(String(format: "Peak %+.1f / RMS %+.1f dBFS", db(meter.peak), db(meter.rms)), 78)
            c.fillRect(CanvasRect(x: 12, y: r.y + 103, width: w * min(1, (db(meter.rms) + 60) / 60), height: 4), PanelTheme.accent.withAlpha(0.5))
            c.fillRect(CanvasRect(x: 12 + w * min(1, (db(meter.peak) + 60) / 60), y: r.y + 101, width: 2, height: 8), PanelTheme.text0)
        }
        c.restore()
        PanelScrollbar.draw(c, track: list.viewport, offset: list.scrollY, content: list.contentHeight, hovered: false)
    }
    public func pointerDown(_ p: CanvasPoint, shift: Bool) -> Bool {
        guard let row = list.row(at: p), tracks.indices.contains(row), let editor else { return false }
        selected = row
        let t = tracks[row], y = p.y - list.rect(of: row).y
        if y < 24 {
            if p.x >= list.viewport.width - 52 { return editor.setTrackSoloed(t.id, t.soloed != true) }
            if p.x >= list.viewport.width - 100 { return editor.setTrackMuted(t.id, !editor.isTrackMuted(t.id)) }
            return true
        }
        if y < 78 { drag = (t.id, y >= 50, 0); return pointerMove(p) }
        return true
    }
    public func pointerMove(_ p: CanvasPoint) -> Bool {
        guard var d = drag else { return false }
        let fraction = min(1, max(0, (p.x - 12) / max(1, list.viewport.width - 24)))
        d.value = d.pan ? fraction * 2 - 1 : (fraction * 72 - 60).rounded()
        drag = d; return true
    }
    public func pointerUp(_ p: CanvasPoint) -> Bool {
        guard let d = drag else { return false }
        _ = pointerMove(p)
        let value = drag?.value ?? d.value
        drag = nil
        guard let t = tracks.first(where: { $0.id == d.id }) else { return true }
        _ = editor?.setTrackMixer(t.id, gainDB: d.pan ? t.mixerGainDB ?? 0 : value, pan: d.pan ? value : t.mixerPan ?? 0)
        return true
    }
    public func scroll(dy: Double) -> Bool { list.scroll(by: dy) }
    public func keyDown(_ k: EditorKey) -> Bool {
        guard let editor, !tracks.isEmpty, !k.command else { return false }
        selected = min(selected, tracks.count - 1)
        let t = tracks[selected]
        switch k.code {
        case .up: selected = max(0, selected - 1); return true
        case .down: selected = min(tracks.count - 1, selected + 1); return true
        case .left, .right:
            let delta = k.code == .left ? -1.0 : 1.0
            return editor.setTrackMixer(t.id, gainDB: min(12, max(-60, (t.mixerGainDB ?? 0) + (k.shift ? 0 : delta))),
                                       pan: min(1, max(-1, (t.mixerPan ?? 0) + (k.shift ? delta * 0.1 : 0))))
        case .char(let ch) where ch.lowercased() == "m": return editor.setTrackMuted(t.id, !editor.isTrackMuted(t.id))
        case .char(let ch) where ch.lowercased() == "s": return editor.setTrackSoloed(t.id, t.soloed != true)
        default: return false
        }
    }
}
