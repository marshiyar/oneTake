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
#if os(macOS)
import AppKit
#endif

/// The stage's cursor in each host's terms. A resize arrow follows the handle's on-screen direction (the element's
/// rotation added), rounded to the nearest of horizontal, vertical and the two diagonals. No OS has a system rotate
/// cursor, so rotate shows the arrow and the stage draws its rotate glyph beside it (PlayerView+TransformBox.swift).
extension EditorShellRouter.Cursor {
    init(stage: StageCursor) {
        switch stage {
        case .arrow, .rotate: self = .arrow
        case .move: self = .move
        case .anchor: self = .crosshair
        case .notAllowed: self = .notAllowed
        case .resize(let degrees): self = Self.resize(degrees)
        }
    }

    /// 0° horizontal, 45° top-left to bottom-right (y down), 90° vertical, 135° top-right to bottom-left.
    static func resize(_ degrees: Double) -> Self {
        guard degrees.isFinite else { return .columnResize }
        let a = (degrees.truncatingRemainder(dividingBy: 180) + 180).truncatingRemainder(dividingBy: 180)
        let sector = Int(((a + 22.5) / 45).rounded(.down)) % 4
        return [.columnResize, .resizeNWSE, .rowResize, .resizeNESW][sector]
    }

    /// GDK cursor names (CSS cursor names; docs.gtk.org/gdk3/ctor.Cursor.new_from_name.html, read 2026-10-21).
    var cssName: String {
        switch self {
        case .arrow: "default"
        case .columnResize: "ew-resize"
        case .rowResize: "ns-resize"
        case .move: "move"
        case .resizeNWSE: "nwse-resize"
        case .resizeNESW: "nesw-resize"
        case .crosshair: "crosshair"
        case .notAllowed: "not-allowed"
        }
    }

    /// Win32 system cursor ids for LoadCursorW (learn.microsoft.com/en-us/windows/win32/menurc/about-cursors,
    /// read 2026-10-21).
    var windowsCursorId: Int {
        switch self {
        case .arrow: 32512         // IDC_ARROW
        case .columnResize: 32644  // IDC_SIZEWE
        case .rowResize: 32645     // IDC_SIZENS
        case .move: 32646          // IDC_SIZEALL
        case .resizeNWSE: 32642    // IDC_SIZENWSE
        case .resizeNESW: 32643    // IDC_SIZENESW
        case .crosshair: 32515     // IDC_CROSS
        case .notAllowed: 32648    // IDC_NO
        }
    }
}

#if os(macOS)
extension MacShell {
    /// AppKit cursors (nil: the arrow). Diagonal resize arrows are `NSCursor.frameResize(position:directions:)`,
    /// macOS 15 and later (developer.apple.com/documentation/appkit/nscursor/frameresize(position:directions:),
    /// read 2026-10-21); earlier systems show the crosshair there.
    static func nsCursor(_ cursor: EditorShellRouter.Cursor) -> NSCursor? {
        switch cursor {
        case .arrow: return nil
        case .columnResize: return .resizeLeftRight
        case .rowResize: return .resizeUpDown
        case .move: return .openHand
        case .crosshair: return .crosshair
        case .notAllowed: return .operationNotAllowed
        case .resizeNWSE, .resizeNESW: return diagonal(cursor == .resizeNWSE)
        }
    }

    static func diagonal(_ nwse: Bool) -> NSCursor {
        if #available(macOS 15, *) { return .frameResize(position: nwse ? .topLeft : .topRight, directions: .all) }
        return .crosshair
    }
}
#endif

/// A window's frame keeps its system cursors; captured drags may continue outside the client area.
enum HostCursorRefreshPolicy {
    static func shouldRefresh(ownsCapture: Bool, ownsWindow: Bool, x: Double, y: Double,
                              width: Double, height: Double) -> Bool {
        ownsCapture || (ownsWindow && x >= 0 && y >= 0 && x < width && y < height)
    }
}
