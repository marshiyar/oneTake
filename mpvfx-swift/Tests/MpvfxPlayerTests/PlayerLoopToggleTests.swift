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
import MpvfxPlayer
import MpvfxTimeline
import MpvfxCanvas

final class PlayerLoopToggleTests: XCTestCase {
    func testButtonAndShortcutNotifyLoopTransitionsOnce() {
        let playback = PlaybackState(duration: 3)
        let player = PlayerController(view: PlayerView(playback: playback))
        player.size = CanvasSize(1032, 640)
        var changes: [Bool] = []
        playback.onChange = { changes.append(playback.loopEnabled) }
        let button = player.view.buttonRect(.loop, in: player.size)
        for _ in 0..<2 {
            player.pointerDown(x: button.x + 5, y: button.y + 5)
            player.pointerUp(x: button.x + 5, y: button.y + 5)
        }
        XCTAssertEqual(changes, [true, false])
        changes = []
        for _ in 0..<2 {
            XCTAssertTrue(playback.keyDown(EditorKey(.char("L"), shift: true)))
            playback.keyUp(EditorKey(.char("L"), shift: true))
        }
        XCTAssertEqual(changes, [true, false])
        changes = []
        playback.loopEnabled = false
        XCTAssertTrue(changes.isEmpty, "assigning the existing state is not a transition")
    }
}
