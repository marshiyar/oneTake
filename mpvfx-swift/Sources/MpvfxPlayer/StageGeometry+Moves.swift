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
// The stage element of a clip with moves: the outline and handles sit on the box preview draws.
import Foundation
import MpvfxCanvas
import MpvfxShared

extension StageGeometry {
    /// `e` moved by `o` as PreviewLayer.moved moves the drawn box: rect shifted, rotation added, scale multiplied.
    /// Opacity is left to the layer (the element carries only live gesture overrides).
    public static func moved(_ e: StageElement, by o: NativeMoveOffsets) -> StageElement {
        guard !o.isIdentity else { return e }
        var m = e
        m.rect = CanvasRect(x: e.rect.x + o.dx, y: e.rect.y + o.dy, width: e.rect.width, height: e.rect.height)
        m.rotation = e.rotation + o.rotation
        let k = (e.scale ?? 1) * o.scale
        m.scale = abs(k - 1) < 1e-12 ? nil : k
        return m
    }

    /// The element a gesture on the moved element `e` means for the clip's own values: `moved` undone, so a drag
    /// writes the position the user sees minus what the moves add at that frame.
    public static func unmoved(_ e: StageElement, by o: NativeMoveOffsets) -> StageElement {
        moved(e, by: o.inverted)
    }
}
