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
import MpvfxPlayer
import MpvfxPanels

extension SessionPanels {
    /// The colour picker's eyedropper (issue #189): the composited stage frame at the playhead, painted as export
    /// paints it.
    func wireStageFrame(_ inspector: InspectorPanel, _ renderer: PresetPreviewRenderer) {
        inspector.stageFrame = { [weak inspector] w, h in
            guard let inspector else { return .unavailable }
            return PresetPreviewState(renderer.programFrame(time: inspector.time, pixelWidth: w, pixelHeight: h))
        }
    }
}

extension PresetPreviewState {
    /// The panels' view of a renderer state (the panels cannot import the player).
    init(_ state: PresetPreviewRenderer.State) {
        switch state {
        case .ready(let img): self = .ready(img)
        case .rendering: self = .rendering
        case .unavailable: self = .unavailable
        }
    }
}
