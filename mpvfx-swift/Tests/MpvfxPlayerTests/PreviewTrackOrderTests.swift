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
@testable import MpvfxPlayer
import MpvfxShared

/// The preview stacks clips by timeline row: the top row draws on top, and reordering rows restacks.
final class PreviewTrackOrderTests: XCTestCase {
    func testTopTimelineRowDrawsOnTopAndFollowsReorder() throws {
        var doc = try PreviewCompositorTests.document()
        XCTAssertEqual(PreviewCompositorTests.composition(doc).layers(at: 0.5).map(\.clipId), ["A", "B", "img"])
        // Swap rows t2 (B) and t1 (A): A is now above B on the timeline, so it draws over B.
        doc.sequence.tracks[1].lane?.displayTrack = 2
        doc.sequence.tracks[2].lane?.displayTrack = 1
        XCTAssertEqual(PreviewCompositorTests.composition(doc).layers(at: 0.5).map(\.clipId), ["B", "A", "img"])
        XCTAssertEqual(nativeTrackStackingLayers(doc.sequence.tracks), [3, 1, 2, 0])
    }

    func testTracksWithoutLanesStackByDocumentOrder() throws {
        var doc = try PreviewCompositorTests.document()
        for i in doc.sequence.tracks.indices { doc.sequence.tracks[i].lane = nil }
        XCTAssertEqual(nativeTrackStackingLayers(doc.sequence.tracks), [3, 2, 1, 0], "first track is the top row")
    }
}
