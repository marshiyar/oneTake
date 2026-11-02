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
// The Layout menu on the stage (issue #322): opening it, its keys and its clicks. StageLayoutMenu has the rows and
// the keys' meaning; the host applies the layout through `onApplyLayout`.
import Foundation
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline

extension PlayerController {
    /// Where the pointer last was on the stage (view px): the menu opens there.
    public var pointerLocation: CanvasPoint { lastPointer }

    /// Opens the menu at `point` for `clipCount` selected clips.
    public func openLayoutMenu(at point: CanvasPoint, clipCount: Int) {
        view.layoutMenu = StageLayoutMenu(origin: point, clipCount: clipCount)
        view.layoutMenu?.selected = StageLayoutMenu.layouts.firstIndex { view.layoutMenu?.isEnabled($0) == true } ?? 0
        view.contextMenu = nil
        needsDisplay?()
    }

    public func closeLayoutMenu() {
        guard view.layoutMenu != nil else { return }
        view.layoutMenu = nil
        needsDisplay?()
    }

    /// While the menu is open it owns the keys it understands; nil when it is closed or the key is not its.
    public func layoutMenuKey(_ k: EditorKey) -> Bool? {
        guard var menu = view.layoutMenu, !k.command, !k.alt else { return nil }
        let result = menu.key(k.code, shift: k.shift)
        view.layoutMenu = menu
        switch result {
        case .none: return nil
        case .handled: needsDisplay?(); return true
        case .close: closeLayoutMenu(); return true
        case .apply(let layout, let options):
            closeLayoutMenu()
            _ = onApplyLayout?(layout, options)
            needsDisplay?()
            return true
        }
    }

    /// A press while the menu is open: a row applies its layout, the footer does nothing, outside closes the menu.
    func layoutMenuPress(_ p: CanvasPoint) -> Bool {
        guard let menu = view.layoutMenu else { return false }
        switch menu.hit(at: p, bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)) {
        case .outside: closeLayoutMenu()
        case .footer: break
        case .row(let index):
            let layout = StageLayoutMenu.layouts[index]
            guard menu.isEnabled(layout) else { break }
            closeLayoutMenu()
            _ = onApplyLayout?(layout, menu.options)
        }
        needsDisplay?()
        return true
    }
}
