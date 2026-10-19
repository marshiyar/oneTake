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
@testable import MpvfxShared

// The library bridge types hold no runtime logic, so these golden-value tests take every expected value
// from the recorded reference values in Fixtures/libraryParity.json (versions recorded),
// type-checked typed samples (see Fixtures/gen).
private let fixture: NativeJSONValue = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/libraryParity.json")
    return try! NativeJSONValue.parse(String(contentsOf: url, encoding: .utf8))
}()
private func rows(_ k: String) -> [NativeJSONValue] { fixture[k]?.arrayValue ?? [] }
/// Bridge round trip in Swift: order-preserving parse -> typed decode -> encode -> JSON.stringify.
private func roundTrip<T: Codable>(_ t: T.Type, _ text: String) throws -> String {
    let value = try NativeJSONValue.parse(text).decode(T.self)
    return jsJSONStringify(try NativeJSONValue.from(value))
}

final class LibraryBridgeParityTests: XCTestCase {
    func testProvenance() {
        XCTAssertEqual(fixture["node"]?.stringValue, "v20.19.2")
        XCTAssertEqual(fixture["typescript"]?.stringValue, "5.9.3")
    }

    func testEveryCommandMemberRoundTripsExactly() throws {
        let r = rows("commands"); XCTAssertEqual(r.count, 11)
        for row in r {
            let text = row["text"]!.stringValue!
            XCTAssertEqual(try roundTrip(LibraryCommand.self, text), row["roundTrip"]?.stringValue, text)
        }
    }

    func testResultsRoundTripExactly() throws {
        let r = rows("results"); XCTAssertEqual(r.count, 4)
        for row in r {
            let text = row["text"]!.stringValue!
            XCTAssertEqual(try roundTrip(LibraryResult.self, text), row["roundTrip"]?.stringValue, text)
        }
    }

    /// Unknown keys, numeric-like keys (JS moves them first), reordered keys, null optionals and -0 come back exactly
    /// as Node's JSON.parse -> JSON.stringify gives them.
    func testUnknownKeysAndOrderSurviveTheBridge() throws {
        for row in rows("rawCommands") {
            let text = row["text"]!.stringValue!
            XCTAssertEqual(try roundTrip(LibraryCommand.self, text), row["roundTrip"]?.stringValue, text)
            let decoded = try NativeJSONValue.parse(text).decode(LibraryCommand.self)
            XCTAssertEqual(decoded.spread.order, row["keys"]?.arrayValue?.map { $0.stringValue! }, text)
        }
        for row in rows("rawResults") {
            let text = row["text"]!.stringValue!
            XCTAssertEqual(try roundTrip(LibraryResult.self, text), row["roundTrip"]?.stringValue, text)
        }
    }

    func testTypedConstructionEncodesInDeclarationOrder() throws {
        // Same values as the typed samples of the fixture (commands[6], results[2]).
        let cmd = LibraryCommand(.import(libraryId: "L1", eventId: "E1", mode: .linked, projectId: "P1"))
        XCTAssertEqual(jsJSONStringify(try NativeJSONValue.from(cmd)), rows("commands")[6]["text"]?.stringValue)
        let view = LibraryView(id: "L1", name: "Main", path: "/libs/main.mpvfxlib",
            events: [.init(id: "E1", name: "Wedding")],
            projects: [.init(id: "P1", eventId: "E1", name: "Cut A", state: .ready)],
            assets: [.init(id: "A1", eventId: "E1", name: "a.mp4", kind: "video", mode: .managed, state: .ready, available: true),
                     .init(id: "A2", eventId: "E1", name: "b.wav", kind: "audio", mode: .linked, state: .pending)],
            jobs: [.init(id: "J1", projectId: "P1", status: "done", output: "out.mp4", error: "")])
        XCTAssertEqual(jsJSONStringify(try NativeJSONValue.from(LibraryResult(libraries: [view], projectId: "P1"))),
                       rows("results")[2]["text"]?.stringValue)
    }

    /// Documented gap (see docs/IMPLEMENTATION_NOTES.md): any JSON passes the bridge; Swift decoding rejects an unknown `type` or a
    /// wrong-typed required field. The desktop handler rejects unknown types too ("Unknown library command",
    /// LibraryCommands).
    func testUnknownCommandTypeIsRejected() {
        XCTAssertThrowsError(try NativeJSONValue.parse(#"{"type":"nope"}"#).decode(LibraryCommand.self)) {
            XCTAssertEqual($0 as? LibraryCommand.UnknownType, .init(type: "nope"))
        }
        XCTAssertThrowsError(try NativeJSONValue.parse(#"{"type":"event","libraryId":1,"name":"n"}"#).decode(LibraryCommand.self))
    }
}
