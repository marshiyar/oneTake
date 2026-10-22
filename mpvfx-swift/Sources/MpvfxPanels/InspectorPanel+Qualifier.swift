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

/// Hue is circular: a low endpoint above the high endpoint selects across red (0°).
/// Only edits constrain values; reading a project never rewrites its authored key.
enum SecondaryQualifier: String, CaseIterable {
    case hue, saturation, luma
    var label: String { rawValue.capitalized }
    var domain: ClosedRange<Double> { self == .hue ? 0...360 : 0...1 }
    var step: Double { self == .hue ? 1 : 0.01 }
    func bounds(_ s: ColorGrading.Secondary) -> (Double, Double) {
        switch self {
        case .hue:
            let lo = Self.wrap(s.hueCenter - s.hueRange), hi = Self.wrap(s.hueCenter + s.hueRange)
            return (lo, s.hueRange >= 180 && lo == 0 ? 360 : hi)
        case .saturation: return (s.satMin, s.satMax)
        case .luma: return (s.lumaMin, s.lumaMax)
        }
    }
    func softness(_ s: ColorGrading.Secondary) -> Double {
        switch self { case .hue: return s.hueSoftness; case .saturation: return s.satSoftness; case .luma: return s.lumaSoftness }
    }
    func setSoftness(_ s: inout ColorGrading.Secondary, _ v: Double) {
        switch self { case .hue: s.hueSoftness = v; case .saturation: s.satSoftness = v; case .luma: s.lumaSoftness = v }
    }
    func editing(_ s: ColorGrading.Secondary, part: Int, value: Double) -> ColorGrading.Secondary {
        guard value.isFinite else { return s }
        var (lo, hi) = bounds(s)
        let v = max(domain.lowerBound, min(domain.upperBound, value))
        if self == .hue {
            if part == 0 { lo = v } else { hi = v }
        } else if part == 0 { lo = min(hi, v) } else { hi = max(lo, v) }
        var next = s
        switch self {
        case .hue:
            let span = hi - lo == 360 ? 360 : Self.wrap(hi - lo)
            next.hueCenter = Self.wrap(lo + span / 2)
            next.hueRange = span / 2
        case .saturation: next.satMin = lo; next.satMax = hi
        case .luma: next.lumaMin = lo; next.lumaMax = hi
        }
        return next
    }
    static func wrap(_ v: Double) -> Double { (v.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
    func text(_ v: Double) -> String { self == .hue ? "\(Int(v.rounded()))°" : "\(Int((v * 100).rounded()))%" }
}

extension InspectorPanel {
    func qualifierRow(_ channel: SecondaryQualifier, secondary: ColorGrading.Secondary,
                      commit: @escaping (ColorGrading.Secondary) -> Void) -> InspectorRow {
        let id = "sec:qualifier:\(channel.rawValue)"
        return .init(.custom(.init(id: id, height: 72, draw: { [weak self] c, r, panel in
            guard let self else { return }
            let s = self.grade.qualifierDraft ?? secondary
            let (lo, hi) = channel.bounds(s)
            PanelDraw.text(c, channel.label, in: CanvasRect(x: r.x, y: r.y, width: 85, height: 16),
                           font: PanelTheme.font(11), color: PanelTheme.text2)
            PanelDraw.text(c, "\(channel.text(lo)) – \(channel.text(hi))", in: CanvasRect(x: r.x + 85, y: r.y, width: r.width - 85, height: 16),
                           font: PanelTheme.mono(11), color: PanelTheme.text1, align: .right)
            let track = CanvasRect(x: r.x + 12, y: r.y + 32, width: max(1, r.width - 24), height: 12)
            self.grade.qualifierTracks[id] = track
            let span = channel.domain.upperBound - channel.domain.lowerBound
            var pixels = [UInt8]()
            for i in 0..<256 {
                let t = Double(i) / 255
                let rgb: (Double, Double, Double)
                switch channel {
                case .hue: rgb = HueWheelImage.hsv(channel.domain.lowerBound + t * span, 1, 1)
                case .saturation: rgb = HueWheelImage.hsv(s.hueCenter, t, 1)
                case .luma: rgb = (t, t, t)
                }
                let value = channel.domain.lowerBound + t * span
                let selected = channel == .hue && s.hueRange >= 180 || (lo <= hi ? value >= lo && value <= hi : value >= lo || value <= hi)
                let brightness = selected ? 1.0 : 0.25
                pixels += [UInt8(rgb.0 * brightness * 255), UInt8(rgb.1 * brightness * 255), UInt8(rgb.2 * brightness * 255), 255]
            }
            c.drawImage(CanvasImage(width: 256, height: 1, rgba: pixels), in: track)
            func x(_ value: Double) -> Double { track.x + max(0, min(1, (value - channel.domain.lowerBound) / span)) * track.width }
            // Separate vertical lanes keep coincident endpoints independently reachable at zero width.
            for (part, value) in [lo, hi].enumerated() {
                let cy = track.midY + (part == 0 ? -12.0 : 12.0)
                let hit = CanvasRect(x: x(value) - 12, y: cy - 12, width: 24, height: 24)
                c.fillRect(CanvasRect(x: x(value) - 1, y: track.y - 2, width: 2, height: track.height + 4), PanelTheme.text0)
                c.fillRoundedRect(CanvasRect(x: x(value) - 5, y: cy - 5, width: 10, height: 10), radius: 2, PanelTheme.panelInput)
                c.stroke(.roundedRect(CanvasRect(x: x(value) - 5, y: cy - 5, width: 10, height: 10), radius: 2),
                         panel.focus.visible && panel.focus.current == .custom(id, part) ? PanelTheme.accent : PanelTheme.text0, StrokeStyle(width: 1))
                panel.addHit(hit, .custom(id, part))
            }
        }, pointer: { [weak self] part, point, phase in
            guard let self else { return }
            guard let track = self.grade.qualifierTracks[id] else { return }
            if phase == 0 {
                let bounds = channel.bounds(secondary)
                self.grade.qualifierGrab = (secondary, point.x, part == 0 ? bounds.0 : bounds.1)
                self.grade.qualifierDraft = secondary
                return
            }
            guard let grab = self.grade.qualifierGrab else { return }
            let value = grab.value + (point.x - grab.x) / max(1, track.width) * (channel.domain.upperBound - channel.domain.lowerBound)
            self.grade.qualifierDraft = abs(point.x - grab.x) <= 0.01 ? grab.secondary : channel.editing(grab.secondary, part: part, value: value)
            if phase == 2, let draft = self.grade.qualifierDraft { self.grade.qualifierDraft = nil; self.grade.qualifierGrab = nil; commit(draft) }
        }, key: { part, key in
            if key.code == .enter || key.code == .space { return true }
            let direction: Double
            switch key.code { case .left, .down: direction = -1; case .right, .up: direction = 1; default: return false }
            let bounds = channel.bounds(secondary)
            let value = (part == 0 ? bounds.0 : bounds.1) + direction * channel.step * (key.shift ? 10 : 1)
            commit(channel.editing(secondary, part: part, value: channel == .hue ? SecondaryQualifier.wrap(value) : value))
            return true
        })))
    }
}
