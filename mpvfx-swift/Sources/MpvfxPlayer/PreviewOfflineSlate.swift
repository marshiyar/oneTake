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
import MpvfxTimeline

/// The slate the stage draws in place of a clip whose media file is missing (issue #102): a dark hatched card in the
/// clip's box with "Media offline" and the file name, so a missing file reads as missing instead of as a blank.
extension PreviewPainter {
    // Stage content, not chrome: the slate keeps the dark palette in both themes, like the stage background.
    static var offlineSlateFill: CanvasColor { CanvasColor(ThemeTokens.stageDefaultBackground) }
    static var offlineSlateHatch: CanvasColor { CanvasColor(ThemeTokens.red500Pair.dark.alpha(0.22)) }
    static var offlineSlateTitle: CanvasColor { CanvasColor(ThemeTokens.red400Pair.dark) }
    static var offlineSlateText: CanvasColor { CanvasColor(ThemeTokens.whitePair.dark.alpha(0.85)) }

    /// Draws an offline layer (kind .offline) where its picture would be: the layer's scale and rotation about its box
    /// centre, or its 3D transform (depth, tilt, lens) through the same projection as a decoded picture.
    public static func drawOffline(_ layer: PreviewLayer, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
        guard layer.isVisible else { return }
        let box = toView(layer.box, frame: frame, scale: s)
        let slate = {
            c.withState {
                c.fill(.rect(box), offlineSlateFill.withAlpha(layer.opacity))
                c.clip(box)
                drawHatch(c, in: box, color: offlineSlateHatch.withAlpha(offlineSlateHatch.a * layer.opacity))
                drawSlateText(c, layer.offlineFileName ?? "", in: box, opacity: layer.opacity)
            }
        }
        guard layer.transform3D.isIdentity else {
            draw3D(layer, layer.transform3D, box: box, frame: frame, scale: s, on: c, content: slate)
            return
        }
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2
        c.withState {
            c.translate(cx, cy)
            if layer.rotation != 0 { c.rotate(layer.rotation * .pi / 180) }
            if layer.scaleX != 1 || layer.scaleY != 1 { c.scale(layer.scaleX, layer.scaleY) }
            c.translate(-cx, -cy)
            slate()
        }
    }

    /// 45° stripes every 16 px across `box` (the caller clips to it).
    static func drawHatch(_ c: CanvasContext, in box: CanvasRect, color: CanvasColor, step: Double = 16) {
        var p = CanvasPath()
        var x = box.x - box.height
        while x < box.maxX {
            p.move(to: CanvasPoint(x, box.maxY)); p.line(to: CanvasPoint(x + box.height, box.y))
            x += step
        }
        c.stroke(p, color, StrokeStyle(width: step / 4))
    }

    /// "Media offline" over the file name, centred in `box`, sized to the box.
    static func drawSlateText(_ c: CanvasContext, _ fileName: String, in box: CanvasRect, opacity: Double) {
        let titleFont = CanvasFont(size: max(9, min(18, box.height / 8)), weight: .semibold)
        let nameFont = CanvasFont(size: max(8, min(14, box.height / 10)))
        let gap = nameFont.size / 2
        let top = box.y + (box.height - titleFont.size - gap - nameFont.size) / 2
        let title = "Media offline"
        let tw = c.measureText(title, font: titleFont).width
        c.drawText(title, at: CanvasPoint(box.x + (box.width - tw) / 2, top), font: titleFont, color: offlineSlateTitle.withAlpha(opacity))
        guard !fileName.isEmpty else { return }
        let nw = min(c.measureText(fileName, font: nameFont).width, box.width - 8)
        c.drawText(fileName, at: CanvasPoint(box.x + max(4, (box.width - nw) / 2), top + titleFont.size + gap), font: nameFont,
                   color: offlineSlateText.withAlpha(opacity))
    }
}
