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
/// Modifier keys held during a pointer event (hosts translate AppKit / GDK / Win32 flags into this).
public struct PointerModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = PointerModifiers(rawValue: 1)
    public static let alt = PointerModifiers(rawValue: 2)      // Option / Alt
    public static let meta = PointerModifiers(rawValue: 4)     // Command / Super
    public static let ctrl = PointerModifiers(rawValue: 8)
    /// Command on macOS or Ctrl elsewhere (`metaKey || ctrlKey`, as the original reads it).
    public var command: Bool { contains(.meta) || contains(.ctrl) }
    /// The wheel zooms instead of scrolling: ⌘ or Ctrl, or Option / Alt (the editor convention for zooming a
    /// timeline about the pointer). Hosts pass it as the scroll's zoom flag.
    public var zoomsWheel: Bool { command || contains(.alt) }
}

/// Pointer buttons in DOM numbering (MouseEvent.button), which every host maps its own numbering onto.
public enum PointerButton {
    public static let primary = 0, middle = 1, secondary = 2, back = 3, forward = 4

    /// AppKit `NSEvent.buttonNumber` (0 left, 1 right, 2 middle, 3+ extra) to DOM numbering.
    public static func fromAppKit(_ n: Int) -> Int {
        switch n { case 0: primary; case 1: secondary; case 2: middle; default: n }
    }
    /// GDK button (1 left, 2 middle, 3 right, 8 back, 9 forward) to DOM numbering.
    public static func fromGdk(_ n: UInt32) -> Int {
        switch n { case 1: primary; case 2: middle; case 3: secondary; case 8: back; case 9: forward; default: Int(n) }
    }
}

/// A native accessibility control represented by a custom-drawn canvas widget.
public struct CanvasAccessibilityControl {
    public var label: String
    public var value: Bool
    public var frame: CanvasRect
    public var press: () -> Void
    public init(label: String, value: Bool, frame: CanvasRect, press: @escaping () -> Void) {
        self.label = label; self.value = value; self.frame = frame; self.press = press
    }
}

/// Canvas inputs that publish native controls to their desktop host.
public protocol CanvasAccessibilityProvider: AnyObject {
    var accessibilityControls: [CanvasAccessibilityControl] { get }
}
