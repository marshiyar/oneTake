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
@testable import MpvfxDesktopCore

/// Issue #28: the Linux shell read 21 `MPVFX_SMOKE_*` names, macOS 3 and Windows 4, so a macOS run given
/// MPVFX_SMOKE_SELECT captured a frame with nothing selected. Reads the shells' source (all three, whichever OS
/// runs the test, since only one of them compiles here) and checks that each handles the same names.
final class SmokeHookParityTests: XCTestCase {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")
    static let shells = ["LinuxShell.swift", "MacShell.swift", "WindowsShell.swift"]
    /// The call through which a shell hands every parsed hook to the shared runner (`MpvfxDesktop/SmokeRunner.swift`).
    static let runnerCall = "SmokeRunner("

    func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Names a file reads itself: quoted `"MPVFX_SMOKE_…"` literals.
    func quotedNames(_ text: String) -> Set<String> {
        let re = try! NSRegularExpression(pattern: "\"(MPVFX_SMOKE_[A-Z_]*[A-Z])\"")
        let ns = text as NSString
        return Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    /// The names a shell handles: the ones it reads itself, plus every name when it starts the shared runner.
    func handled(_ shell: String) throws -> Set<String> {
        let text = try source("MpvfxDesktop/" + shell)
        return quotedNames(text).union(text.contains(Self.runnerCall) ? Self.allNames : [])
    }

    static let allNames = Set(SmokeHookName.allCases.map(\.rawValue))

    /// Shell file -> the names it misses ("-NAME") or reads that the parser does not know ("+NAME").
    func shellMismatches() throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for shell in Self.shells {
            let names = try handled(shell)
            let diff = Self.allNames.subtracting(names).map { "-" + $0 } + names.subtracting(Self.allNames).map { "+" + $0 }
            if !diff.isEmpty { out[shell] = diff.sorted() }
        }
        return out
    }

    /// Source files other than the parser that quote a smoke variable name -> those names.
    func quotedOutsideParser() throws -> [String: [String]] {
        guard let walk = FileManager.default.enumerator(atPath: Self.sources.path) else { return ["<no Sources>": []] }
        var out: [String: [String]] = [:]
        for case let path as String in walk where path.hasSuffix(".swift") {
            // The enumerator yields "MpvfxDesktopCore\\SmokeHooks.swift" on Windows: compare and report with "/".
            let rel = path.replacingOccurrences(of: "\\", with: "/")
            if rel == "MpvfxDesktopCore/SmokeHooks.swift" { continue }
            let names = quotedNames(try source(path))
            if !names.isEmpty { out[rel] = names.sorted() }
        }
        return out
    }

    func testEveryShellHandlesTheSameSmokeHookNames() throws {
        XCTAssertEqual(try shellMismatches(), [:])
    }

    /// Parsed once: no source file but the parser quotes a smoke variable name, so a new hook cannot reach one
    /// shell alone.
    func testSmokeHookNamesAreQuotedOnlyInTheParser() throws {
        XCTAssertEqual(try quotedOutsideParser(), [:], "read these through SmokeHooks(env:) instead")
        XCTAssertEqual(quotedNames(try source("MpvfxDesktopCore/SmokeHooks.swift")), Self.allNames)
    }
}
