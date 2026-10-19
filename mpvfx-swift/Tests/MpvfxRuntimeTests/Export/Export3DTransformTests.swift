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
// The 3D transform in a real render: depth, tilt and lens drawn by the preview painter with the same NativeTransform3D
// projection the preview mesh draws, exported through the media engine.
import Foundation
import XCTest
@testable import MpvfxShared
@testable import MpvfxRuntime

extension ExportCompletenessTests {
    /// A 32x16 red box (the picture's aspect) centred on the 64x32 canvas, turned 60° about Y under a 64 px lens: the
    /// near (left) edge grows past the flat box's top, the far (right) edge shrinks, and the box narrows to x 22…39.
    func testStaticTiltUnderALensForeshortensTheExport() throws {
        let doc = try project(#""staticParameters":{"layout.left":16,"layout.top":8,"layout.width":32,"layout.height":16,"transform.rotationY":60,"transform.perspective":64},"#)
        let f = try picture(try render(doc, "tilt.mov"), 0.5)
        let near = NativeTransform3D(rotationY: 60, perspective: 64).project(-16, 0).x + 32
        let far = NativeTransform3D(rotationY: 60, perspective: 64).project(16, 0).x + 32
        XCTAssertEqual(near, 21.8, accuracy: 0.2); XCTAssertEqual(far, 38.6, accuracy: 0.2)
        XCTAssertGreaterThan(red(f, 30, 16), 200, "the middle stays covered")
        XCTAssertLessThan(red(f, 18, 16), 40, "flat, x 18 was inside the box; tilted it is not")
        XCTAssertLessThan(red(f, 43, 16), 40)
        XCTAssertGreaterThan(red(f, 23, 7), 200, "the near edge grows past the flat box's top (y 8)")
        XCTAssertLessThan(red(f, 37, 7), 40, "the far edge is shorter")
    }

    /// Keyframed Tilt X under a lens: flat at the first key, foreshortened at the second.
    func testKeyframedTiltAnimatesTheWarp() throws {
        let doc = try project(#""staticParameters":{"transform.perspective":64},"#,
                              parameterTracks: "[\(track("transform.rotationX", "number", [(0, "0"), (10, "70")]))]")
        let out = try render(doc, "tilt-keys.mov")
        let start = try picture(out, 0), end = try picture(out, 1.5)
        XCTAssertGreaterThan(red(start, 32, 1), 200); XCTAssertGreaterThan(red(start, 32, 30), 200)
        XCTAssertLessThan(red(end, 32, 1), 40, "tilted 70° the top edge falls away from the frame edge")
        XCTAssertGreaterThan(red(end, 32, 16), 200)
    }

    /// Depth under a lens magnifies about the box centre (z 32 under a 64 px lens doubles the size).
    func testDepthMagnifiesTheExport() throws {
        let doc = try project(#""staticParameters":{"layout.left":24,"layout.top":8,"layout.width":16,"layout.height":16,"transform.position.z":32,"transform.perspective":64},"#)
        let f = try picture(try render(doc, "depth.mov"), 0.5)
        XCTAssertGreaterThan(red(f, 18, 16), 200, "16 px box drawn 32 px wide: x 16…48")
        XCTAssertLessThan(red(f, 12, 16), 40)
    }
}
