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
import XCTest
import MpvfxDesktopCore
import MpvfxPanels
@testable import MpvfxDesktop

/// The requests the navigator's naming commands become: each carries the type, ids and name LibraryCommands reads (#40).
final class LibraryNameCommandTests: XCTestCase {
    func testEachNamingCommandBecomesItsLibraryCommandsRequest() {
        XCTAssertEqual(SessionPanels.namedItemCommand(.createEvent(libraryId: "L", name: "Day 2")),
                       ["type": .string("event"), "libraryId": .string("L"), "name": .string("Day 2")])
        XCTAssertEqual(SessionPanels.namedItemCommand(.createProject(libraryId: "L", eventId: "E", name: "B-roll")),
                       ["type": .string("project"), "libraryId": .string("L"), "eventId": .string("E"), "name": .string("B-roll")])
        XCTAssertEqual(SessionPanels.namedItemCommand(.renameEvent(libraryId: "L", eventId: "E", name: "Day 1")),
                       ["type": .string("renameEvent"), "libraryId": .string("L"), "eventId": .string("E"), "name": .string("Day 1")])
        XCTAssertEqual(SessionPanels.namedItemCommand(.renameProject(libraryId: "L", projectId: "P", name: "Final")),
                       ["type": .string("renameProject"), "libraryId": .string("L"), "projectId": .string("P"), "name": .string("Final")])
    }

    func testACommandThatNamesNothingOnlyLists() {
        XCTAssertEqual(SessionPanels.namedItemCommand(.reveal(libraryId: "L")), ["type": .string("list")])
    }
}
