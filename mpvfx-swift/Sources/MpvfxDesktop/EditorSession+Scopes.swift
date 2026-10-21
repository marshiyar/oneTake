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

/// Host-side wiring of the Grade scopes (issue #80).
extension SessionPanels {
    /// Clip reads the selected clip's own graded frame (PresetPreviewRenderer), Program the composited program frame
    /// (ProgramScopeRenderer), both at the playhead, including during playback. Frames and
    /// scope bitmaps are made off the UI thread; each finished one redraws.
    func wireScopes(_ inspector: InspectorPanel, clip renderer: PresetPreviewRenderer) {
        let program = ProgramScopeRenderer(compositor: session.compositor)
        program.onReady = { [weak self] in self?.uiPost { self?.redraw() } }
        inspector.scopeWorker.onReady = { [weak self] in self?.uiPost { self?.redraw() } }
        // Separate renderer so look matching's sequential source/reference requests cannot supersede the scopes'
        // own pending frame in PresetPreviewRenderer's latest-request slot.
        let matchRenderer = PresetPreviewRenderer(compositor: session.compositor)
        matchRenderer.onReady = { [weak self] in self?.uiPost { self?.redraw() } }
        inspector.matchLookFrame = { clipId, time, w, h in
            Self.panelState(matchRenderer.gradedFrame(clipId: clipId, time: time, pixelWidth: w, pixelHeight: h))
        }
        inspector.scopeFrame = { [weak self, weak inspector] clipId, w, h in
            guard let self, let inspector else { return .unavailable }
            return Self.panelState(renderer.gradedFrame(clipId: clipId, time: self.scopeTime(inspector), pixelWidth: w, pixelHeight: h))
        }
        inspector.programScopeFrame = { [weak self, weak inspector] w, h in
            guard let self, let inspector else { return .unavailable }
            return Self.panelState(program.frame(at: self.scopeTime(inspector), pixelWidth: w, pixelHeight: h))
        }
    }

    /// The composition time the scopes show, including during playback.
    func scopeTime(_ inspector: InspectorPanel) -> Double {
        inspector.time
    }

    /// A renderer's state as the inspector's hooks return it.
    static func panelState(_ state: PresetPreviewRenderer.State) -> PresetPreviewState {
        switch state {
        case .ready(let img): return .ready(img)
        case .rendering: return .rendering
        case .unavailable: return .unavailable
        }
    }
}
