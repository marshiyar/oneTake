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
import MpvfxShared

extension TimelineController {
    /// F9 easy ease on the selected keys, as After Effects binds it: F9 both sides, ⇧F9 the in side, ⌘⇧F9 (Ctrl+Shift+F9)
    /// the out side (https://helpx.adobe.com/after-effects/using/keyboard-shortcuts-reference.html, read
    /// 2026-10-21). One undo step; false (the key is not taken) without selected keys.
    func easyEaseSelectedKeyframes(_ k: EditorKey) -> Bool {
        guard let editor, !view.selectedKeyframes.isEmpty else { return false }
        let outOnly = k.shift && k.command, inOnly = k.shift && !k.command
        _ = editor.easyEase(Array(view.selectedKeyframes), out: !inOnly, in: !outOnly)
        needsDisplay?()
        return true
    }
}
