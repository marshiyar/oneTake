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

/// The highest gain reduction a meter showed lately, kept for `AudioFxMeterBar.holdSeconds`.
struct AfxPeakHold: Equatable {
    var value: Double
    var at: Double
}

/// Where a meter bar's numbers come from and how they map onto the bar.
enum AudioFxMeterBar {
    static let floorDb = -60.0, reductionRangeDb = 24.0, holdSeconds = 1.0

    /// How full an input or output bar is (-60...0 dBFS across its length).
    static func level(_ db: Double) -> Double { min(1, max(0, (db - floorDb) / -floorDb)) }
    /// How far down a gain-reduction bar hangs (0...-24 dB across its height).
    static func reduction(_ db: Double) -> Double { min(1, max(0, db / reductionRangeDb)) }

    /// The held peak after a new reading: a deeper reading replaces it at once, and it falls back to the live
    /// reading one second after it was set.
    static func held(_ hold: AfxPeakHold?, value: Double, now: Double) -> AfxPeakHold {
        guard let hold, hold.value > value, now - hold.at < holdSeconds else { return AfxPeakHold(value: value, at: now) }
        return hold
    }

    static func readout(_ db: Double) -> String { db <= floorDb ? "-inf" : String(format: "%.1f", db) }
    static func reductionReadout(_ db: Double) -> String { db < 0.05 ? "0.0" : String(format: "-%.1f", db) }
}

extension InspectorPanel {
    /// Height the input and output bars add to a module card.
    static let afxMeterStripH = 30.0
    /// Width kept beside a transfer curve for its gain-reduction bar.
    static let afxReductionBarW = 40.0

    /// The reading for the module at `meterIndex` (its place among the chain's enabled modules) for the sound heard now.
    func afxMeterReading(_ meterIndex: Int?) -> FxMeterReading? {
        guard let meterIndex, let owner = audioFxUI.owner, let snapshot = fxMeterProvider?(owner),
              snapshot.nodes.indices.contains(meterIndex) else { return nil }
        return snapshot.nodes[meterIndex]
    }

    /// A module's place among the enabled modules: what `FxChainProcessor` numbers its meters by (nil: bypassed).
    static func afxMeterIndex(_ chain: FxChain, _ i: Int) -> Int? {
        guard chain.nodes.indices.contains(i), chain.nodes[i].enabled != false else { return nil }
        return chain.nodes[..<i].filter { $0.enabled != false }.count
    }

    /// The input and output bars of a module card: RMS filled, peak as a tick, the peak in dB as a number.
    /// Returns the y below the strip.
    func afxDrawMeterStrip(_ c: CanvasContext, _ card: CanvasRect, y: Double, _ reading: FxMeterReading?, alpha: Double) -> Double {
        let x = card.x + 2 + 6, w = card.width - 3 - 12
        let labelW = 26.0, readoutW = 38.0
        let bar = CanvasRect(x: x + labelW, y: 0, width: Swift.max(0, w - labelW - readoutW - 4), height: 7)
        for (k, row) in [("In", reading?.inputPeakDb, reading?.inputRMSDb), ("Out", reading?.outputPeakDb, reading?.outputRMSDb)].enumerated() {
            let top = y + 2 + Double(k) * 13
            PanelDraw.text(c, row.0, in: CanvasRect(x: x, y: top - 2, width: labelW, height: 12), font: PanelTheme.mono(11),
                           color: PanelTheme.text2.withAlpha(alpha))
            let track = CanvasRect(x: bar.x, y: top + 1, width: bar.width, height: bar.height)
            c.fillRect(track, PanelTheme.panelHover.withAlpha(alpha))
            if let peak = row.1, let rms = row.2 {
                c.fillRect(CanvasRect(x: track.x, y: track.y, width: track.width * AudioFxMeterBar.level(rms), height: track.height),
                           (peak > -1 ? PanelTheme.danger : PanelTheme.accent).withAlpha(0.6 * alpha))
                let tick = track.x + track.width * AudioFxMeterBar.level(peak)
                c.fillRect(CanvasRect(x: Swift.min(tick, track.maxX - 2), y: track.y - 1, width: 2, height: track.height + 2),
                           PanelTheme.text0.withAlpha(alpha))
            }
            PanelDraw.text(c, row.1.map(AudioFxMeterBar.readout) ?? "–", in: CanvasRect(x: track.maxX + 4, y: top - 2, width: readoutW, height: 12),
                           font: PanelTheme.mono(11), color: PanelTheme.text1.withAlpha(alpha), align: .right)
        }
        return y + Self.afxMeterStripH
    }

    /// A compressor, limiter or gate's gain-reduction bar, hanging from 0 to -24 dB down the right of its curve, with the
    /// deepest reading of the last second held as a tick and the live reading as a number under it.
    func afxDrawReductionBar(_ c: CanvasContext, _ rect: CanvasRect, key: String, _ reading: FxMeterReading?, alpha: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let value = reading?.gainReductionDb ?? 0
        let hold = AudioFxMeterBar.held(audioFxUI.reductionHolds[key], value: value, now: now)
        audioFxUI.reductionHolds[key] = hold
        let bar = CanvasRect(x: rect.maxX - 12, y: rect.y + 6, width: 8, height: rect.height - 20)
        c.fillRect(bar, PanelTheme.panelHover.withAlpha(alpha))
        if reading != nil {
            c.fillRect(CanvasRect(x: bar.x, y: bar.y, width: bar.width, height: bar.height * AudioFxMeterBar.reduction(value)),
                       PanelTheme.accent.withAlpha(alpha))
            let tick = bar.y + bar.height * AudioFxMeterBar.reduction(hold.value)
            c.fillRect(CanvasRect(x: bar.x - 2, y: Swift.min(tick, bar.maxY - 2), width: bar.width + 4, height: 2), PanelTheme.text0.withAlpha(alpha))
        }
        PanelDraw.text(c, "GR", in: CanvasRect(x: bar.x - 8, y: rect.y - 6, width: 24, height: 12), font: PanelTheme.mono(11),
                       color: PanelTheme.text2.withAlpha(alpha), align: .center)
        PanelDraw.text(c, reading == nil ? "–" : AudioFxMeterBar.reductionReadout(value),
                       in: CanvasRect(x: bar.x - 22, y: bar.maxY + 1, width: 44, height: 12), font: PanelTheme.mono(11),
                       color: PanelTheme.text1.withAlpha(alpha), align: .center)
    }
}
