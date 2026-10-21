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
// Offline media in the running editor (issue #102): a media file deleted or restored outside the app, with no edit to
// the document, marks or clears the timeline clip at the next re-check, which is rate-limited rather than per frame.
import Foundation
import XCTest
import MpvfxTimeline
@testable import MpvfxDesktop

final class OfflineMediaRecheckTests: XCTestCase {
    var dir = ""
    override func tearDown() { if !dir.isEmpty { try? FileManager.default.removeItem(atPath: dir) }; super.tearDown() }

    func testAFileDeletedOrRestoredOutsideTheAppUpdatesTheMarksWithoutAnEdit() throws {
        dir = NSTemporaryDirectory() + "mpvfx-offline-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let logo = dir + "/logo.png"
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: logo))

        let session = try EditorSession(projectPath: nil, demo: true)
        // The demo's logo clip plays a file on disk (an absolute source: the demo has no project folder).
        var doc = session.editor.document
        let i = try XCTUnwrap(doc.assets.firstIndex { $0.id == "asset:logo" })
        doc.assets[i].source = logo
        session.editor.replaceDocument(doc, inverse: .restoreDocument(session.editor.document))
        session.syncDecoderClips()
        XCTAssertEqual(session.timeline.view.offlineAssetIds, [])

        session.mediaRecheckSeconds = 3600
        try FileManager.default.removeItem(atPath: logo)
        session.syncDecoderClips()
        XCTAssertEqual(session.timeline.view.offlineAssetIds, [], "not re-statted before the re-check is due")

        session.mediaRecheckSeconds = 0
        session.syncDecoderClips()
        XCTAssertEqual(session.timeline.view.offlineAssetIds, ["asset:logo"], "deleted outside the app: marked offline")

        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: logo))
        session.syncDecoderClips()
        XCTAssertEqual(session.timeline.view.offlineAssetIds, [], "restored: the mark clears")
    }
}
