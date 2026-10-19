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
// Issue #25: a catalog lookup that finds no project is a typed LibraryError, never a crash.
import Foundation
import XCTest
@testable import MpvfxShared
@testable import MpvfxRuntime

final class LibraryProjectLookupTests: XCTestCase {
    func testAnEmptyCatalogLookupThrowsATypedLibraryError() {
        let empty = Catalog(id: "library", name: "Film", events: [], projects: [], assets: [], placements: [], jobs: [])
        XCTAssertThrowsError(try LibraryService.catalogProject(empty, "missing")) { error in
            XCTAssertEqual(error as? LibraryError, LibraryError("Library project not found"))
        }
    }

    func testTheLookupReturnsTheCatalogEntryWithThatId() throws {
        let other = LibraryProject(id: "other", eventId: "e1", name: "Short Version", state: .ready)
        let wanted = LibraryProject(id: "main", eventId: "e2", name: "Main Edit", state: .pending)
        let catalog = Catalog(id: "library", name: "Film", events: [], projects: [other, wanted], assets: [], placements: [], jobs: [])
        XCTAssertEqual(try LibraryService.catalogProject(catalog, "main"), wanted)
    }
}
