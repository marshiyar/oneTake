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

extension TimelineController {
    /// A clip popup owns its keys until activated or dismissed. Disabled rows are never keyboard targets.
    @discardableResult func clipMenuKeyDown(_ key: EditorKey) -> Bool {
        guard var menu = view.clipMenu else { return false }
        let items = menu.itemRects().map(\.0).filter(\.enabled)
        switch key.code {
        case .escape:
            view.clipMenu = nil
            needsDisplay?()
            return true
        case .enter, .space:
            guard let item = items.first(where: { $0.action == menu.hovered }) ?? items.first else { return true }
            view.clipMenu = nil
            _ = runClipMenu(item.action, clipId: menu.clipId)
            needsDisplay?()
            return true
        case .up, .down, .home, .end:
            guard !items.isEmpty else { return true }
            let index: Int
            if key.code == .home { index = 0 }
            else if key.code == .end { index = items.count - 1 }
            else if let current = items.firstIndex(where: { $0.action == menu.hovered }) {
                index = (current + (key.code == .down ? 1 : items.count - 1)) % items.count
            } else { index = key.code == .down ? 0 : items.count - 1 }
            menu.hovered = items[index].action
            menu.reveal(items[index].action)
            view.clipMenu = menu
            needsDisplay?()
            return true
        default:
            return true
        }
    }
}
