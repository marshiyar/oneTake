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
import MpvfxAudioGraph
import MpvfxTimeline

/// The parametric EQ module (`eq`): one graph point per band, a strip to pick, add and remove bands, and the
/// band's own settings under it. A drag moves a band's frequency and gain; Alt-drag or the wheel changes its Q; a
/// double-click on the plot adds a band; Delete removes the focused one; the arrow keys move it.
extension InspectorPanel {
    /// Height of the band strip under an EQ module's graph.
    static let afxEqStripH = 28.0

    /// Q after the pointer moved `dy` points up: a doubling every 40 points, inside the effect's range.
    static func afxBandQ(_ q: Double, raisedBy dy: Double) -> Double {
        (min(18, max(0.1, q * pow(2, dy / 40))) * 100).rounded() / 100
    }

    static func afxEqHasGain(_ kind: String) -> Bool { !["lowcut", "highcut", "notch"].contains(kind) }

    /// One point per band that filters, in band order (part k is band k's place in this list, plus one).
    static func afxEqHandles(_ node: FxNode, _ i: Int) -> [AfxGraphHandle] {
        let p = AudioFx.normalize("eq", node.params, version: node.version ?? 2)
        return AudioFxEq.activeBands(p).map { band in
            let k = band.band
            let kind = p[AudioFxEq.key(k, "type")]?.string ?? "bell"
            let hasGain = afxEqHasGain(kind), hasQ = !["lowshelf", "highshelf"].contains(kind)
            let f = p.num(AudioFxEq.key(k, "freq"))
            // A band without gain sits on the curve its own filter makes at its corner.
            let level = hasGain ? p.num(AudioFxEq.key(k, "gain"))
                : AudioFxResponse.bandGainDb(p, w: 2 * Double.pi * f / 48_000, sampleRate: 48_000, only: k)
            return AfxGraphHandle(node: i, frequency: f, gain: level, movesGain: hasGain, movesFrequency: true, band: nil,
                                  freqKey: AudioFxEq.key(k, "freq"), gainKey: AudioFxEq.key(k, "gain"), bandNumber: k,
                                  qKey: hasQ ? AudioFxEq.key(k, "q") : nil, q: hasQ ? p.num(AudioFxEq.key(k, "q")) : nil)
        }
    }

    /// `p` with one more band at `frequency` and `gain` (a bell), or nil at eight bands.
    static func afxEqAddingBand(_ p: FxParams, frequency: Double, gain: Double) -> FxParams? {
        let count = Int(p.num("bands").rounded())
        guard count < AudioFxEq.maxBands else { return nil }
        var next = p
        let k = count + 1
        next["bands"] = .number(Double(k))
        next[AudioFxEq.key(k, "type")] = .string("bell")
        next[AudioFxEq.key(k, "freq")] = .number(frequency.rounded())
        next[AudioFxEq.key(k, "gain")] = .number((gain * 10).rounded() / 10)
        next[AudioFxEq.key(k, "q")] = .number(1)
        next[AudioFxEq.key(k, "slope")] = .string("12")
        next[AudioFxEq.key(k, "bypass")] = .string("off")
        return AudioFx.normalize("eq", next, version: 2)
    }

    /// `p` without band `band`: the bands after it move up one place and the last one returns to its defaults.
    /// Nil when only one band is left.
    static func afxEqRemovingBand(_ p: FxParams, band: Int) -> FxParams? {
        let count = Int(p.num("bands").rounded())
        guard count > 1, (1...count).contains(band) else { return nil }
        let defaults = AudioFx.defaultParams("eq", version: 2)
        let names = ["type", "freq", "gain", "q", "slope", "bypass"]
        var next = p
        for k in band..<count {
            for name in names { next[AudioFxEq.key(k, name)] = p[AudioFxEq.key(k + 1, name)] }
        }
        for name in names { next[AudioFxEq.key(count, name)] = defaults[AudioFxEq.key(count, name)] }
        next["bands"] = .number(Double(count - 1))
        return AudioFx.normalize("eq", next, version: 2)
    }

    func afxEqPointer(_ node: FxNode, _ i: Int, update: @escaping (FxParams) -> Void) -> (Int, CanvasPoint, Int) -> Void {
        let row = "afx:node:\(i)"
        let params = AudioFx.normalize("eq", node.params, version: node.version ?? 2)
        return afxGraphPointer(row: row, handles: Self.afxEqHandles(node, i), pressed: { [weak self] h in
            if let band = h.bandNumber { self?.audioFxUI.selectedBand = band }
        }, plotDoubleClick: { [weak self] pt in
            guard let self, let g = self.audioFxUI.graphBoxes[row] else { return }
            let gain = max(-24, min(24, AfxGraphScale.gain(pt.y, range: g.range, in: g.box)))
            guard let next = Self.afxEqAddingBand(params, frequency: AfxGraphScale.frequency(pt.x, in: g.box), gain: gain) else { return }
            self.audioFxUI.selectedBand = Int(next.num("bands"))
            update(next)
        }, commitQ: { h, q in
            guard let key = h.qKey else { return }
            var next = params
            next[key] = .number(q)
            update(next)
        }) { h, f, g in
            update(Self.afxFilterParams(node, h, frequency: f, gain: g))
        }
    }

    /// Keys on a focused band point: Left / Right move its frequency by a twelfth of an octave (Shift: a third),
    /// Up / Down its gain by 0.5 dB (Shift: 3 dB), Alt+Up / Alt+Down its Q, Delete / Backspace remove the band.
    func afxEqKey(_ node: FxNode, _ i: Int, update: @escaping (FxParams) -> Void) -> (Int, EditorKey) -> Bool {
        let handles = Self.afxEqHandles(node, i)
        return { [weak self] part, k in
            guard handles.indices.contains(part - 1), let band = handles[part - 1].bandNumber else { return false }
            let h = handles[part - 1]
            self?.audioFxUI.selectedBand = band
            var p = AudioFx.normalize("eq", node.params, version: node.version ?? 2)
            switch k.code {
            case .space, .enter: return true
            case .delete, .backspace:
                if let next = Self.afxEqRemovingBand(p, band: band) { update(next) }
                return true
            case .left, .right:
                p[h.freqKey] = .number((h.frequency * pow(2, (k.shift ? 1.0 / 3 : 1.0 / 12) * (k.code == .left ? -1 : 1))).rounded())
            case .up, .down:
                let sign = k.code == .up ? 1.0 : -1.0
                if k.alt {
                    guard let key = h.qKey, let q = h.q else { return true }
                    p[key] = .number(q * pow(2, sign / 4))
                } else {
                    guard h.movesGain else { return true }
                    p[h.gainKey] = .number(h.gain + sign * (k.shift ? 3 : 0.5))
                }
            default: return false
            }
            update(AudioFx.normalize("eq", p, version: node.version ?? 2))
            return true
        }
    }

    /// A wheel notch over the plot: Q of the band nearest the pointer, up for narrower.
    func afxEqWheel(_ node: FxNode, _ i: Int, update: @escaping (FxParams) -> Void) -> (CanvasPoint, Double) -> Bool {
        let row = "afx:node:\(i)"
        return { [weak self] pt, dy in
            guard let self, let g = self.audioFxUI.graphBoxes[row] else { return false }
            let f = AfxGraphScale.frequency(pt.x, in: g.box)
            let bands = Self.afxEqHandles(node, i).filter { $0.q != nil }
            guard let h = bands.min(by: { abs(log($0.frequency / f)) < abs(log($1.frequency / f)) }), let key = h.qKey, let q = h.q else { return false }
            var p = AudioFx.normalize("eq", node.params, version: node.version ?? 2)
            p[key] = .number(Self.afxBandQ(q, raisedBy: -dy * 40 / 212))
            if let band = h.bandNumber { self.audioFxUI.selectedBand = band }
            update(p)
            return true
        }
    }

    /// The band strip's buttons (also the keyboard's way to pick, add and remove a band).
    func afxEqButtons(_ chain: FxChain, _ node: FxNode, _ i: Int, fxKey: String, write: @escaping (FxChain) -> Void) -> [InspectorRow] {
        let p = AudioFx.normalize("eq", node.params, version: node.version ?? chain.version)
        let count = Int(p.num("bands").rounded()), selected = min(count, max(1, audioFxUI.selectedBand))
        func set(_ next: FxParams?) {
            guard let next else { return }
            var chain = chain
            chain.nodes[i].params = next
            write(chain)
        }
        var buttons: [InspectorRow.Button] = (1...count).map { k in
            .init(key: "\(fxKey):band:\(k)", label: "Band \(k)", style: .muted) { [weak self] in
                self?.audioFxUI.selectedBand = k; self?.onEdited?()
            }
        }
        buttons.append(.init(key: "\(fxKey):band-add", label: "Add band", style: .muted, action: { [weak self] in
            let mid = Self.afxEqAddingBand(p, frequency: 1000, gain: 0)
            if let mid { self?.audioFxUI.selectedBand = Int(mid.num("bands")) }
            set(mid)
        }, disabled: count >= AudioFxEq.maxBands))
        buttons.append(.init(key: "\(fxKey):band-remove", label: "Remove band", style: .muted, action: {
            set(Self.afxEqRemovingBand(p, band: selected))
        }, disabled: count <= 1))
        return [.init(.buttons(buttons))]
    }

    /// The strip under the graph: "Band", then one chip per band (the picked one in brackets), "+" and "−".
    func afxEqStrip(_ c: CanvasContext, _ r: CanvasRect, _ node: FxNode, _ i: Int, fxKey: String, alpha: Double, enabled: Bool) {
        let p = AudioFx.normalize("eq", node.params, version: node.version ?? 2)
        let count = Int(p.num("bands").rounded()), selected = min(count, max(1, audioFxUI.selectedBand))
        let midY = r.midY
        var right = r.maxX
        right = afxSwitch(c, right: right, midY: midY, "−", hit: .button("\(fxKey):band-remove"), alpha: alpha, enabled: enabled && count > 1) - 4
        right = afxSwitch(c, right: right, midY: midY, "+", hit: .button("\(fxKey):band-add"), alpha: alpha, enabled: enabled && count < AudioFxEq.maxBands) - 8
        for k in stride(from: count, through: 1, by: -1) {
            let bypassed = p[AudioFxEq.key(k, "bypass")]?.string == "on"
            right = afxSwitch(c, right: right, midY: midY, k == selected ? "[\(k)]" : "\(k)", hit: .button("\(fxKey):band:\(k)"),
                              alpha: alpha * (bypassed ? 0.5 : 1), enabled: enabled) - 4
        }
        PanelDraw.text(c, "Band", in: CanvasRect(x: r.x, y: midY - 7, width: 40, height: 14), font: PanelTheme.font(11),
                       color: PanelTheme.text2.withAlpha(alpha))
    }

    /// The params an open EQ module lists: the band count, and the picked band's own (a slope only on a cut, gain
    /// not on a cut or notch, Q not on a shelf).
    static func afxEqShownKeys(_ p: FxParams, selected: Int) -> Set<String> {
        let k = max(1, min(Int(p.num("bands").rounded()), selected))
        let kind = p[AudioFxEq.key(k, "type")]?.string ?? "bell"
        var keys: Set<String> = ["bands", AudioFxEq.key(k, "type"), AudioFxEq.key(k, "freq"), AudioFxEq.key(k, "bypass")]
        if afxEqHasGain(kind) { keys.insert(AudioFxEq.key(k, "gain")) }
        if !["lowshelf", "highshelf"].contains(kind) { keys.insert(AudioFxEq.key(k, "q")) }
        if ["lowcut", "highcut"].contains(kind) { keys.insert(AudioFxEq.key(k, "slope")) }
        return keys
    }
}
