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

/// The Record motion control at the left of the tools bar: a 28 pt button (the bar's icon-button height, over the
/// 24 pt minimum target) whose width fits its longest label, so it never shifts while its state changes.
extension PreviewToolbar {
    static let recordLabels: [Recording: String] = [.idle: "Record", .armed: "Armed", .recording: "Recording"]
    static let recordTips: [Recording: String] = [.idle: "Record motion (R)", .armed: "Disarm Record (R or Esc)",
                                                  .recording: "Release to finish (Esc cancels)"]
    static let recordHeight = 28.0

    public var recordLabel: String { Self.recordLabels[recording] ?? "Record" }
    public var recordTip: String { Self.recordTips[recording] ?? "Record motion (R)" }

    /// Left-aligned at the bar's padding, vertically centred like the snap and grid buttons.
    func recordRect(_ c: CanvasContext?) -> CanvasRect {
        let text = Self.recordLabels.values.map { textWidth(c, $0, Self.label) }.max() ?? 0
        let w = (8 + 8 + 6 + text + 10).rounded(.up)
        return CanvasRect(x: Self.paddingX, y: (Self.height - Self.recordHeight) / 2, width: w, height: Self.recordHeight)
    }

    /// Off: the bar's neutral wash. Armed: a red-tinted fill with a red border. Recording: solid red.
    func drawRecord(_ c: CanvasContext, _ r: CanvasRect) {
        let hov = hovered == .record, red = Self.red500, white = PanelTheme.white
        let onRed = CanvasColor(r: 1, g: 1, b: 1)   // white on red in both modes
        switch recording {
        case .idle: c.fillRoundedRect(r, radius: 6, Self.wash(hov ? 0.6 : 0.4))
        case .armed:
            c.fillRoundedRect(r, radius: 6, red.withAlpha(hov ? 0.28 : 0.18))
            c.strokeRoundedRect(r.insetBy(0.5), radius: 5.5, red, width: 1)
        case .recording: c.fillRoundedRect(r, radius: 6, red)
        }
        let dot = CanvasRect(x: r.x + 8, y: r.y + (r.height - 8) / 2, width: 8, height: 8)
        c.fillRoundedRect(dot, radius: recording == .recording ? 2 : 4, recording == .recording ? onRed : red)
        let ink: CanvasColor
        switch recording {
        case .idle: ink = white.withAlpha(hov ? 1 : 0.8)
        case .armed: ink = PanelTheme.red400
        case .recording: ink = onRed
        }
        c.drawText(recordLabel, at: .init(dot.maxX + 6, r.y + (r.height - 11) / 2), font: Self.label, color: ink)
    }

    /// The hover tip under the control: what a click does and its key.
    func drawRecordTip(_ c: CanvasContext, _ r: CanvasRect) {
        let font = CanvasFont(size: 11), tip = recordTip
        let w = textWidth(c, tip, font) + 16, tr = CanvasRect(x: r.x, y: r.maxY + 6, width: w, height: 22)
        c.fillRoundedRect(tr, radius: 4, PanelStyle.neutral900.withAlpha(0.97))
        c.strokeRoundedRect(tr.insetBy(0.5), radius: 3.5, PanelStyle.neutral700, width: 1)
        c.drawText(tip, at: .init(tr.x + 8, tr.y + 5), font: font, color: PanelStyle.neutral200)
    }
}
