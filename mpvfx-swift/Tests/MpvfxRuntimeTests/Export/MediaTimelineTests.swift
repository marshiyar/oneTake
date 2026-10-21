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
import MpvfxShared
@testable import MpvfxRuntime

final class MediaTimelineTests: XCTestCase {
    func project() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"test","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#000000"},
         "assets":[{"id":"video","kind":"video","name":"clip.mov","durationFrames":90}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"v","kind":"video","clips":[
           {"id":"clip","assetId":"video","startFrame":15,"durationFrames":60,"sourceInFrame":30,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    func testRendersANativeMediaDocumentAsIs() throws {
        var document = try project()
        document.assets[0].source = "assets/clip.mov"
        XCTAssertEqual(try mediaTimelineForExport(document), document)
    }

    func testRejectsIncompleteNativeMediaDocumentsInsteadOfGuessingASource() throws {
        let document = try project()
        XCTAssertThrowsError(try mediaTimelineForExport(document)) { XCTAssertTrue("\($0)".contains("Media path is missing"), "\($0)") }
    }

    func testAMissingMediaPathNamesTheAssetNotItsId() throws {
        XCTAssertThrowsError(try mediaTimelineForExport(try project())) {
            XCTAssertEqual("\($0)", "Media path is missing for clip.mov")
        }
    }

    func testAnOlderProjectWithoutAStoredEngineNameExports() throws {
        var document = try project()
        XCTAssertEqual(document.mediaEngine, .native)   // parse migrates the missing field
        document.mediaEngine = nil
        document.assets[0].source = "assets/clip.mov"
        XCTAssertEqual(try mediaTimelineForExport(document), document)
    }

    func testAnElementLayerTheRendererCannotDrawIsSkippedNotRefused() throws {
        var document = try project()
        document.assets[0].source = "assets/clip.mov"
        document.assets.append(.init(id: "card", kind: .element, name: "card", source: nil, durationFrames: 90))
        document.sequence.tracks.append(.init(id: "over", kind: .video, clips: [.fresh(id: "card", assetId: "card", startFrame: 0, durationFrames: 30)]))
        XCTAssertEqual(try mediaTimelineForExport(document), document)   // the document is not changed
        let rendered = nativeExportVisibleProject(document)
        XCTAssertEqual(rendered.sequence.tracks.flatMap(\.clips).map(\.id), ["clip"])
        XCTAssertEqual(rendered.sequence.durationFrames, 75)
        let plan = planExport(document, settings: .init())
        XCTAssertTrue(plan.canStart, "\(plan.issues)")
        XCTAssertEqual(plan.notices, ["1 layer from an earlier version of the editor is kept in the project but not drawn in preview or export."])
    }
}
