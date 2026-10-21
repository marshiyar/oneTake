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
import Dispatch
import Foundation
import XCTest
import MpvfxTheme

final class ThemeObserverTests: XCTestCase {
    override func setUp() { Theme.setMode(.dark) }
    override func tearDown() { Theme.setMode(.dark) }

    func testDeliveryIsSynchronousOrderedAndOnTheMainThread() {
        var seen: [String] = []
        let first = Theme.addObserver { mode in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(Theme.mode, mode)
            XCTAssertEqual(ThemeTokens.timelineSurface, ThemeTokens.timelineSurfacePair.value(mode))
            seen.append("first-\(mode.rawValue)")
        }
        let second = Theme.addObserver { seen.append("second-\($0.rawValue)") }
        defer { Theme.removeObserver(first); Theme.removeObserver(second) }
        XCTAssertTrue(seen.isEmpty, "Registration does not deliver an initial event")
        Theme.setMode(.light)
        XCTAssertEqual(seen, ["first-light", "second-light"], "Delivery finishes before setMode returns")
        Theme.setMode(.light)
        XCTAssertEqual(seen.count, 2, "An unchanged mode does not deliver again")
        Theme.removeObserver(first)
        Theme.removeObserver(first)
        Theme.setMode(.dark)
        XCTAssertEqual(seen, ["first-light", "second-light", "second-dark"])
    }

    func testSubscriptionChangesTakeEffectOnTheNextDelivery() {
        var seen: [String] = []
        var first = 0, second = 0, added = 0
        first = Theme.addObserver { mode in
            seen.append("first-\(mode.rawValue)")
            Theme.removeObserver(first)
            Theme.removeObserver(second)
            added = Theme.addObserver { seen.append("added-\($0.rawValue)") }
        }
        second = Theme.addObserver { seen.append("second-\($0.rawValue)") }
        defer { Theme.removeObserver(first); Theme.removeObserver(second); Theme.removeObserver(added) }
        Theme.setMode(.light)
        XCTAssertEqual(seen, ["first-light", "second-light"], "The current delivery keeps its snapshot")
        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThan(added, second, "Removed observer ids are not reused")
        Theme.setMode(.dark)
        XCTAssertEqual(seen, ["first-light", "second-light", "added-dark"])
    }

    func testAnObserverCanSwitchModeReentrantly() {
        var seen: [String] = []
        let first = Theme.addObserver { mode in
            seen.append("first-\(mode.rawValue)")
            if mode == .light { Theme.setMode(.dark) }
        }
        let second = Theme.addObserver { seen.append("second-\($0.rawValue)") }
        defer { Theme.removeObserver(first); Theme.removeObserver(second) }
        Theme.setMode(.light)
        XCTAssertEqual(Theme.mode, .dark)
        XCTAssertEqual(seen, ["first-light", "first-dark", "second-dark", "second-light"],
                       "Nested changes retain the existing synchronous delivery order")
    }

    func testObserverDoesNotHoldTheModeLockDuringDelivery() {
        let id = Theme.addObserver { mode in
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                XCTAssertEqual(Theme.mode, mode)
                XCTAssertEqual(ThemeTokens.timelineSurface, ThemeTokens.timelineSurfacePair.value(mode))
                read.signal()
            }
            XCTAssertEqual(read.wait(timeout: .now() + 5), .success,
                           "Drawing threads can read tokens while the main-thread observer is running")
        }
        defer { Theme.removeObserver(id) }
        Theme.setMode(.light)
    }

    func testConcurrentDrawingReadsDuringModeChanges() {
        let readers = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for _ in 0..<4 {
            readers.enter()
            DispatchQueue.global().async {
                start.wait()
                for _ in 0..<5_000 {
                    XCTAssertTrue(ThemeMode.allCases.contains(Theme.mode))
                    let color = ThemeTokens.timelineSurface
                    let pair = ThemeTokens.timelineSurfacePair
                    XCTAssertTrue(color == pair.dark || color == pair.light)
                }
                readers.leave()
            }
        }
        for _ in 0..<4 { start.signal() }
        for _ in 0..<1_000 { Theme.setMode(.light); Theme.setMode(.dark) }
        XCTAssertEqual(readers.wait(timeout: .now() + 10), .success)
    }
}
