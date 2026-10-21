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
@testable import MpvfxPanels

final class DockCodecTests: XCTestCase {
    let registry = DockRegistry.editor
    var fallback: DockFile { DockFile(workspaces: [DockFile.defaultWorkspace: DockDefaults.layout(registry)]) }

    func decoded(_ json: String) -> Result<DockCodec.Decoded, DockLayoutError> { DockCodec.decode(Data(json.utf8), registry: registry) }

    func file(_ json: String) throws -> DockCodec.Decoded {
        switch decoded(json) {
        case .success(let d): return d
        case .failure(let e): XCTFail("refused: \(e)"); throw e
        }
    }

    func error(_ json: String) -> DockLayoutError? {
        if case .failure(let e) = decoded(json) { return e }
        return nil
    }

    // MARK: Round trip and versioning

    func testALayoutSurvivesASaveAndLoad() throws {
        var l = DockDefaults.layout(registry)
        try l.move("renders", to: .split(group: try XCTUnwrap(l.root.group(containing: "preview")).id, edge: .bottom), fraction: 0.3)
        try l.close("media", registry: registry)
        let f = DockFile(current: "color", workspaces: ["edit": DockDefaults.layout(registry), "color": l])
        let back = try file(String(decoding: try DockCodec.encode(f), as: UTF8.self))
        XCTAssertEqual(back.file, f)
        XCTAssertEqual(back.notes, [])
    }

    func testTheFileCarriesItsVersionAndAnotherVersionIsRefused() throws {
        let data = try DockCodec.encode(fallback)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(error(#"{"version": 2, "workspaces": {}}"#), .unsupportedVersion(2))
        XCTAssertEqual(error(#"{"version": 0}"#), .unsupportedVersion(0))
        XCTAssertEqual(error(#"{"workspaces": {}}"#), .malformed("no version"))
    }

    // MARK: Hostile and corrupt files fall back to the default

    func testCorruptFilesAreTypedErrorsAndLoadTheDefault() {
        let cases: [String] = ["", "null", "[]", "{", "not json", #"{"version": "1"}"#, #"{"version": 1, "workspaces": []}"#,
                               #"{"version": 1, "workspaces": {"edit": {"root": {"leaf": {}}}}}"#]
        for json in cases {
            let result = DockCodec.load(Data(json.utf8), registry: registry, fallback: fallback)
            XCTAssertNotNil(result.error, json)
            XCTAssertEqual(result.file, fallback, json)
        }
        XCTAssertNil(DockCodec.load(nil, registry: registry, fallback: fallback).error, "no file is the first launch, not an error")
    }

    func testAFileWithNoUsableWorkspaceIsRefused() {
        XCTAssertEqual(error(#"{"version": 1}"#), .noWorkspace)
        XCTAssertEqual(error(#"{"version": 1, "workspaces": {"Bad Name": {"root": {"group": {"panels": ["media"]}}}}}"#), .noWorkspace)
        XCTAssertEqual(error(#"{"version": 1, "workspaces": {"edit": {}}}"#), .noWorkspace)
    }

    func testAnOversizedFileIsRefusedBeforeParsing() {
        let big = Data(repeating: 0x20, count: DockCodec.maxBytes + 1)
        XCTAssertEqual(DockCodec.decode(big, registry: registry).failureValue, .tooLarge(bytes: DockCodec.maxBytes + 1))
    }

    func testANestingBombIsRefusedBeforeParsing() {
        let bomb = String(repeating: "[", count: 200_000)
        XCTAssertEqual(error(bomb), .tooDeep)
        XCTAssertEqual(DockCodec.jsonDepth(Data(#"{"a": "[[[[{{{{"}"#.utf8)), 1, "brackets inside strings do not count")
    }

    static let emptyGroup = "{\"group\": {\"panels\": []}}"
    static func split(_ children: [String]) -> String { "{\"split\": {\"axis\": \"row\", \"children\": [" + children.joined(separator: ",") + "]}}" }
    static func edit(_ root: String) -> String { "{\"version\": 1, \"workspaces\": {\"edit\": {\"root\": " + root + "}}}" }

    func testATreeDeeperThanTheLimitIsRefused() {
        var node = "{\"group\": {\"panels\": [\"media\"]}}"
        for _ in 0..<DockCodec.maxDepth { node = Self.split([node, Self.emptyGroup]) }
        XCTAssertEqual(error(Self.edit(node)), .tooDeep)
    }

    func testTooManyNodesAreRefused() {
        let groups = Array(repeating: Self.emptyGroup, count: DockCodec.maxNodes + 1)
        XCTAssertEqual(error(Self.edit(Self.split(groups))), .tooManyNodes)
    }

    /// The limits themselves are allowed, degenerate trees collapse, and numbers JSON cannot hold never crash.
    func testBoundaryTreesAndNumbers() throws {
        var node = "{\"group\": {\"panels\": [\"media\"]}}"
        for _ in 1..<DockCodec.maxDepth { node = Self.split([node, Self.emptyGroup]) }
        assertDockInvariants(try XCTUnwrap(try file(Self.edit(node)).file.layout), registry)   // depth exactly 12
        let groups = Array(repeating: Self.emptyGroup, count: DockCodec.maxNodes - 1)
        assertDockInvariants(try XCTUnwrap(try file(Self.edit(Self.split(groups))).file.layout), registry)   // 256 nodes
        for degenerate in [Self.split([]), Self.split([Self.emptyGroup]), "{\"split\": {}}", "{\"group\": {}}"] {
            let l = try XCTUnwrap(try file(Self.edit(degenerate)).file.layout, degenerate)
            assertDockInvariants(l, registry)
            XCTAssertEqual(l.openPanels.sorted(), ["preview", "timeline"], degenerate)
        }
        for number in ["1e999", "-1e999", "1e-999", "0", "-0", "123456789012345678901234567890"] {
            let json = "{\"split\": {\"axis\": \"row\", \"weights\": [\(number), 1], \"children\": [{\"group\": {\"panels\": [\"preview\"]}}, {\"group\": {\"panels\": [\"timeline\"]}}]}}"
            switch decoded(Self.edit(json)) {
            case .failure(let e):
                guard case .malformed = e else { XCTFail("\(number): \(e)"); continue }
            case .success(let d): d.file.workspaces.values.forEach { assertDockInvariants($0, registry) }
            }
        }
    }

    // MARK: Content errors are repaired

    func testUnknownAndDuplicatePanelsAreDroppedAndMissingRequiredPanelsAdded() throws {
        let d = try file(#"""
        {"version": 1, "workspaces": {"edit": {"root": {"split": {"axis": "row", "weights": [1, 1], "children": [
          {"group": {"id": "g1", "panels": ["media", "ghost", "media"], "active": "ghost"}},
          {"group": {"id": "g1", "panels": ["inspector"]}}]}}}}}
        """#)
        let l = try XCTUnwrap(d.file.layout)
        assertDockInvariants(l, registry)
        XCTAssertEqual(l.root.group(containing: "media")?.panels, ["media"])
        XCTAssertEqual(l.root.group(containing: "media")?.active, "media")
        XCTAssertTrue(l.isOpen("preview"))
        XCTAssertTrue(l.isOpen("timeline"))
        XCTAssertFalse(l.isOpen("renders"), "a closable panel the file left out stays closed")
        XCTAssertEqual(d.notes, [#"dropped unknown panel "ghost""#, #"dropped duplicate panel "media""#,
                                 #"added missing panel "preview""#, #"added missing panel "timeline""#])
    }

    func testBadWeightsAndAxesAreRepaired() throws {
        let d = try file(#"""
        {"version": 1, "workspaces": {"edit": {"root": {"split": {"axis": "diagonal", "weights": [-3, 0, 1e300], "children": [
          {"group": {"panels": ["media"]}}, {"group": {"panels": ["preview"]}}, {"group": {"panels": ["timeline"]}}]}}}}}
        """#)
        let l = try XCTUnwrap(d.file.layout)
        assertDockInvariants(l, registry)
        guard case .split(let s) = l.root else { return XCTFail("root") }
        XCTAssertEqual(s.axis, .row)
        XCTAssertTrue(d.notes.contains(#"unknown split axis "diagonal", using row"#))
    }

    /// One wrong value in a list (a number among panel ids, a string among weights, an object as an index) is
    /// dropped or defaulted with a note; the rest of the layout survives.
    func testWrongTypesInsideListsAreDroppedNotFatal() throws {
        let d = try file(#"""
        {"version": 1, "current": 7, "workspaces": {"edit": {"root": {"split": {"axis": "row", "weights": ["a", 1, null], "children": [
          {"group": {"id": 3, "panels": [1, "media", null, {"x": 1}, ["preview"]], "active": false}},
          {"group": {"panels": ["preview"]}}, {"group": {"panels": ["timeline"]}}]}},
          "closed": {"renders": {"mates": [true, "inspector"], "index": {}, "edge": 2, "fraction": "half"}}}}}
        """#)
        let l = try XCTUnwrap(d.file.layout)
        assertDockInvariants(l, registry)
        XCTAssertEqual(d.file.current, "edit")
        XCTAssertEqual(l.root.group(containing: "media")?.panels, ["media"])
        guard case .split(let s) = l.root else { return XCTFail("root") }
        XCTAssertEqual(s.weights.count, 3)
        XCTAssertEqual(l.closed["renders"], .tab(mates: ["inspector"], index: 0))
        XCTAssertEqual(d.notes.filter { $0 == "dropped a panel entry that is not a name" }.count, 4)
    }

    func testClosedPlacesAreFilteredAndClamped() throws {
        let d = try file(#"""
        {"version": 1, "current": "missing", "workspaces": {"edit": {"root": {"group": {"panels": ["preview", "timeline"]}},
          "closed": {"media": {"mates": ["ghost", "preview"], "index": 9999, "edge": "up", "fraction": 7},
                     "preview": {"index": 0}, "ghost": {}}}}}
        """#)
        XCTAssertEqual(d.file.current, "edit", "an unknown current workspace falls back to edit")
        let l = try XCTUnwrap(d.file.layout)
        XCTAssertEqual(l.closed, ["media": .tab(mates: ["preview"], index: 64)])
        var reopened = l
        try reopened.open("media", registry: registry)
        XCTAssertEqual(reopened.root.group(containing: "media")?.panels, ["preview", "timeline", "media"])
    }

    func testNotesQuoteAtMostFortyCharacters() throws {
        let long = String(repeating: "x", count: 500)
        let d = try file(#"{"version": 1, "workspaces": {"edit": {"root": {"group": {"panels": ["preview", "timeline", "\#(long)"]}}}}}"#)
        XCTAssertEqual(d.notes, ["dropped unknown panel \"\(String(repeating: "x", count: 40))…\""])
    }

    /// Byte edits of a valid file (a fixed SplitMix64 sequence): decoding never crashes, and a file it accepts satisfies every invariant.
    func testMutatedFilesNeverCrashAndAcceptedOnesAreValid() throws {
        var l = DockDefaults.layout(registry)
        try l.close("renders", registry: registry)
        let base = Array(try DockCodec.encode(DockFile(workspaces: ["edit": l, "audio": DockDefaults.layout(registry)])))
        var seq = SplitMix64(seed: 0xF11E)
        let alphabet = Array(#"{}[]",:0123456789.-eE"abcdefghijklmnopqrstuvwxyz \n"#.utf8)
        var accepted = 0
        for _ in 0..<2000 {
            var bytes = base
            for _ in 0..<(1 + seq.below(6)) {
                let i = seq.below(bytes.count)
                switch seq.below(3) {
                case 0: bytes[i] = seq.pick(alphabet) ?? 0
                case 1: bytes.remove(at: i)
                default: bytes.insert(seq.pick(alphabet) ?? 0, at: i)
                }
            }
            guard case .success(let d) = DockCodec.decode(Data(bytes), registry: registry) else { continue }
            accepted += 1
            for layout in d.file.workspaces.values { assertDockInvariants(layout, registry) }
            XCTAssertNotNil(d.file.layout)
        }
        XCTAssertGreaterThan(accepted, 0, "some edits (inside strings, numbers) still parse")
    }
}

fileprivate extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e }; return nil }
}
