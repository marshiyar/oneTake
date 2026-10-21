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

/// What the pointer is over on the selected element's transform box.
public enum TransformHit: Equatable, Sendable {
    case handle(TransformHandle)
    /// Just outside a corner: dragging there rotates.
    case rotateZone(TransformHandle)
    case rotateChip
    case anchor
    case body
}

/// The pointer shape the stage asks its host for. There is no system rotate cursor on macOS, Windows or GTK, so
/// the stage also draws a rotate glyph beside the pointer while `.rotate` is shown.
public enum StageCursor: Equatable, Sendable {
    case arrow
    case move
    /// A two-way resize arrow along `degrees` on screen (0 is horizontal, 90 vertical; the element's rotation added).
    case resize(degrees: Double)
    case rotate
    case anchor
    /// Over a locked layer: it can be selected, not transformed.
    case notAllowed
}

/// The live readout drawn beside the cursor while a transform drag runs (W × H, angle, X / Y).
public struct TransformReadout: Equatable, Sendable {
    public var text: String
    public var at: CanvasPoint
    public init(text: String, at: CanvasPoint) { self.text = text; self.at = at }
}

/// Transform-box state the stage draws: the anchor of each element, the hovered and dragged part, the readout and
/// the cursor. The anchor lives on the stage for this session only: the document has no anchor parameter yet, so a
/// rotate or scale about it is written as the position, size and rotation that put the box where it shows.
public struct TransformChrome: Equatable, Sendable {
    /// Anchor per element id in unit coordinates of its visible box (missing: the centre).
    public var anchors: [String: CanvasPoint] = [:]
    public var hover: TransformHit?
    /// The part being dragged (drawn filled).
    public var active: TransformHit?
    public var readout: TransformReadout?
    public var cursor: StageCursor = .arrow
    /// Last pointer position over the stage (view px), where the rotate glyph is drawn.
    public var pointer: CanvasPoint?
    public init() {}

    public func anchor(_ id: String) -> CanvasPoint { anchors[id] ?? TransformBox.centreAnchor }
}

/// Controller-side transform state that is not drawn: callbacks the host sets, the last anchor press (double-click
/// detection) and whether a press landed on a locked layer.
struct TransformSession {
    var commitGroup: (([StageElement]) -> Void)?
    var readoutOrigin: ((StageElement) -> CanvasPoint?)?
    var lastAnchorPress: (id: String, at: Double, point: CanvasPoint)?
    var lockedPress: String?
    var lockedToastShown = false
}
