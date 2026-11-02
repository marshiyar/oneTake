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
import MpvfxTimeline

extension EditorSession {
    /// ⌥⌘S saves the selected text layer as a style and ⌥⌘1…9 apply the n-th style to the selected text layers.
    /// With no text layer selected ⌥⌘S stays scene splitting (EditorSession+Scenes.swift), so this runs first.
    func textStyleKey(_ key: EditorKey) -> Bool {
        guard key.command, key.alt, !key.shift, case .char(let char) = key.code, let inspector = panels?.right.inspector else { return false }
        if char.lowercased() == "s" {
            guard inspector.canSaveTextStyle else { return false }
            _ = inspector.saveTextStyleFromLayer()
            redraw()
            return true
        }
        guard let number = Int(String(char)), (1...9).contains(number), inspector.applyTextStyle(number: number) else { return false }
        redraw()
        return true
    }
}
