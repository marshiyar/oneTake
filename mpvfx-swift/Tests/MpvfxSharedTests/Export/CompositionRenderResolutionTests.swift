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

/// The Renders tab's resolution scales the composition: "auto" is the composition's own size, every other choice
/// keeps its aspect ratio (720p of a 9:16 composition is 720×1280), so a render never squeezes the frame.
final class CompositionRenderResolutionTests: XCTestCase {
    func testStoredValuesAndLegacyChoicesMapToAShortEdge() {
        XCTAssertEqual(CompositionRenderResolution(stored: "auto"), .auto)
        XCTAssertEqual(CompositionRenderResolution(stored: "720p"), .shortEdge(720))
        XCTAssertEqual(CompositionRenderResolution(stored: "2160p"), .shortEdge(2160))
        XCTAssertEqual(CompositionRenderResolution(stored: "custom"), .custom)
        // Saved before the change: the fixed presets and the 1080p/4K scale name their short edge.
        XCTAssertEqual(CompositionRenderResolution(stored: "1080p"), .shortEdge(1080))
        XCTAssertEqual(CompositionRenderResolution(stored: "4k"), .shortEdge(2160))
        XCTAssertEqual(CompositionRenderResolution(stored: "vertical-hd"), .shortEdge(720))
        XCTAssertEqual(CompositionRenderResolution(stored: "full-hd"), .shortEdge(1080))
        XCTAssertEqual(CompositionRenderResolution(stored: "social-4-5"), .shortEdge(1080))
        XCTAssertEqual(CompositionRenderResolution(stored: "uhd-8k"), .shortEdge(4320))
        XCTAssertEqual(CompositionRenderResolution(stored: "nonsense"), .auto)
        XCTAssertEqual(CompositionRenderResolution(stored: "toString"), .auto)
        XCTAssertEqual(CompositionRenderResolution.shortEdge(1440).storedValue, "1440p")
        XCTAssertEqual(CompositionRenderResolution.auto.storedValue, "auto")
        XCTAssertEqual(CompositionRenderResolution.custom.storedValue, "custom")
    }

    func testAShortEdgeKeepsTheCompositionAspect() {
        func d(_ edge: Double, _ w: Double, _ h: Double) -> ExportDimensions? {
            CompositionRenderResolution.shortEdge(edge).dimensions(compositionWidth: w, compositionHeight: h, customWidth: 0)
        }
        XCTAssertEqual(d(720, 1080, 1920), .init(width: 720, height: 1280), "720p of 9:16")
        XCTAssertEqual(d(720, 1920, 1080), .init(width: 1280, height: 720), "720p of 16:9")
        XCTAssertEqual(d(1080, 1080, 1080), .init(width: 1080, height: 1080))
        XCTAssertEqual(d(1080, 1080, 1350), .init(width: 1080, height: 1350), "4:5")
        XCTAssertEqual(d(2160, 1080, 1350), .init(width: 2160, height: 2700))
        XCTAssertEqual(d(2160, 1080, 1920), .init(width: 2160, height: 3840))
        // Odd results round to the nearest even pixel (H.264 4:2:0 needs even sides).
        XCTAssertEqual(d(720, 1000, 1777), .init(width: 720, height: 1280))
        XCTAssertEqual(d(720, 1001, 1001), .init(width: 720, height: 720))
        // Outside the 8K envelope (7680 long edge, 4320 short edge): no size.
        XCTAssertEqual(d(4320, 1080, 1920), .init(width: 4320, height: 7680), "vertical 8K")
        XCTAssertNil(d(4320, 1080, 2520), "10080 px long edge")
        XCTAssertNil(d(720, 0, 1080))
        XCTAssertEqual(CompositionRenderResolution.auto.dimensions(compositionWidth: 1080, compositionHeight: 1920, customWidth: 0),
                       .init(width: 1080, height: 1920), "auto is the composition size")
    }

    func testCustomTakesAWidthAndTheHeightFollowsTheAspect() {
        let c = CompositionRenderResolution.custom
        XCTAssertEqual(c.dimensions(compositionWidth: 1080, compositionHeight: 1920, customWidth: 540), .init(width: 540, height: 960))
        XCTAssertEqual(c.dimensions(compositionWidth: 1920, compositionHeight: 1080, customWidth: 1000), .init(width: 1000, height: 562))
        XCTAssertNil(c.dimensions(compositionWidth: 1920, compositionHeight: 1080, customWidth: 0))
        XCTAssertEqual(CompositionRenderResolution.customHeight(forWidth: 540, compositionWidth: 1080, compositionHeight: 1920), 960)
        XCTAssertEqual(CompositionRenderResolution.customWidth(forHeight: 1280, compositionWidth: 1080, compositionHeight: 1920), 720)
    }

    func testTheChoicesOfferedForAComposition() {
        let tall = CompositionRenderResolution.choices(compositionWidth: 1080, compositionHeight: 1920)
        XCTAssertEqual(tall.map(\.storedValue), ["auto", "720p", "1080p", "1440p", "2160p", "4320p", "custom"])
        let taller = CompositionRenderResolution.choices(compositionWidth: 1080, compositionHeight: 2520)
        XCTAssertEqual(taller.map(\.storedValue), ["auto", "720p", "1080p", "1440p", "2160p", "custom"], "8K of 3:7 exceeds the 7680 long edge")
        let square = CompositionRenderResolution.choices(compositionWidth: 1080, compositionHeight: 1080)
        XCTAssertEqual(square.map(\.storedValue), ["auto", "720p", "1080p", "1440p", "2160p", "4320p", "custom"])
    }

    func testCompositionPresets() {
        XCTAssertEqual(NativeCompositionPreset.allCases.map { "\($0.label) \(Int($0.width))x\(Int($0.height))" }, [
            "Landscape 16:9 1920x1080", "Portrait 9:16 1080x1920", "Square 1:1 1080x1080", "Vertical 4:5 1080x1350", "4K 16:9 3840x2160",
        ])
        XCTAssertEqual(NativeCompositionPreset.matching(width: 1080, height: 1920), .portrait)
        XCTAssertNil(NativeCompositionPreset.matching(width: 1000, height: 1920))
    }
}
