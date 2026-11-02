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
// The caption on screen at a time (`sequence.captions`): the cue's lines laid out by `nativeCaptionLayout` and handed to the
// ordinary text painter as a plate layer and a text layer, so a caption takes the same outline and shadow path as a text clip.
import Foundation
import MpvfxCanvas
import MpvfxShared

public extension PreviewComposition {
    /// The cue covering `time`: the one with `startMs <= time < endMs`, the time taken at the start of its frame.
    func captionCue(at time: Double) -> NativeCaptionCue? {
        guard let track = captions else { return nil }
        let ms = Double(frameIndex(at: time)) / fps * 1000
        return track.cues.first { Double($0.startMs) <= ms + 1e-6 && ms + 1e-6 < Double($0.endMs) }
    }

    /// Where the cue's text lands in this composition's frame, or nil without a cue at `time`. `measure(text, font)` is the
    /// width in px of one line at the font's size.
    func captionLayout(at time: Double, measure: (String, CanvasFont) -> Double) -> NativeCaptionLayout? {
        guard let cue = captionCue(at: time) else { return nil }
        return captionLayout(for: cue, measure: measure)
    }

    func captionLayout(for cue: NativeCaptionCue, measure: (String, CanvasFont) -> Double) -> NativeCaptionLayout {
        let look = captions?.look?.isSupported == false ? nil : captions?.look
        let resolved = look ?? NativeCaptionLook()
        return nativeCaptionLayout(text: cue.text, look: look, position: cue.position, frameWidth: canvas.width,
                                   frameHeight: canvas.height) { text, size in
            measure(text, Self.captionFont(resolved, size: size))
        }
    }

    /// The layers to paint above the picture at `time`, bottom first: the plate (when the look has one), then the text.
    func captionLayers(at time: Double, measure: (String, CanvasFont) -> Double) -> [PreviewLayer] {
        guard let cue = captionCue(at: time) else { return [] }
        let look = captions?.look?.isSupported == false ? nil : captions?.look
        let resolved = look ?? NativeCaptionLook()
        let layout = captionLayout(for: cue, measure: measure)
        let start = Double(cue.startMs) / 1000, end = Double(cue.endMs) / 1000
        var layers: [PreviewLayer] = []
        if let plate = layout.plateRect, let color = resolved.plate?.color {
            var layer = PreviewLayer(clipId: "caption-plate:\(cue.id)", source: "", kind: .generator, start: start, end: end, sourceIn: 0,
                                     box: CanvasRect(x: plate.x, y: plate.y, width: plate.width, height: plate.height))
            layer.generator = NativeFill(kind: "color", color: color)
            layers.append(layer)
        }
        // The painter wraps again at the box width, so the box gets slack and the lines are already broken.
        let slack = layout.fontSize * 0.25
        let box = CanvasRect(x: layout.textRect.x - slack, y: layout.textRect.y, width: layout.textRect.width + 2 * slack,
                             height: layout.textRect.height)
        var layer = PreviewLayer(clipId: "caption:\(cue.id)", source: "", kind: .text, start: start, end: end, sourceIn: 0, box: box)
        layer.text = NativeClipText(content: layout.lines.joined(separator: "\n"), fontFamily: resolved.resolvedFontFamily,
                                    fontSize: layout.fontSize, fontWeight: resolved.resolvedWeight, color: resolved.resolvedColor,
                                    align: "center", lineHeight: NativeClipText.normalLineHeight, look: Self.captionTextLook(resolved, canvas: canvas))
        layers.append(layer)
        return layers
    }

    private static func captionFont(_ look: NativeCaptionLook, size: Double) -> CanvasFont {
        CanvasFont(family: look.resolvedFontFamily, size: size, numericWeight: look.resolvedWeight, italic: false)
    }

    /// The look's outlines and shadow as a text look; their px are given for a 1080 px short edge, so they scale with the frame.
    private static func captionTextLook(_ look: NativeCaptionLook, canvas: CanvasSize) -> NativeTextLook? {
        guard (look.outlines ?? []).isEmpty == false || look.shadow != nil else { return nil }
        let unit = min(canvas.width, canvas.height) / 1080
        let outlines = look.outlines?.map { NativeTextLook.Outline(width: $0.width * unit, color: $0.color, position: $0.position) }
        let shadow = look.shadow.map {
            NativeTextLook.Shadow(x: $0.resolvedX * unit, y: $0.resolvedY * unit, blur: $0.resolvedBlur * unit, color: $0.color)
        }
        return NativeTextLook(outlines: outlines, shadow: shadow)
    }
}
