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
// Checks jsLocaleCompare against Node's String.prototype.localeCompare (fixture generated with
// Node v20.19.2, ICU 76.1, default locale en-US — see Fixtures/localeCompare.json).
// The fixture is read via #filePath because Package.swift declares no test resources.
import XCTest
@testable import MpvfxShared

final class LocaleCompareFixtureTests: XCTestCase {
    struct Fixture: Decodable { let node: String; let icu: String; let locale: String; let strings: [String]; let pairs: [[NativeJSONValue]] }

    static func mismatches() throws -> [(String, String, Int, Int)] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/localeCompare.json")
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        var out: [(String, String, Int, Int)] = []
        for p in f.pairs {
            guard let a = p[0].stringValue, let b = p[1].stringValue, let e = p[2].numberValue else { continue }
            let got = jsLocaleCompare(a, b)
            if got != Int(e) { out.append((a, b, Int(e), got)) }
        }
        return out
    }

    /// Pairs involving these strings are documented gaps (see docs/IMPLEMENTATION_NOTES.md) and excluded.
    static let knownGapStrings: Set<String> = []

    func testMatchesNodeLocaleCompare() throws {
        let bad = try Self.mismatches().filter { !Self.knownGapStrings.contains($0.0) && !Self.knownGapStrings.contains($0.1) }
        XCTAssertTrue(bad.isEmpty, "\(bad.count) mismatches, e.g. " + bad.prefix(25).map { "\($0.0)|\($0.1): node \($0.2) swift \($0.3)" }.joined(separator: "; "))
    }
}
