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
import XCTest
import MpvfxCanvas

/// docs/TIMELINE.md "Zoom": Option (Alt) + scroll zooms the timeline about the pointer, like ⌘ or Ctrl + scroll and a
/// pinch; Shift alone scrolls sideways. Every host passes `zoomsWheel` as the scroll's zoom flag.
final class PointerModifiersTests: XCTestCase {
    func testOptionCommandAndCtrlMakeTheWheelZoom() {
        XCTAssertTrue(PointerModifiers.alt.zoomsWheel, "Option / Alt + scroll")
        XCTAssertTrue(PointerModifiers.meta.zoomsWheel, "⌘ + scroll")
        XCTAssertTrue(PointerModifiers.ctrl.zoomsWheel, "Ctrl + scroll, and a pinch (sent as Ctrl)")
        XCTAssertTrue(PointerModifiers([.alt, .shift]).zoomsWheel, "Option still zooms with Shift held")
        XCTAssertFalse(PointerModifiers.shift.zoomsWheel, "Shift scrolls sideways")
        XCTAssertFalse(PointerModifiers().zoomsWheel, "a plain wheel scrolls")
    }
}
