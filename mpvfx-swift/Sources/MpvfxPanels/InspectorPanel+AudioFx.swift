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

/// UI state of one Audio FX rack (per clip or bus).
public struct AudioFxUIState: Equatable {
    public enum Menu: Equatable { case none, presets, add }
    var owner: String?
    public var menu: Menu = .none
    /// The chain index whose module is open (`openNode`, 0 at mount).
    public var openNode: Int? = 0
    /// The Tone EQ whose faders are showing.
    public var openEq: String?
    /// Preset runs folded shut, by `<preset>-<first index>`: every run present when the rack mounts starts folded.
    public var collapsedRuns: Set<String> = []
    /// Nodes (by id) whose Details are open.
    public var details: Set<String> = []
}

/// One run of the hand-built chain: a preset's consecutive nodes, or one bare node (FxSection `runs`).
struct AudioFxRun {
    var preset: String?
    var items: [(node: FxNode, i: Int)]
    var key: String { "\(preset ?? "undefined")-\(items.first?.i ?? 0)" }
}

/// The Audio FX rack (FxRackChain, FxPresetRun, FxNodeRow, FxEqModule, FxPresetMenu,
/// FxAddMenu) drawn natively: the Tone EQ modules, then every preset run or hand-built module in signal order, the
/// preset shelf or add shelf when open, then "Presets" and "+ effect". Every control writes the chain through
/// `commit`, the same path the clip and bus racks always used, so each one is heard live and in the export.
extension InspectorPanel {
    static let afxGap = 4.0            // FxRackChain `space-y-1`
    static let afxSectionGap = 8.0     // FxSection `space-y-2`

    static func afxRuns(_ chain: FxChain) -> [AudioFxRun] {
        var out: [AudioFxRun] = []
        for (i, n) in chain.nodes.enumerated() where n.fromCarve != true && n.fromEq == nil {
            if let last = out.last, last.preset == n.fromPreset, n.fromPreset != nil { out[out.count - 1].items.append((n, i)) }
            else { out.append(AudioFxRun(preset: n.fromPreset, items: [(n, i)])) }
        }
        return out
    }

    /// The family a node letters and tints by (fxFamilyOf).
    static func afxFamily(_ n: FxNode) -> String {
        if n.fromCarve == true || n.fromEq != nil || n.fromLeveller == true { return "smart" }
        let g = AudioFx.definition(n.type)?.group
        return g == "dynamics" || g == "nonlinear" || g == "time" ? g! : "filter"
    }
    /// fxFamilyTint: the family hue, stepped by the module's place among its registry siblings.
    static func afxTint(_ n: FxNode) -> CanvasColor {
        let fam = afxFamily(n)
        if fam == "smart" { return CanvasColor(ThemeTokens.fxFamilyTintPair("smart", step: 0).now) }
        let sib = AudioFx.definitions.filter { afxFamily(FxNode(type: $0.id)) == fam }
        let idx = max(0, sib.firstIndex { $0.id == n.type } ?? 0)
        return CanvasColor(ThemeTokens.fxFamilyTintPair(fam, step: sib.count > 1 ? Double(idx) / Double(sib.count - 1) : 0).now)
    }

    /// Resets the rack state when the rack's owner changes, folding every preset run already there.
    func afxSeed(owner: String, _ chain: FxChain) {
        guard audioFxUI.owner != owner else { return }
        audioFxUI = AudioFxUIState(owner: owner)
        audioFxUI.collapsedRuns = Set(Self.afxRuns(chain).filter { $0.preset != nil }.map(\.key))
    }

    /// Presets, EQ and the signal chain for one FX chain (a clip's or a bus's); `commit` writes the next chain.
    func audioFxRackRows(_ chain: FxChain, owner: String, subject: String, _ commit: @escaping (FxChain) -> Bool) -> [InspectorRow] {
        afxSeed(owner: owner, chain)
        let ui = audioFxUI
        var rows: [InspectorRow] = []
        func gap(_ h: Double) { rows.append(.init(.spacer(h))) }
        let write: (FxChain) -> Void = { [weak self] next in self?.edited(commit(next)) }

        // Tone EQ modules lead the rack.
        let eqIds = AudioEq.ids(chain)
        for (k, eqId) in eqIds.enumerated() {
            if !rows.isEmpty { gap(Self.afxGap) }
            rows.append(afxEqModule(chain, eqId: eqId, first: k == 0, open: ui.openEq == eqId, write: write))
        }
        let runs = Self.afxRuns(chain)
        var positions: [Int: Int] = [:]
        var at = eqIds.count
        for run in runs { for item in run.items { at += 1; positions[item.i] = at } }
        if runs.isEmpty && eqIds.isEmpty {
            rows.append(.init(.custom(InspectorCustomRow(id: "afx:empty", height: 24.5, draw: { c, r, _ in
                PanelDraw.text(c, "No effects on this \(subject).", in: CanvasRect(x: r.x, y: r.y + 4, width: r.width, height: 16.5),
                               font: PanelTheme.font(11), color: PanelTheme.text2)
            }))))
        }
        for run in runs {
            if !rows.isEmpty { gap(Self.afxGap) }
            if let presetId = run.preset, let preset = AudioFxPresets.preset(presetId) {
                rows += afxPresetRun(chain, run, preset, positions: positions, ui: ui, write: write)
            } else {
                for (k, item) in run.items.enumerated() {
                    if k > 0 { gap(Self.afxGap) }
                    rows.append(afxNodeRow(chain, item.node, item.i, position: positions[item.i], inRun: nil, ui: ui, write: write))
                }
            }
        }
        if ui.menu == .add { gap(Self.afxSectionGap); rows.append(afxAddMenu(chain, write: write)) }
        if ui.menu == .presets { gap(Self.afxSectionGap); rows.append(afxPresetMenu(chain, write: write)) }
        gap(Self.afxSectionGap)
        rows.append(afxButtons(chain, ui: ui, write: write))
        return rows
    }

    // MARK: Controls shared by the rack

    /// `rounded-[3px] border border-panel-border-input px-1.5 py-0.5 font-mono text-[9px] text-panel-text-2` (On / Off).
    static func afxSwitchWidth(_ c: CanvasContext, _ label: String) -> Double { c.measureText(label, font: PanelTheme.mono(9)).width + 14 }
    func afxSwitch(_ c: CanvasContext, right: Double, midY: Double, _ label: String, hit: Hit, alpha: Double = 1, enabled: Bool = true) -> Double {
        let w = Self.afxSwitchWidth(c, label)
        let r = CanvasRect(x: right - w, y: midY - 9.75, width: w, height: 19.5)
        let hot = enabled && hovered == hit
        c.strokeRoundedRect(r.insetBy(0.5), radius: 3, PanelTheme.panelBorderInput.withAlpha(alpha), width: 1)
        PanelDraw.text(c, label, in: CanvasRect(x: r.x + 7, y: r.y + 3, width: w - 14 + 1, height: 13.5), font: PanelTheme.mono(9),
                       color: (hot ? PanelTheme.text0 : PanelTheme.text2).withAlpha(alpha * (enabled ? 1 : 0.4)))
        if enabled { addHit(r, hit) }
        return r.x
    }
    /// A `px-1 font-mono` glyph button (× remove, ↑ ↓ move): text-panel-text-2, hover text-0 (× hover red-400).
    func afxGlyph(_ c: CanvasContext, right: Double, midY: Double, _ glyph: String, size: Double, hit: Hit, danger: Bool = false,
                  alpha: Double = 1, enabled: Bool = true, disabledAlpha: Double = 0.4) -> Double {
        let f = PanelTheme.mono(size)
        let w = c.measureText(glyph, font: f).width + 8
        let r = CanvasRect(x: right - w, y: midY - 10, width: w, height: 20)
        let hot = enabled && hovered == hit
        let col = hot ? (danger ? PanelTheme.red400 : PanelTheme.text0) : PanelTheme.text2
        PanelDraw.text(c, glyph, in: CanvasRect(x: r.x, y: midY - size * 0.75, width: w, height: size * 1.5), font: f,
                       color: col.withAlpha(alpha * (enabled ? 1 : disabledAlpha)), align: .center)
        if enabled { addHit(r, hit) }
        return r.x
    }

    /// FxParamRow (`flex min-h-6 items-center gap-2`): the 86px 10px text-2 name, the range (`accent-panel-accent`),
    /// the 54px mono number field on bg-panel-surface, the unit, then the 20px reset (RotateCcw 11, opacity .4 at
    /// its default). Hits: `.slider(key)`, `.field(key)`, `.reset(key)` resolve through the row's controls.
    func afxParamRowDraw(_ c: CanvasContext, _ r: CanvasRect, key: String, label: String, position: Double, display: String,
                         unit: String, atDefault: Bool, enabled: Bool, alpha: Double, format: @escaping (Double) -> String,
                         min lo: Double, max hi: Double) {
        let midY = r.midY
        PanelDraw.text(c, label, in: CanvasRect(x: r.x, y: midY - 7.5, width: 86, height: 15), font: PanelTheme.font(10),
                       color: PanelTheme.text2.withAlpha(alpha))
        var right = r.maxX
        let reset = CanvasRect(x: right - 20, y: midY - 10, width: 20, height: 20)
        let resetOn = enabled && !atDefault
        if resetOn && hovered == .reset(key) { c.fillRoundedRect(reset, radius: 4, PanelTheme.panelHover.withAlpha(alpha)) }
        PanelIcon.reset.draw(c, in: CanvasRect(x: reset.midX - 5.5, y: midY - 5.5, width: 11, height: 11),
                             color: (resetOn && hovered == .reset(key) ? PanelTheme.text0 : PanelTheme.text2).withAlpha(alpha * (resetOn ? 1 : 0.4)))
        if resetOn { addHit(reset, .reset(key)) }
        right = reset.x - 8
        if !unit.isEmpty {
            PanelDraw.text(c, unit, in: CanvasRect(x: right - 22, y: midY - 6.75, width: 22, height: 13.5), font: PanelTheme.mono(9),
                           color: PanelTheme.text2.withAlpha(alpha))
            right -= 22 + 8
        }
        let box = CanvasRect(x: right - 54, y: midY - 9.5, width: 54, height: 19)
        let editing = field?.key == key
        c.fillRoundedRect(box, radius: 3, (editing ? PanelTheme.panelInput : PanelTheme.panelSurface).withAlpha(alpha))
        let dragging = sliderDrag?.key == key
        let pos = dragging ? sliderDrag!.current : position
        let text = editing ? (field?.draft ?? display) : (dragging ? format(pos) : display)
        let tr = CanvasRect(x: box.x + 4, y: box.y + 2, width: box.width - 8, height: 15)
        PanelDraw.text(c, text, in: tr, font: PanelTheme.mono(10), color: PanelTheme.text0.withAlpha(alpha * (enabled ? 1 : 0.5)), align: .right)
        if editing { c.fillRect(CanvasRect(x: tr.maxX + 1, y: tr.midY - 6, width: 1, height: 12), PanelTheme.accent) }
        if enabled { addHit(box, .field(key)) }
        // The range: a 4px track (bg-panel-hover) with the accent fill and a 16px accent thumb.
        let track = CanvasRect(x: r.x + 86 + 8, y: midY - 8, width: Swift.max(8, box.x - 8 - (r.x + 94)), height: 16)
        let pct = Swift.max(0, Swift.min(1, (pos - lo) / Swift.max(1e-9, hi - lo)))
        let k = 16.0, usable = track.width - k
        let cx = track.x + k / 2 + usable * pct
        c.fillRoundedRect(CanvasRect(x: track.x, y: midY - 2, width: track.width, height: 4), radius: 2, PanelTheme.panelHover.withAlpha(alpha))
        c.fillRoundedRect(CanvasRect(x: track.x, y: midY - 2, width: cx - track.x, height: 4), radius: 2,
                          (enabled ? PanelTheme.accent : PanelTheme.text4).withAlpha(alpha))
        c.fill(.roundedRect(CanvasRect(x: cx - k / 2, y: midY - k / 2, width: k, height: k), radius: k / 2),
               (enabled ? PanelTheme.accent : PanelTheme.text4).withAlpha(alpha))
        if enabled { addHit(track, .slider(key)) }
    }

    /// The descriptors an FxParamRow drives: a slider (`position` in `min…max`), a number field and its reset.
    static func afxParamControls(key: String, label: String, position: Double, min lo: Double, max hi: Double,
                                 display: String, format: @escaping (Double) -> String, atDefault: Bool,
                                 commitPosition: @escaping (Double) -> Void, commitText: @escaping (String) -> Void,
                                 reset: @escaping () -> Void) -> [InspectorRow] {
        [.init(.slider(.init(key: key, label: label, position: position, min: lo, max: hi, display: display, format: format,
                             tier: atDefault ? .default : .explicitCustom, commit: commitPosition, reset: reset))),
         .init(.number(.init(key: key, label: label, text: display, tier: atDefault ? .default : .explicitCustom, commit: commitText, reset: reset)))]
    }

    // MARK: Tone EQ (FxEqModule)

    static let eqHeadH = 24.5, eqSummaryH = 22.5, eqFaderH = 74.0
    static var eqOpenBodyH: Double { eqFaderH + 4 + 13.5 + 4 + 13.5 + 4 + 20 + 6 + 12 + 8 }

    func afxEqModule(_ chain: FxChain, eqId: String, first: Bool, open: Bool, write: @escaping (FxChain) -> Void) -> InspectorRow {
        let bands = AudioEq.readBands(chain, eqId: eqId)
        let id = "afx:eq:\(eqId)"
        let bandKey: (String) -> String = { first ? "eq:\($0)" : "eq:\(eqId):\($0)" }
        var controls: [InspectorRow] = [.init(.buttons([
            .init(key: "eq:\(eqId):open", label: "Tone", style: .muted) { [weak self] in
                guard let self else { return }
                self.audioFxUI.openEq = self.audioFxUI.openEq == eqId ? nil : eqId; self.onEdited?()
            },
            .init(key: "eq:\(eqId):remove", label: "×", style: .muted) { write(AudioEq.remove(chain, eqId: eqId)) },
        ]))]
        if first { controls.append(.init(.buttons([.init(key: "eq:remove", label: "Remove", style: .muted) { write(AudioEq.remove(chain, eqId: eqId)) }]))) }
        for band in bands {
            let k = bandKey(band.name)
            let set: (Double) -> Void = { g in write(AudioEq.setBandGain(chain, eqId: eqId, band: band.name, gain: (g * 10).rounded() / 10)) }
            controls.append(.init(.slider(.init(
                key: k, label: band.name, position: band.gain, min: -AudioEq.rangeDb, max: AudioEq.rangeDb,
                display: String(format: "%+.1f dB", band.gain), format: { String(format: "%+.1f dB", $0) },
                tier: band.gain == 0 ? .default : .explicitCustom, centerTick: true,
                commit: { v in set((v * 2).rounded() / 2) },   // the fader's 0.5 dB step
                reset: { set(0) }, vertical: true))))
        }
        let tint = Self.afxTint(FxNode(type: "eq", fromEq: eqId))
        let h = 2 + Self.eqHeadH + (open ? Self.eqOpenBodyH : Self.eqSummaryH)
        return .init(.custom(InspectorCustomRow(id: id, height: h, draw: { [weak self] c, r, _ in
            guard let self else { return }
            Self.afxModuleFrame(c, r, tint: tint, alpha: 1)
            let head = CanvasRect(x: r.x + 2 + 6, y: r.y + 1, width: r.width - 3 - 12, height: Self.eqHeadH)
            let midY = head.midY
            var right = self.afxGlyph(c, right: head.maxX, midY: midY, "×", size: 11, hit: .button("eq:\(eqId):remove"), danger: true) - 6
            let lab = "\(bands.count)-band"
            let lw = c.measureText(lab, font: PanelTheme.mono(9)).width
            PanelDraw.text(c, lab, in: CanvasRect(x: right - lw, y: midY - 6.75, width: lw + 1, height: 13.5), font: PanelTheme.mono(9), color: PanelTheme.text2)
            right -= lw + 6
            let nameR = CanvasRect(x: head.x, y: head.y, width: Swift.max(0, right - head.x), height: head.height)
            PanelDraw.text(c, "Tone", in: CanvasRect(x: nameR.x, y: midY - 8.25, width: nameR.width, height: 16.5), font: PanelTheme.mono(11, .medium),
                           color: self.hovered == .button("eq:\(eqId):open") ? PanelTheme.text1 : PanelTheme.text0)
            self.addHit(nameR, .button("eq:\(eqId):open"))
            let body = CanvasRect(x: r.x + 2 + 8, y: head.maxY, width: r.width - 3 - 16, height: r.maxY - 1 - head.maxY)
            guard open else {
                PanelDraw.text(c, AudioEq.summary(bands), in: CanvasRect(x: body.x, y: body.y, width: body.width, height: 16.5),
                               font: PanelTheme.font(11), color: PanelTheme.text2)
                return
            }
            let n = Double(Swift.max(1, bands.count)), gapX = 6.0
            let colW = (body.width - gapX * (n - 1)) / n
            for (i, band) in bands.enumerated() {
                let x = body.x + Double(i) * (colW + gapX)
                self.afxFader(c, CanvasRect(x: x, y: body.y, width: colW, height: Self.eqOpenBodyH - 26), band: band, key: bandKey(band.name))
            }
            let foot = CanvasRect(x: body.x, y: body.y + Self.eqOpenBodyH - 8 - 12, width: body.width, height: 12)
            PanelDraw.tracked(c, "CUT", in: foot, font: PanelTheme.mono(8), tracking: 0.2, color: PanelTheme.text2)
            let bw = c.measureText("BOOST", font: PanelTheme.mono(8)).width + 1
            PanelDraw.tracked(c, "BOOST", in: CanvasRect(x: foot.maxX - bw, y: foot.y, width: bw, height: 12), font: PanelTheme.mono(8),
                              tracking: 0.2, color: PanelTheme.text2)
        })), controls: controls)
    }

    /// One fader column: the 74px travel (centre detent line, 3px accent fill from 0 dB to the value, the cap), the
    /// band name (mono 9 uppercase), the value (accent once moved off 0) and the 20px reset.
    func afxFader(_ c: CanvasContext, _ r: CanvasRect, band: AudioEqBand, key: String) {
        let travel = CanvasRect(x: r.x, y: r.y, width: r.width, height: Self.eqFaderH)
        let dragging = sliderDrag?.key == key
        let value = dragging ? (sliderDrag!.current * 2).rounded() / 2 : band.gain
        let range = AudioEq.rangeDb
        let pct = 50 - (Swift.max(-range, Swift.min(range, value)) / (range * 2)) * 100   // offsetFor: % from the top
        let yv = travel.y + travel.height * pct / 100, y0 = travel.midY
        c.fillRect(CanvasRect(x: travel.x, y: y0 - 0.5, width: travel.width, height: 1), PanelTheme.panelBorderInput)
        c.fillRoundedRect(CanvasRect(x: travel.midX - 1.5, y: Swift.min(yv, y0), width: 3, height: abs(y0 - yv)), radius: 1, PanelTheme.accent)
        let cap = CanvasRect(x: travel.midX - 8, y: yv - 3, width: 16, height: 6)
        c.fillRoundedRect(cap, radius: 2, dragging || hovered == .slider(key) ? PanelTheme.text0 : PanelTheme.text1)
        addHit(CanvasRect(x: travel.midX - 10, y: travel.y, width: 20, height: travel.height), .slider(key))
        var y = travel.maxY + 4
        let nameW = Self.trackedWidth(c, band.name.uppercased(), font: PanelTheme.mono(9), tracking: 0.225)
        c.withState {
            c.clip(CanvasRect(x: r.x, y: y, width: r.width, height: 13.5))
            PanelDraw.tracked(c, band.name.uppercased(), in: CanvasRect(x: r.midX - nameW / 2, y: y, width: nameW, height: 13.5), font: PanelTheme.mono(9),
                              tracking: 0.225, color: PanelTheme.text2)
        }
        y += 13.5 + 4
        let moved = abs(value) >= 0.05
        let v = jsRoundTo(value, 1)
        PanelDraw.text(c, moved ? (v > 0 ? "+" : "") + jsNumberToString(v) : "0", in: CanvasRect(x: r.x, y: y, width: r.width, height: 13.5),
                       font: PanelTheme.mono(9), color: moved ? PanelTheme.accent : PanelTheme.text2, align: .center)
        y += 13.5 + 4
        let reset = CanvasRect(x: r.midX - 10, y: y, width: 20, height: 20)
        let neutral = value == 0
        if !neutral && hovered == .reset(key) { c.fillRoundedRect(reset, radius: 4, PanelTheme.panelHover) }
        PanelIcon.reset.draw(c, in: CanvasRect(x: reset.midX - 5.5, y: reset.midY - 5.5, width: 11, height: 11),
                             color: (!neutral && hovered == .reset(key) ? PanelTheme.text0 : PanelTheme.text2).withAlpha(neutral ? 0.4 : 1))
        if !neutral { addHit(reset, .reset(key)) }
    }

    /// A module card: `rounded-[4px] border border-l-2 border-panel-border-input` with the tint on the left edge.
    static func afxModuleFrame(_ c: CanvasContext, _ box: CanvasRect, tint: CanvasColor, alpha: Double) {
        let r = box.snapped
        c.strokeRoundedRect(r.insetBy(0.5), radius: 4, PanelTheme.panelBorderInput.withAlpha(alpha), width: 1)
        c.withState {
            c.clip(.roundedRect(r, radius: 4))
            c.fillRect(CanvasRect(x: r.x, y: r.y, width: 2, height: r.height), tint.withAlpha(alpha))
        }
    }

    // MARK: Preset runs (FxPresetRun)

    static let runHeadH = 24.0, runAmountH = 24.0

    func afxPresetRun(_ chain: FxChain, _ run: AudioFxRun, _ preset: FxPreset, positions: [Int: Int], ui: AudioFxUIState,
                      write: @escaping (FxChain) -> Void) -> [InspectorRow] {
        let key = run.key, collapsed = ui.collapsedRuns.contains(key)
        let amount = run.items.first?.node.presetAmount ?? 1
        let slots = Set(run.items.map(\.i))
        let setAmount: (Double) -> Void = { v in
            var next = chain
            for i in slots { next.nodes[i].presetAmount = v }
            write(next)
        }
        let amountKey = "run:\(key):amount"
        let fmt: (Double) -> String = { String(format: "%.2f", $0) }
        var controls: [InspectorRow] = [.init(.buttons([
            .init(key: "run:\(key):collapse", label: preset.label, style: .muted) { [weak self] in
                guard let self else { return }
                if self.audioFxUI.collapsedRuns.contains(key) { self.audioFxUI.collapsedRuns.remove(key) } else { self.audioFxUI.collapsedRuns.insert(key) }
                self.onEdited?()
            },
            .init(key: "run:\(key):toggle", label: amount > 0 ? "On" : "Off", style: .muted) { setAmount(amount > 0 ? 0 : 1) },
            .init(key: "run:\(key):remove", label: "×", style: .muted) { [weak self] in
                self?.audioFxUI.openNode = nil
                write(FxChain(nodes: chain.nodes.enumerated().filter { !slots.contains($0.offset) }.map(\.element)))
            },
        ]))]
        controls += Self.afxParamControls(
            key: amountKey, label: "Amount", position: amount, min: 0, max: 1, display: fmt(amount), format: fmt, atDefault: amount == 1,
            commitPosition: { setAmount((Swift.max(0, Swift.min(1, $0)) * 100).rounded() / 100) },
            commitText: { t in if let v = PanelFormat.parse(t) { setAmount((Swift.max(0, Swift.min(1, v)) * 100).rounded() / 100) } },
            reset: { setAmount(1) })
        let edge = CanvasColor(ThemeTokens.fxPresetEdgePair(preset.id).now)
        let wash = ThemeTokens.fxPresetWashPair(preset.id).map { CanvasColor($0.now) }
        let headH = 1 + 6 + Self.runHeadH + 4 + Self.runAmountH
        var rows: [InspectorRow] = [.init(.custom(InspectorCustomRow(id: "afx:run:\(key)", height: headH, draw: { [weak self] c, r, _ in
            guard let self else { return }
            Self.afxRunFrame(c, r, edge: edge, wash: wash, top: true, bottom: false)
            let inner = CanvasRect(x: r.x + 7, y: r.y + 7, width: r.width - 14, height: r.height - 7)
            let head = CanvasRect(x: inner.x + 2, y: inner.y, width: inner.width - 4, height: Self.runHeadH)
            var right = self.afxGlyph(c, right: head.maxX, midY: head.midY, "×", size: 11, hit: .button("run:\(key):remove"), danger: true) - 4
            right = self.afxSwitch(c, right: right, midY: head.midY, amount > 0 ? "On" : "Off", hit: .button("run:\(key):toggle")) - 4
            let lab = CanvasRect(x: head.x, y: head.y, width: Swift.max(0, right - head.x), height: head.height)
            let hot = self.hovered == .button("run:\(key):collapse")
            let col = (PanelTheme.text1).withAlpha(hot ? 0.8 : 1)
            let caret = collapsed ? "▸" : "▾"
            let cw = c.measureText(caret, font: PanelTheme.mono(11)).width
            PanelDraw.text(c, caret, in: CanvasRect(x: lab.x, y: head.midY - 8.25, width: cw + 1, height: 16.5), font: PanelTheme.mono(11), color: col.withAlpha(0.6))
            let tx = lab.x + cw + 4
            let ls = PanelDraw.text(c, preset.label, in: CanvasRect(x: tx, y: head.midY - 8.25, width: Swift.max(0, lab.maxX - tx), height: 16.5),
                                    font: PanelTheme.font(11, .medium), color: col)
            if collapsed {
                PanelDraw.text(c, "\(run.items.count)", in: CanvasRect(x: tx + ls.width + 6, y: head.midY - 6.25, width: Swift.max(0, lab.maxX - tx - ls.width - 6), height: 13.5),
                               font: PanelTheme.mono(9), color: col.withAlpha(0.6))
            }
            self.addHit(lab, .button("run:\(key):collapse"))
            let ar = CanvasRect(x: inner.x, y: head.maxY + 4, width: inner.width, height: Self.runAmountH)
            self.afxParamRowDraw(c, ar, key: amountKey, label: "Amount", position: amount, display: fmt(amount), unit: "", atDefault: amount == 1,
                                 enabled: true, alpha: 1, format: fmt, min: 0, max: 1)
        })), controls: controls)]
        // Folded, the run still carries its nodes' controls (bypass, remove) for a scripted drive; it draws none of them.
        for item in run.items {
            let node = afxNodeRow(chain, item.node, item.i, position: positions[item.i], inRun: (edge, wash), ui: ui, write: write)
            if collapsed { rows[0].controls += node.controls } else { rows.append(node) }
        }
        rows.append(.init(.custom(InspectorCustomRow(id: "afx:run:\(key):end", height: 7, draw: { c, r, _ in
            Self.afxRunFrame(c, r, edge: edge, wash: wash, top: false, bottom: true)
        }))))
        return rows
    }

    /// One slice of a preset bracket (`rounded-[4px] border border-panel-border-input p-1.5`, the preset's colour on
    /// the left edge, its wash behind): the bracket is drawn across the rows it wraps, closing at its top and bottom.
    static func afxRunFrame(_ c: CanvasContext, _ box: CanvasRect, edge: CanvasColor, wash: CanvasColor?, top: Bool, bottom: Bool) {
        let r = box.snapped
        let ext = 8.0
        let full = CanvasRect(x: r.x, y: top ? r.y : r.y - ext, width: r.width, height: r.height + (top ? 0 : ext) + (bottom ? 0 : ext))
        c.withState {
            c.clip(r)
            if let wash { c.fillRoundedRect(full, radius: 4, wash) }
            c.strokeRoundedRect(full.insetBy(0.5), radius: 4, PanelTheme.panelBorderInput, width: 1)
            c.clip(.roundedRect(full, radius: 4))
            c.fillRect(CanvasRect(x: r.x, y: r.y, width: 1, height: r.height), edge)
        }
    }

    // MARK: Modules (FxNodeRow)

    static let nodeHeadH = 28.0, nodeSummaryH = 19.0

    /// A param of an open module: its key, plain label, and how to draw / drive it.
    struct AfxParam {
        var key: String, label: String
        var def: FxParamDef?   // nil: the derived strength knob
    }

    func afxNodeRow(_ chain: FxChain, _ node: FxNode, _ i: Int, position: Int?, inRun: (CanvasColor, CanvasColor?)?, ui: AudioFxUIState,
                    write: @escaping (FxChain) -> Void) -> InspectorRow {
        let fxKey = "fx:\(i)"
        let bypassed = node.enabled == false
        let open = ui.openNode == i
        let params = node.params ?? AudioFx.defaultParams(node.type)
        let summary = AudioFxCopy.summary(node.type, params)
        let def = AudioFx.definition(node.type)
        let label = node.label ?? AudioFxCopy.effects[node.type]?.title ?? def?.label ?? node.type
        let family = Self.afxFamily(node), tint = Self.afxTint(node)
        let count = chain.nodes.count
        let nodeId = node.id ?? "\(node.type)-\(i)"
        let update: (FxParams) -> Void = { p in var next = chain; next.nodes[i].params = AudioFx.normalize(node.type, p); write(next) }
        let move: (Int) -> Void = { [weak self] d in
            let t = i + d
            guard t >= 0, t < count else { return }
            var next = chain
            let m = next.nodes.remove(at: i); next.nodes.insert(m, at: t)
            self?.audioFxUI.openNode = t
            write(next)
        }
        var controls: [InspectorRow] = [
            .init(.fxNode(.init(key: fxKey, label: label, detail: def?.label ?? node.type, enabled: !bypassed,
                                toggle: { var next = chain; next.nodes[i].enabled = bypassed ? true : false; write(next) },
                                remove: { [weak self] in self?.audioFxUI.openNode = nil; var next = chain; next.nodes.remove(at: i); write(next) }))),
            .init(.buttons([
                .init(key: "\(fxKey):open", label: label, style: .muted) { [weak self] in
                    guard let self else { return }
                    self.audioFxUI.openNode = self.audioFxUI.openNode == i ? nil : i; self.onEdited?()
                },
                .init(key: "\(fxKey):up", label: "↑", style: .muted, action: { move(-1) }, disabled: i == 0),
                .init(key: "\(fxKey):down", label: "↓", style: .muted, action: { move(1) }, disabled: i == count - 1),
                .init(key: "\(fxKey):details", label: "Details", style: .muted) { [weak self] in
                    guard let self else { return }
                    if self.audioFxUI.details.contains(nodeId) { self.audioFxUI.details.remove(nodeId) } else { self.audioFxUI.details.insert(nodeId) }
                    self.onEdited?()
                },
            ])),
        ]
        // The open face (FxNodeOpenBody): what it is for, the one knob and its ends, then Details.
        let copy = AudioFxCopy.effects[node.type]
        let profile = AudioFxProfiles.profiles[node.type]
        let primary = AudioFxCopy.primaryParam(node.type)
        let oneKnob = primary != nil || profile != nil
        let details = ui.details.contains(nodeId)
        var face: [AfxParam] = []
        if let profile { face = [AfxParam(key: "strength", label: profile.label, def: nil)] }
        else if let primary, let d = def?.params.first(where: { $0.key == primary }) {
            face = [AfxParam(key: primary, label: AudioFxCopy.paramLabel(node.type, primary, fallback: d.label), def: d)]
        }
        let all = (def?.params ?? []).map { AfxParam(key: $0.key, label: AudioFxCopy.paramLabel(node.type, $0.key, fallback: $0.label), def: $0) }
        let shownFace = details ? [] : face
        let shownAll = details || !oneKnob ? all : []
        var seen = Set<String>()
        for p in face + all where seen.insert(p.key).inserted {
            controls += afxNodeParamControls(node, params, p, key: "\(fxKey):\(p.key)", update: update)
        }
        let contentW = bodyContentWidth - (inRun != nil ? 14 : 0)
        let doesH = copy.map { 8 + 15 * Double(Self.wrapLines($0.does, width: contentW - 12, charW: 5.3).count) } ?? 0
        let paramsH: ([AfxParam]) -> Double = { ps in ps.isEmpty ? 0 : 1 + 12 + Double(ps.count) * 24 + Double(ps.count - 1) * 2 }
        let endsH = !shownFace.isEmpty && copy != nil ? 17.5 : 0
        let detailsH = 1 + 21.5 - (oneKnob ? 0 : 4)
        let openH = open ? doesH + paramsH(shownFace) + endsH + detailsH + paramsH(shownAll) : 0
        let cardH = 2 + Self.nodeHeadH + (summary != nil ? Self.nodeSummaryH : 0) + openH
        let topGap = inRun != nil ? 4.0 : 0
        let name = Self.afxLettered(label, family: family)
        return .init(.custom(InspectorCustomRow(id: "afx:node:\(i)", height: topGap + cardH, draw: { [weak self] c, r, _ in
            guard let self else { return }
            var card = r
            if let run = inRun {
                Self.afxRunFrame(c, r, edge: run.0, wash: run.1, top: false, bottom: false)
                card = CanvasRect(x: r.x + 7, y: r.y + topGap, width: r.width - 14, height: cardH)
            }
            let a = bypassed ? 0.5 : 1.0   // `opacity-50` on a bypassed module
            Self.afxModuleFrame(c, card, tint: tint, alpha: a)
            let head = CanvasRect(x: card.x + 2 + 6, y: card.y + 1, width: card.width - 3 - 12, height: Self.nodeHeadH)
            let midY = head.midY
            var right = self.afxGlyph(c, right: head.maxX, midY: midY, "×", size: 11, hit: .fxRemove(fxKey), danger: true, alpha: a) - 4
            right = self.afxGlyph(c, right: right, midY: midY, "↓", size: 10, hit: .button("\(fxKey):down"), alpha: a,
                                  enabled: i < count - 1, disabledAlpha: 0.25) - 4
            right = self.afxGlyph(c, right: right, midY: midY, "↑", size: 10, hit: .button("\(fxKey):up"), alpha: a,
                                  enabled: i > 0, disabledAlpha: 0.25) - 4
            right = self.afxSwitch(c, right: right, midY: midY, bypassed ? "Off" : "On", hit: .fxToggle(fxKey), alpha: a) - 4
            var x = head.x
            if let position {
                let s = position < 10 ? "0\(position)" : "\(position)"
                let w = c.measureText(s, font: PanelTheme.mono(9)).width
                PanelDraw.text(c, s, in: CanvasRect(x: x, y: midY - 6.75, width: w + 1, height: 13.5), font: PanelTheme.mono(9),
                               color: PanelTheme.text2.withAlpha(a))
                x += w + 4
            }
            let nameR = CanvasRect(x: x, y: head.y, width: Swift.max(0, right - x), height: head.height)
            let hot = self.hovered == .button("\(fxKey):open")
            c.withState {
                c.clip(nameR)
                let col = (hot ? PanelTheme.text0 : PanelTheme.text1).withAlpha(a)
                if name.tracking > 0 {
                    PanelDraw.tracked(c, name.text, in: CanvasRect(x: nameR.x, y: midY - 8.25, width: nameR.width, height: 16.5), font: name.font,
                                      tracking: name.tracking, color: col)
                } else {
                    PanelDraw.text(c, name.text, in: CanvasRect(x: nameR.x, y: midY - 8.25, width: nameR.width, height: 16.5), font: name.font, color: col)
                }
            }
            self.addHit(nameR, .button("\(fxKey):open"))
            var y = head.maxY
            if let summary {
                PanelDraw.text(c, summary, in: CanvasRect(x: card.x + 2 + 6, y: y, width: card.width - 3 - 12, height: 15), font: PanelTheme.font(10),
                               color: PanelTheme.text2.withAlpha(a))
                y += Self.nodeSummaryH
            }
            guard open else { return }
            let bx = card.x + 2, bw = card.width - 3
            func rule() { c.fillRect(CanvasRect(x: bx, y: y, width: bw, height: 1), PanelTheme.panelBorderInput.withAlpha(a)) }
            if let copy {
                rule()
                var ly = y + 1 + 4
                for line in Self.wrapLines(copy.does, width: bw - 12, charW: 5.3) {
                    PanelDraw.text(c, line, in: CanvasRect(x: bx + 6, y: ly, width: bw - 12, height: 15), font: PanelTheme.font(10), color: PanelTheme.text2.withAlpha(a))
                    ly += 15
                }
                y += doesH
            }
            func drawParams(_ ps: [AfxParam]) {
                guard !ps.isEmpty else { return }
                rule()
                var py = y + 1 + 6
                for p in ps {
                    self.afxNodeParamDraw(c, CanvasRect(x: bx + 6, y: py, width: bw - 12, height: 24), node, params, p,
                                          key: "\(fxKey):\(p.key)", enabled: !bypassed, alpha: a)
                    py += 26
                }
                y += paramsH(ps)
            }
            drawParams(shownFace)
            if endsH > 0, let copy {
                let er = CanvasRect(x: bx + 6, y: y, width: bw - 12, height: 13.5)
                PanelDraw.text(c, copy.ends.low, in: CanvasRect(x: er.x, y: er.y, width: er.width / 2 - 4, height: er.height), font: PanelTheme.font(9),
                               color: PanelTheme.text2.withAlpha(a))
                PanelDraw.text(c, copy.ends.high, in: CanvasRect(x: er.midX + 4, y: er.y, width: er.width / 2 - 4, height: er.height), font: PanelTheme.font(9),
                               color: PanelTheme.text2.withAlpha(a), align: .right)
                y += endsH
            }
            rule()
            let dr = CanvasRect(x: bx, y: y + 1, width: bw, height: detailsH - 1)
            let mech = "Details — \(def?.label ?? node.type)".uppercased()
            let dhot = oneKnob && self.hovered == .button("\(fxKey):details")
            PanelDraw.tracked(c, oneKnob ? (details ? "▾ " : "▸ ") + mech : mech,
                              in: CanvasRect(x: dr.x + 6, y: dr.y + (oneKnob ? 4 : 4), width: dr.width - 12, height: 13.5), font: PanelTheme.mono(9),
                              tracking: 0.225, color: (dhot ? PanelTheme.text0 : PanelTheme.text2).withAlpha(a))
            if oneKnob { self.addHit(dr, .button("\(fxKey):details")) }
            y += detailsH
            drawParams(shownAll)
        })), controls: controls)
    }

    /// Width of `PanelDraw.tracked` text (no tracking after the last glyph).
    static func trackedWidth(_ c: CanvasContext, _ s: String, font: CanvasFont, tracking: Double) -> Double {
        s.reduce(0.0) { $0 + c.measureText(String($1), font: font).width + tracking } - (s.isEmpty ? 0 : tracking)
    }

    /// FX_FAMILY_TYPE lettering: filter light caps tracked .14em, dynamics bold caps, non-linear plain (a serif
    /// italic face is not in the canvas fonts), time caps tracked .24em, smart mono medium.
    static func afxLettered(_ s: String, family: String) -> (text: String, font: CanvasFont, tracking: Double) {
        switch family {
        case "filter": (s.uppercased(), PanelTheme.font(11), 11 * 0.14)
        case "dynamics": (s.uppercased(), PanelTheme.font(11, .bold), 0)
        case "time": (s.uppercased(), PanelTheme.font(11), 11 * 0.24)
        case "smart": (s, PanelTheme.mono(11, .medium), 0)
        default: (s, PanelTheme.font(11), 0)
        }
    }

    static func wrapLines(_ s: String, width: Double, charW: Double) -> [String] {
        wrap(s, perLine: Swift.max(8, Int(width / charW)))
    }

    static func afxDecimals(_ step: Double) -> Int { step >= 1 ? 0 : step >= 0.1 ? 1 : 2 }

    /// One open-module control's descriptors: a number knob (log-scale knobs travel in log space, as toSlider), the
    /// derived strength knob, or an enum (pressing the field steps to the next option).
    func afxNodeParamControls(_ node: FxNode, _ params: FxParams, _ p: AfxParam, key: String, update: @escaping (FxParams) -> Void) -> [InspectorRow] {
        guard let d = p.def else {
            let s = AudioFxProfiles.strength(node.type, params: params)
            let fmt: (Double) -> String = { String(format: "%.2f", $0) }
            let set: (Double) -> Void = { v in update(AudioFxProfiles.apply(node.type, strength: (Swift.max(0, Swift.min(1, v)) * 100).rounded() / 100, params: params)) }
            return Self.afxParamControls(key: key, label: p.label, position: s, min: 0, max: 1, display: fmt(s), format: fmt, atDefault: s == 0.5,
                                         commitPosition: set, commitText: { t in if let v = PanelFormat.parse(t) { set(v) } }, reset: { set(0.5) })
        }
        switch d {
        case let .number(_, _, _, lo, hi, step, dv, scale, _):
            let v = params.num(p.key)
            let log = scale == .log && lo > 0
            let toPos: (Double) -> Double = { x in log ? lo + (Foundation.log(x) - Foundation.log(lo)) / (Foundation.log(hi) - Foundation.log(lo)) * (hi - lo) : x }
            let fromPos: (Double) -> Double = { x in log ? exp(Foundation.log(lo) + (x - lo) / (hi - lo) * (Foundation.log(hi) - Foundation.log(lo))) : x }
            let dec = Self.afxDecimals(step)
            let show: (Double) -> String = { String(format: "%.\(dec)f", $0) }
            let set: (Double) -> Void = { x in
                var n = params; let c = Swift.max(lo, Swift.min(hi, x))
                n[p.key] = .number((c / step).rounded() * step == c ? c : jsRoundTo(c, dec + 1)); update(n)
            }
            return Self.afxParamControls(key: key, label: p.label, position: toPos(v), min: lo, max: hi, display: show(v),
                                         format: { show(fromPos($0)) }, atDefault: v == dv,
                                         commitPosition: { set(fromPos($0)) }, commitText: { t in if let x = PanelFormat.parse(t) { set(x) } },
                                         reset: { set(dv) })
        case let .enumeration(_, _, options, dv):
            let cur = params[p.key]?.string ?? dv
            let idx = options.firstIndex { $0.value == cur } ?? 0
            let set: (String) -> Void = { s in var n = params; n[p.key] = .string(s); update(n) }
            return [.init(.buttons([.init(key: key, label: options[idx].label, style: .muted) { set(options[(idx + 1) % options.count].value) }])),
                    .init(.number(.init(key: key, label: p.label, text: options[idx].label, tier: cur == dv ? .default : .explicitCustom,
                                        commit: { t in if let o = options.first(where: { $0.label == t || $0.value == t }) { set(o.value) } },
                                        reset: { set(dv) })))]
        }
    }

    func afxNodeParamDraw(_ c: CanvasContext, _ r: CanvasRect, _ node: FxNode, _ params: FxParams, _ p: AfxParam, key: String, enabled: Bool, alpha: Double) {
        guard let d = p.def else {
            let s = AudioFxProfiles.strength(node.type, params: params)
            afxParamRowDraw(c, r, key: key, label: p.label, position: s, display: String(format: "%.2f", s), unit: "", atDefault: s == 0.5,
                            enabled: enabled, alpha: alpha, format: { String(format: "%.2f", $0) }, min: 0, max: 1)
            return
        }
        switch d {
        case let .number(_, _, unit, lo, hi, step, dv, scale, _):
            let v = params.num(p.key)
            let log = scale == .log && lo > 0
            let toPos: (Double) -> Double = { x in log ? lo + (Foundation.log(x) - Foundation.log(lo)) / (Foundation.log(hi) - Foundation.log(lo)) * (hi - lo) : x }
            let fromPos: (Double) -> Double = { x in log ? exp(Foundation.log(lo) + (x - lo) / (hi - lo) * (Foundation.log(hi) - Foundation.log(lo))) : x }
            let dec = Self.afxDecimals(step)
            afxParamRowDraw(c, r, key: key, label: p.label, position: toPos(v), display: String(format: "%.\(dec)f", v), unit: unit,
                            atDefault: v == dv, enabled: enabled, alpha: alpha, format: { String(format: "%.\(dec)f", fromPos($0)) }, min: lo, max: hi)
        case let .enumeration(_, _, options, dv):
            // The enum row: name, a `bg-panel-surface` mono 10 select filling the row, the reset.
            let cur = params[p.key]?.string ?? dv
            let label = options.first { $0.value == cur }?.label ?? cur
            PanelDraw.text(c, p.label, in: CanvasRect(x: r.x, y: r.midY - 7.5, width: 86, height: 15), font: PanelTheme.font(10),
                           color: PanelTheme.text2.withAlpha(alpha))
            let reset = CanvasRect(x: r.maxX - 20, y: r.midY - 10, width: 20, height: 20)
            let resetOn = enabled && cur != dv
            PanelIcon.reset.draw(c, in: CanvasRect(x: reset.midX - 5.5, y: reset.midY - 5.5, width: 11, height: 11),
                                 color: (resetOn && hovered == .reset(key) ? PanelTheme.text0 : PanelTheme.text2).withAlpha(alpha * (resetOn ? 1 : 0.4)))
            if resetOn { addHit(reset, .reset(key)) }
            let box = CanvasRect(x: r.x + 94, y: r.midY - 9.5, width: Swift.max(0, reset.x - 8 - (r.x + 94)), height: 19)
            c.fillRoundedRect(box, radius: 3, PanelTheme.panelSurface.withAlpha(alpha))
            PanelDraw.text(c, label, in: CanvasRect(x: box.x + 4, y: box.y + 2, width: box.width - 18, height: 15), font: PanelTheme.mono(10),
                           color: PanelTheme.text0.withAlpha(alpha))
            PanelIcon.groupCaretDown.draw(c, in: CanvasRect(x: box.maxX - 13, y: box.midY - 5, width: 10, height: 10), color: PanelTheme.text2.withAlpha(alpha))
            if enabled { addHit(box, .button(key)) }
        }
    }

    // MARK: Shelves (FxPresetMenu, FxAddMenu) and the section buttons

    static let presetItemH = 36.5

    /// FxPresetMenu: `space-y-1.5 rounded-[4px] border p-1.5`, a shelf per family (mono 9 caps label), each preset a
    /// `bg-panel-surface py-1 pl-1.5` button: the complaint it answers (10px), then "Name · N effects" (mono 9 text-2).
    func afxPresetMenu(_ chain: FxChain, write: @escaping (FxChain) -> Void) -> InspectorRow {
        let fams: [(label: String, presets: [FxPreset])] = AudioFxPresets.families.map { f in
            (["voice": "Voice", "repair": "Fix", "character": "Character", "space": "Space"][f] ?? f.capitalized, AudioFxPresets.byFamily(f))
        }.filter { !$0.presets.isEmpty }
        var h = 2 + 12.0
        for (k, f) in fams.enumerated() { h += (k > 0 ? 6 : 0) + 13.5 + Double(f.presets.count) * (2 + Self.presetItemH) }
        return .init(.custom(InspectorCustomRow(id: "afx:presets", height: h, draw: { [weak self] c, r, _ in
            guard let self else { return }
            c.strokeRoundedRect(r.snapped.insetBy(0.5), radius: 4, PanelTheme.panelBorderInput, width: 1)
            var y = r.y + 7
            let x = r.x + 7, w = r.width - 14
            for (k, f) in fams.enumerated() {
                if k > 0 { y += 6 }
                PanelDraw.tracked(c, f.label.uppercased(), in: CanvasRect(x: x, y: y, width: w, height: 13.5), font: PanelTheme.mono(9), tracking: 0.225, color: PanelTheme.text2)
                y += 13.5
                for p in f.presets {
                    y += 2
                    let item = CanvasRect(x: x, y: y, width: w, height: Self.presetItemH)
                    let hot = self.hovered == .button("preset:\(p.id)")
                    c.fillRoundedRect(item, radius: 3, PanelTheme.panelSurface)
                    PanelDraw.text(c, AudioFxCopy.presetProblem[p.id] ?? p.description, in: CanvasRect(x: item.x + 6, y: item.y + 4, width: item.width - 6 - 32, height: 15),
                                   font: PanelTheme.font(10), color: hot ? PanelTheme.text0 : PanelTheme.text1)
                    let n = p.nodes.count
                    PanelDraw.text(c, "\(p.label) · \(n) effect\(n == 1 ? "" : "s")", in: CanvasRect(x: item.x + 6, y: item.y + 19, width: item.width - 6 - 32, height: 13.5),
                                   font: PanelTheme.mono(9), color: PanelTheme.text2)
                    self.addHit(item, .button("preset:\(p.id)"))
                    y += Self.presetItemH
                }
            }
        })))
    }

    /// FxAddMenu: Tone, then the jobs standing in for `peaking` and every other registry effect by family, as
    /// `bg-panel-surface px-1.5 py-0.5 text-[10px]` chips that wrap.
    func afxAddMenu(_ chain: FxChain, write: @escaping (FxChain) -> Void) -> InspectorRow {
        let groupLabels = ["filter": "Filters", "dynamics": "Dynamics", "nonlinear": "Non-linear", "time": "Time"]
        var groups: [(label: String, chips: [(key: String, label: String)])] = [("Tone", [("eq:add", "Tone")])]
        for g in ["filter", "dynamics", "nonlinear", "time"] {
            var chips: [(String, String)] = AudioFxJobs.all.filter { AudioFx.definition($0.type)?.group == g }.map { ("job:\($0.id)", $0.label) }
            chips += AudioFx.definitions.filter { $0.group == g && !AudioFxJobs.types.contains($0.id) }.map { ("add:\($0.id)", AudioFxCopy.title($0.id)) }
            groups.append((groupLabels[g]!, chips))
        }
        let width = bodyContentWidth - 14
        let charW = 5.6   // 10px UI face, for laying out the wrap before a canvas is at hand
        func layout(_ chips: [(key: String, label: String)], measure: (String) -> Double) -> [(CanvasRect)] {
            var out: [CanvasRect] = [], x = 0.0, y = 0.0
            for chip in chips {
                let w = measure(chip.label) + 12
                if x > 0 && x + w > width { x = 0; y += 19 + 4 }
                out.append(CanvasRect(x: x, y: y, width: w, height: 19)); x += w + 4
            }
            return out
        }
        var h = 2 + 12.0
        for (k, g) in groups.enumerated() {
            let rects = layout(g.chips) { Double($0.count) * charW }
            h += (k > 0 ? 6 : 0) + 13.5 + 4 + (rects.last.map { $0.maxY } ?? 0)
        }
        return .init(.custom(InspectorCustomRow(id: "afx:add", height: h, draw: { [weak self] c, r, _ in
            guard let self else { return }
            c.strokeRoundedRect(r.snapped.insetBy(0.5), radius: 4, PanelTheme.panelBorderInput, width: 1)
            var y = r.y + 7
            let x = r.x + 7
            for (k, g) in groups.enumerated() {
                if k > 0 { y += 6 }
                PanelDraw.tracked(c, g.label.uppercased(), in: CanvasRect(x: x, y: y, width: width, height: 13.5), font: PanelTheme.mono(9), tracking: 0.225, color: PanelTheme.text2)
                y += 13.5 + 4
                let rects = layout(g.chips) { Double($0.count) * charW }
                for (chip, cr) in zip(g.chips, rects) {
                    let rr = CanvasRect(x: x + cr.x, y: y + cr.y, width: cr.width, height: cr.height)
                    c.fillRoundedRect(rr, radius: 3, PanelTheme.panelSurface)
                    PanelDraw.text(c, chip.label, in: CanvasRect(x: rr.x + 6, y: rr.y + 2, width: rr.width - 12 + 4, height: 15), font: PanelTheme.font(10),
                                   color: self.hovered == .button(chip.key) ? PanelTheme.text0 : PanelTheme.text1)
                    self.addHit(rr, .button(chip.key))
                }
                y += rects.last.map { $0.maxY } ?? 0
            }
        })))
    }

    /// The section's two buttons (`flex flex-col gap-1`): "Presets" (`w-full rounded-[4px] border border-panel-text-0
    /// py-1.5 text-[11px] font-semibold`) and "+ effect" (`self-end px-1 text-[10px] text-panel-text-2`), each
    /// reading "Close" while its shelf is open. The row also carries every shelf pick and the scripted Clear.
    func afxButtons(_ chain: FxChain, ui: AudioFxUIState, write: @escaping (FxChain) -> Void) -> InspectorRow {
        var picks: [InspectorRow.Button] = [
            .init(key: "fx:presets", label: ui.menu == .presets ? "Close" : "Presets", style: .muted) { [weak self] in
                guard let self else { return }
                self.audioFxUI.menu = self.audioFxUI.menu == .presets ? .none : .presets; self.onEdited?()
            },
            .init(key: "fx:add", label: ui.menu == .add ? "Close" : "+ effect", style: .muted) { [weak self] in
                guard let self else { return }
                self.audioFxUI.menu = self.audioFxUI.menu == .add ? .none : .add; self.onEdited?()
            },
            .init(key: "fx:clear", label: "Clear", style: .muted) { [weak self] in self?.audioFxUI.openNode = nil; write(FxChain()) },
        ]
        for p in AudioFxPresets.all {
            picks.append(.init(key: "preset:\(p.id)", label: p.label, style: .muted) { [weak self] in
                let next = AudioFxPresets.apply(chain, p)
                self?.audioFxUI.openNode = next.nodes.firstIndex { $0.fromPreset == p.id }
                self?.audioFxUI.menu = .none
                write(next)
            })
        }
        picks.append(.init(key: "eq:add", label: "Tone", style: .muted) { [weak self] in
            let (next, eqId) = AudioEq.add(chain)
            self?.audioFxUI.openEq = eqId; self?.audioFxUI.menu = .none
            write(next)
        })
        for job in AudioFxJobs.all {
            picks.append(.init(key: "job:\(job.id)", label: job.label, style: .muted) { [weak self] in
                self?.audioFxUI.openNode = chain.nodes.count; self?.audioFxUI.menu = .none
                write(FxChain(nodes: chain.nodes + [AudioFxJobs.node(job, joining: chain)]))
            })
        }
        for d in AudioFx.definitions where !AudioFxJobs.types.contains(d.id) {
            picks.append(.init(key: "add:\(d.id)", label: AudioFxCopy.title(d.id), style: .muted) { [weak self] in
                self?.audioFxUI.openNode = chain.nodes.count; self?.audioFxUI.menu = .none
                write(FxChain(nodes: chain.nodes + [AudioFxJobs.effectNode(d.id, joining: chain)]))
            })
        }
        let presetsLabel = ui.menu == .presets ? "Close" : "Presets", addLabel = ui.menu == .add ? "Close" : "+ effect"
        return .init(.custom(InspectorCustomRow(id: "afx:buttons", height: 31.5 + PanelTheme.minTarget, draw: { [weak self] c, r, _ in
            guard let self else { return }
            let pr = CanvasRect(x: r.x, y: r.y, width: r.width, height: 31.5).snapped
            let hot = self.hovered == .button("fx:presets")
            c.strokeRoundedRect(pr.insetBy(0.5), radius: 4, PanelTheme.text0, width: 1)
            if hot { c.fillRoundedRect(pr.insetBy(1), radius: 3, PanelTheme.white.withAlpha(0.06)) }
            PanelDraw.text(c, presetsLabel, in: CanvasRect(x: pr.x, y: pr.midY - 8.25, width: pr.width, height: 16.5), font: PanelTheme.font(11, .semibold),
                           color: PanelTheme.text0, align: .center)
            self.addHit(pr, .button("fx:presets"))
            let w = c.measureText(addLabel, font: PanelTheme.font(10)).width + 8
            let ar = CanvasRect(x: r.maxX - w, y: pr.maxY + 4, width: w, height: 15)
            PanelDraw.text(c, addLabel, in: CanvasRect(x: ar.x + 4, y: ar.y, width: w - 8 + 1, height: 15), font: PanelTheme.font(10),
                           color: self.hovered == .button("fx:add") ? PanelTheme.text0 : PanelTheme.text2)
            self.addHit(CanvasRect(x: ar.x, y: pr.maxY, width: ar.width, height: PanelTheme.minTarget), .button("fx:add"))
        })), controls: [.init(.buttons(picks))])
    }
}
