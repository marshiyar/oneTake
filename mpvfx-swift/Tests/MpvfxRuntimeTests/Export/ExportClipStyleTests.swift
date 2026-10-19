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
@testable import MpvfxShared
@testable import MpvfxRuntime

/// Clip style (fill, stroke, shadow) in a real render: a 64x32 red clip boxed into the left 32x32 square, so the
/// contain fit leaves 8 px bands above and below for the fill, and the canvas right of the box shows the shadow.
extension ExportCompletenessTests {
    func rgb(_ f: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 64 + x) * 3; return (Int(f[i]), Int(f[i + 1]), Int(f[i + 2])) }
    static let boxed = ##""staticParameters":{"layout.width":32,"layout.height":32},"##

    func testStyleFillStrokeAndShadowRender() throws {
        let style = ##""style":{"fill":"#0000ff","strokeWidth":2,"strokeStyle":"solid","strokeColor":"#ffffff","shadows":[{"x":16,"y":0,"blur":0,"spread":0,"color":"#00ff00"}]},"##
        let f = try picture(try render(try project(Self.boxed + style), "style.mov"), 0.5)
        let band = rgb(f, 16, 4), media = rgb(f, 16, 16), edge = rgb(f, 0, 16), shadow = rgb(f, 40, 16), past = rgb(f, 60, 16)
        XCTAssertGreaterThan(band.2, 180, "fill in the letterbox band \(band)"); XCTAssertLessThan(band.0, 60)
        XCTAssertGreaterThan(media.0, 180, "media \(media)"); XCTAssertLessThan(media.2, 60)
        XCTAssertGreaterThan(edge.0 + edge.1 + edge.2, 600, "stroke at the box edge \(edge)")
        XCTAssertGreaterThan(shadow.1, 180, "shadow right of the box \(shadow)"); XCTAssertLessThan(shadow.0, 60)
        XCTAssertLessThan(past.0 + past.1 + past.2, 60, "nothing beyond the shadow \(past)")
    }

    func testStyleShadowFollowsAKeyframedClip() throws {
        let style = ##""style":{"shadows":[{"x":16,"y":0,"blur":4,"spread":0,"color":"#00ff00"}]},"##
        let doc = try project(Self.boxed + style,
                              parameterTracks: "[\(track("transform.position", "vec2", [(0, ##"{"x":0,"y":0}"##), (10, ##"{"x":16,"y":0}"##)]))]")
        let out = try render(doc, "style-animated.mov")
        let start = try picture(out, 0), end = try picture(out, 1.5)
        XCTAssertGreaterThan(rgb(start, 40, 16).1, 120, "shadow right of the box at the start \(rgb(start, 40, 16))")
        XCTAssertGreaterThan(rgb(end, 56, 16).1, 120, "the shadow moved with the clip \(rgb(end, 56, 16))")
        XCTAssertGreaterThan(rgb(end, 24, 16).0, 180, "the clip moved right")
    }
}
