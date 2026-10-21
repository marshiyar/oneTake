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
// Narration from text on the timeline: a planned narration edit (MpvfxShared `NativeNarrationPlan`) committed as one
// undo step. Undo restores the document before it, so the clip (and, for a re-speak, the earlier WAV) comes back.
import Foundation
import MpvfxShared

public extension TimelineEditor {
    /// Places the clip of `planNativeNarrationInsert` as one undoable edit ("Add narration").
    @discardableResult
    func addNarration(_ plan: NativeNarrationPlan) -> Bool { commit(plan.document, "Add narration") }

    /// Commits the clip of `planNativeNarrationRespeak` as one undoable edit ("Speak narration again").
    @discardableResult
    func respeakNarration(_ plan: NativeNarrationPlan) -> Bool { commit(plan.document, "Speak narration again") }
}
