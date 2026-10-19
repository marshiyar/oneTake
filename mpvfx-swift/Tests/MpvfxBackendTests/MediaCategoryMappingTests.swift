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
// Issue #25: listMedia maps runtime media categories to the panel's without force unwraps; an unknown one is skipped.
import Foundation
import XCTest
@testable import MpvfxBackend
import MpvfxDesktopCore
@testable import MpvfxRuntime

final class MediaCategoryMappingTests: XCTestCase {
    static let entry = ProjectMediaEntry(path: "assets/clip.mov", name: "clip.mov", category: .video, size: 42, modified: 1,
                                         used: true, description: "Video", duration: 2, width: 640, height: 360)

    func testAnUnknownCategoryIsSkippedInsteadOfCrashing() {
        XCTAssertNil(RuntimeDesktopBackend.desktopMediaEntry(Self.entry, categoryName: "subtitles"))
    }

    func testEveryRuntimeCategoryReachesTheMediaPanel() {
        let mapped = ProjectMediaCategory.allCases.map { category -> String? in
            var e = Self.entry
            e.category = category
            return RuntimeDesktopBackend.desktopMediaEntry(e, categoryName: category.rawValue)?.category.rawValue
        }
        XCTAssertEqual(mapped, ["audio", "images", "video", "fonts"])
    }

    func testTheMappedEntryKeepsEveryField() throws {
        let mapped = try XCTUnwrap(RuntimeDesktopBackend.desktopMediaEntry(Self.entry, categoryName: "video"))
        XCTAssertEqual(mapped, DesktopMediaEntry(path: "assets/clip.mov", name: "clip.mov", category: .video, size: 42, modified: 1,
                                                 used: true, description: "Video", duration: 2, width: 640, height: 360))
    }

    /// The three functions named in #25 hold no postfix `!` force unwrap.
    func testTheIssueFunctionsHoldNoForceUnwrap() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let checks = [("MpvfxBackend/RuntimeDesktopBackend.swift", "func listMedia("),
                      ("MpvfxRuntime/Library/LibraryService.swift", "func initializeProject("),
                      ("MpvfxRuntime/Library/LibraryService.swift", "func importForProject(")]
        let unwrap = try NSRegularExpression(pattern: #"[\w)\]}]!(?!=)"#)
        let hits = try checks.map { file, signature -> String in
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let body = try XCTUnwrap(Self.functionBody(text, signature), "\(signature) not found in \(file)")
            return "\(signature) \(unwrap.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body)))"
        }
        XCTAssertEqual(hits, ["func listMedia( 0", "func initializeProject( 0", "func importForProject( 0"])
    }

    /// The text from `signature` to the brace that closes its body (braces inside string literals in these functions are balanced).
    static func functionBody(_ text: String, _ signature: String) -> String? {
        guard let start = text.range(of: signature) else { return nil }
        var depth = 0, opened = false
        for i in text[start.lowerBound...].indices {
            if text[i] == "{" { depth += 1; opened = true }
            if text[i] == "}" { depth -= 1; if opened && depth == 0 { return String(text[start.lowerBound...i]) } }
        }
        return nil
    }
}
