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

/// What a frame source may need beyond the time: the display's pixel density and the transport state.
public struct FrameDrawContext: Equatable, Sendable {
    /// Device pixels per view point (2 on Retina), times the interface size (issue #106: the shell's `scale(k, k)`
    /// reaches it through `CanvasContext.deviceScale`). Decoders size frames to `rect × backingScale`.
    public var backingScale: Double
    public var isPlaying: Bool
    /// Signed playback speed (negative while playing backward).
    public var speed: Double
    /// Stage elements a gesture is editing right now (drag, crop tool, recording, nudge). Only these override the
    /// document's box, rotation and crop; every other layer is drawn from the document as evaluated at this time,
    /// so inspector edits show at once. nil: every element passed in is live (callers without a controller).
    public var liveElementIds: Set<String>?
    /// Selected clip shown raw left of the preview-only compare divider.
    public var compareClipId: String?
    public var comparePosition: Double
    public init(backingScale: Double = 1, isPlaying: Bool = false, speed: Double = 1, liveElementIds: Set<String>? = nil,
                compareClipId: String? = nil, comparePosition: Double = 0.5) {
        self.backingScale = backingScale; self.isPlaying = isPlaying; self.speed = speed; self.liveElementIds = liveElementIds
        self.compareClipId = compareClipId; self.comparePosition = comparePosition
    }
}

/// Source of preview frames.
public protocol FrameSource: AnyObject {
    /// Paint the composition frame at `time` into `rect` (the letterboxed canvas frame).
    func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement])
    func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement], context: FrameDrawContext)
}

public extension FrameSource {
    func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement], context: FrameDrawContext) {
        draw(c, in: rect, time: time, elements: elements)
    }
}

/// An element on the canvas, in composition pixels (NativeCanvas width × height).
public struct StageElement: Equatable, Sendable {
    public var id: String; public var name: String; public var rect: CanvasRect; public var kind: TimelineClipKind
    /// Degrees, clockwise, about the rect centre.
    public var rotation: Double
    /// Non-destructive insets from each edge (top, right, bottom, left), in element pixels.
    public var crop: CropInsets
    /// Live overrides while a gesture is being recorded (nil: the document's value).
    public var opacity: Double?
    public var scale: Double?
    /// On a locked track: the stage selects it but does not move or transform it.
    public var locked = false
    public init(id: String, name: String, rect: CanvasRect, kind: TimelineClipKind, rotation: Double = 0, crop: CropInsets = .zero,
                opacity: Double? = nil, scale: Double? = nil, locked: Bool = false) {
        self.id = id; self.name = name; self.rect = rect; self.kind = kind; self.rotation = rotation; self.crop = crop
        self.opacity = opacity; self.scale = scale; self.locked = locked
    }
    public var centre: CanvasPoint { CanvasPoint(rect.x + rect.width / 2, rect.y + rect.height / 2) }
    /// Visible (cropped) rect in unrotated element space.
    public var visibleRect: CanvasRect {
        CanvasRect(x: rect.x + crop.left, y: rect.y + crop.top,
                   width: max(1, rect.width - crop.left - crop.right), height: max(1, rect.height - crop.top - crop.bottom))
    }
}

public struct CropInsets: Equatable, Sendable {
    public var top = 0.0, right = 0.0, bottom = 0.0, left = 0.0
    public init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0) { self.top = top; self.right = right; self.bottom = bottom; self.left = left }
    public static let zero = CropInsets()
    public var isZero: Bool { self == .zero }
    /// scaleCropInsetsForBoxResize: each axis follows its own box scale.
    public func scaled(from: CanvasSize, to: CanvasSize) -> CropInsets {
        let sx = from.width > 0 ? to.width / from.width : 1, sy = from.height > 0 ? to.height / from.height : 1
        return CropInsets(top: max(0, top * sy), right: max(0, right * sx), bottom: max(0, bottom * sy), left: max(0, left * sx))
    }
}

public enum CropEdge: CaseIterable, Equatable, Sendable { case top, right, bottom, left }

/// Placeholder: canvas background + labelled boxes per active element + timecode.
public final class PlaceholderFrameSource: FrameSource {
    public let background: CanvasColor
    public init(background: CanvasColor = CanvasColor(ThemeTokens.stageDefaultBackground)) { self.background = background }
    public func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement]) {
        c.fillRect(rect, background)
        Self.drawBoxes(c, elements)
        let label = "placeholder frame · \(TimelineRuler.label(time, duration: 0, major: 0.05))"
        let m = c.measureText(label, font: .mono(11))
        c.drawText(label, at: .init(rect.x + (rect.width - m.width) / 2, rect.maxY - 24), font: .mono(11), color: CanvasColor(ThemeTokens.stageInk.alpha(0.35)))
    }

    /// Tinted, labelled box per element (view coordinates).
    public static func drawBoxes(_ c: CanvasContext, _ elements: [StageElement]) {
        for (i, e) in elements.enumerated() {
            let hue: [CanvasColor] = [ThemeTokens.mintPair.dark.alpha(0.10), ThemeTokens.blue500Pair.dark.alpha(0.12), ThemeTokens.purple500Pair.dark.alpha(0.12)].map { CanvasColor($0) }
            c.fillRect(e.rect, hue[i % hue.count])
            c.drawText(e.name, at: .init(e.rect.x + 12, e.rect.y + 12), font: CanvasFont(size: 13, weight: .medium), color: CanvasColor(ThemeTokens.stageInk.alpha(0.55)))
        }
    }
}
