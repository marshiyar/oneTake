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
#if canImport(MpvfxMetal)
import XCTest
import Metal
@testable import MpvfxMetal
@testable import MpvfxColor
import MpvfxShared

/// The Metal grade keeps a bounded pool of per-size targets: grading at many sizes (a resizing preview, export at
/// another size) never holds more than the pool budget of idle buffers and textures, and memory pressure empties it.
final class MetalPoolMemoryTests: XCTestCase {
    func testIdleTargetsStayWithinThePoolBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let metal = MetalColorRenderer(pipeline: try MetalGradePipeline(device: device))
        metal.pipeline.poolBudgetBytes = 4 << 20
        let r = GradeReferenceCases.renderer(GradeReferenceCases.all[0])
        for i in 0..<40 {
            let w = 320 + (i % 10) * 64, h = 180 + (i % 10) * 36
            var px = GradeReferenceCases.card(width: w, height: h)
            metal.render(r, &px, width: w, height: h, time: Double(i) / 30)
            XCTAssertLessThanOrEqual(metal.pipeline.pool.count, 6)
            let largest = 2 * ((w * 4 + 255) / 256 * 256) * h * 8   // one target with every pass, generously
            XCTAssertLessThanOrEqual(metal.pipeline.pooledBytes, max(metal.pipeline.poolBudgetBytes, largest), "size \(w)x\(h)")
        }
        MemoryPressureMonitor.shared.simulate(.warning)
        XCTAssertEqual(metal.pipeline.pooledBytes, 0, "pressure drops the idle targets")
    }
}
#endif
