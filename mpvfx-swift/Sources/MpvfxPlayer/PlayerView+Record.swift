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
import MpvfxPanels

/// What the stage shows while Record motion is armed: a red outline round the composition and a banner that says
/// what the next press will do (or why it won't record).
public struct RecordOverlay: Equatable {
    public enum State: Equatable { case ready, blocked, recording }
    public var state: State
    public var message: String
    /// Seconds into the take (recording only).
    public var elapsed: Double
    public init(state: State, message: String, elapsed: Double = 0) { self.state = state; self.message = message; self.elapsed = elapsed }

    /// The banner's lead label: "REC 0:01.2" during a take, else "Record armed".
    public var title: String {
        guard state == .recording else { return "Record armed" }
        let t = max(0, elapsed), m = Int(t / 60), s = t - Double(m) * 60
        return "REC " + String(format: "%d:%04.1f", m, s)
    }
}

extension PlayerView {
    static let recordBannerFont = CanvasFont(size: 12), recordTitleFont = CanvasFont(size: 12, weight: .semibold)

    /// The banner pill, centred at the top of the viewport (view px), or nil when Record is off.
    public func recordBannerRect(in size: CanvasSize, _ c: CanvasContext?) -> CanvasRect? {
        guard let o = recordOverlay else { return nil }
        let v = viewportRect(in: size)
        func width(_ s: String, _ f: CanvasFont) -> Double { c?.measureText(s, font: f).width ?? Double(s.count) * f.size * 0.6 }
        let inner = 12 + 8 + 8 + width(o.title, Self.recordTitleFont) + 12 + width(o.message, Self.recordBannerFont) + 12
        let w = min(max(0, v.width - 24), inner), h = 28.0
        return CanvasRect(x: (v.x + (v.width - w) / 2).rounded(), y: v.y + 10, width: w, height: h)
    }

    /// Red composition outline (2 pt; solid during a take) and the banner.
    func drawRecordOverlay(_ c: CanvasContext, size: CanvasSize, frame: CanvasRect) {
        guard let o = recordOverlay, let r = recordBannerRect(in: size, c) else { return }
        let red = PanelTheme.red500
        let pulse = o.state == .recording ? Self.pulse(now()) : 1
        Self.strokeSquare(c, frame.insetBy(-2), red.withAlpha(o.state == .recording ? 1 : 0.75), width: 2)
        c.fillRoundedRect(r, radius: 8, PanelStyle.neutral900.withAlpha(0.95))
        c.strokeRoundedRect(r.insetBy(0.5), radius: 7.5, o.state == .blocked ? PanelStyle.neutral700 : red, width: 1)
        c.withState {
            c.clip(r)
            let dot = CanvasRect(x: r.x + 12, y: r.y + r.height / 2 - 4, width: 8, height: 8)
            c.fillRoundedRect(dot, radius: 4, red.withAlpha(pulse))
            let titleX = dot.maxX + 8, textY = r.y + 8
            c.drawText(o.title, at: .init(titleX, textY), font: Self.recordTitleFont, color: o.state == .blocked ? PanelStyle.neutral200 : PanelTheme.red400)
            let msgX = titleX + c.measureText(o.title, font: Self.recordTitleFont).width + 12
            c.drawText(o.message, at: .init(msgX, textY), font: Self.recordBannerFont, color: PanelStyle.neutral200)
        }
    }
}
