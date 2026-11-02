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

/// The stage eyedropper's state (issue #300): waiting for one click on the selected layer.
struct StageEyedropperSession {
    var clipId: String
    /// Called with the clip id and the click's place on the layer's visible box, 0…1 across each side.
    var onPick: (String, CanvasPoint) -> Void
    /// Called once when the mode ends, picked or not (the inspector's button goes back to idle).
    var onEnd: (() -> Void)?
}

extension PlayerController {
    /// Whether the stage is waiting for an eyedropper click.
    public var eyedropperActive: Bool { eyedropper != nil }

    /// Waits for one click on the selected layer. Needs exactly one selected, unlocked layer; false when it cannot start.
    /// `onPick` gets the clip id and the click's place on the layer's visible box, 0...1 across each side.
    @discardableResult
    public func startEyedropper(onEnd: (() -> Void)? = nil, onPick: @escaping (_ clipId: String, _ unit: CanvasPoint) -> Void) -> Bool {
        guard view.selectedIds.count == 1, let e = selected, !e.locked else { return false }
        endEyedropper()
        eyedropper = StageEyedropperSession(clipId: e.id, onPick: onPick, onEnd: onEnd)
        needsDisplay?()
        return true
    }

    /// Ends the mode with nothing picked.
    public func cancelEyedropper() { endEyedropper() }

    /// Esc: ends the mode. False when it was not active.
    func eyedropperEscape() -> Bool {
        guard eyedropper != nil else { return false }
        endEyedropper()
        return true
    }

    /// A stage press while the mode is active: inside the selected layer's box it picks, anywhere else it ends the
    /// mode. Always true then, so the press starts no move and selects nothing.
    func eyedropperPress(at p: CanvasPoint) -> Bool {
        guard let session = eyedropper else { return false }
        let ve = selected.flatMap { $0.id == session.clipId ? view.chromeElement($0, in: size) : nil }
        endEyedropper()
        if let ve {
            let u = TransformBox.unit(ve, of: p)
            if u.x >= 0, u.x <= 1, u.y >= 0, u.y <= 1 { session.onPick(session.clipId, u) }
        }
        return true
    }

    private func endEyedropper() {
        guard let session = eyedropper else { return }
        eyedropper = nil
        session.onEnd?()
        needsDisplay?()
    }
}
