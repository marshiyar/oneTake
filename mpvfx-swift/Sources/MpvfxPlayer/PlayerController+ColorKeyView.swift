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

/// The colour-key preview mode (issue #300): which picture the stage shows of the selected clip (Result, Matte or
/// Source). Preview only: it is never saved and export never reads it.
extension PlayerController {
    /// Shows `mode` for the selected clip (the inspector's view segmented control calls this).
    public func setColorKeyView(_ mode: ColorKeyViewMode) {
        view.colorKeyView = mode
        needsDisplay?()
    }

    /// Whether an Option-press at `p` starts the source hold: the selected layer has an enabled colour key and the press is
    /// not for a transform handle, the rotate chip, the anchor, a mask handle, the crop tool or the eyedropper (which
    /// all keep their Option meaning).
    func holdsColorKeySource(at p: CanvasPoint) -> Bool {
        guard let e = selected, colorKeyActive?(e.id) == true, maskStage.target == nil, eyedropper == nil, !view.cropActive,
              view.viewportRect(in: size).contains(p) else { return false }
        switch transformHit(p, view.chromeElement(e, in: size)) {
        case .body?, nil: return true
        default: return false
        }
    }

    /// Holds the source picture while the Option press is down (wins over `colorKeyView` until released).
    func beginColorKeyHold() {
        view.colorKeyHold = .source
        needsDisplay?()
    }

    /// Releases a held colour-key preview; true when one was held.
    @discardableResult
    func clearColorKeyHold() -> Bool {
        guard view.colorKeyHold != nil else { return false }
        view.colorKeyHold = nil
        needsDisplay?()
        return true
    }
}
