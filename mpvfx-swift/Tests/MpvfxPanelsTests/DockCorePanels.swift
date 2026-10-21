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
import MpvfxPanels

extension DockRegistry {
    /// The five panels the dock mechanics tests were written against (Media, Preview, Design, Renders, Timeline):
    /// they test splitting, stacking and dragging, which must not change when the editor adds a panel.
    static var corePanels: DockRegistry {
        var r = DockRegistry()
        let ids: Set<String> = [DockPanels.media, DockPanels.preview, DockPanels.inspector, DockPanels.renders, DockPanels.timeline]
        for spec in DockRegistry.editor.specs where ids.contains(spec.id) { try? r.register(spec) }
        return r
    }
}
