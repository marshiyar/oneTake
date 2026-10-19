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
import MpvfxMetal
@testable import MpvfxColor

/// The Metal grade against the CPU reference (`GradeProgram`), control by control and effect by effect, plus the
/// 1080p heavy-effects frame time. Runs on the Mac CI runner.
final class MetalColorRendererTests: XCTestCase {
    var metal: MetalColorRenderer!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        metal = MetalColorRenderer(pipeline: try MetalGradePipeline(device: device))
    }

    struct Diff: CustomStringConvertible {
        var max = 0, over1 = 0, over2 = 0, count = 0, sum = 0
        var mean: Double { count > 0 ? Double(sum) / Double(count) : 0 }
        var description: String { "max \(max), >1: \(over1), >2: \(over2) of \(count), mean \(String(format: "%.4f", mean))" }
    }

    func diff(_ a: [UInt8], _ b: [UInt8]) -> Diff {
        var d = Diff(); d.count = a.count
        for i in 0..<min(a.count, b.count) {
            let x = abs(Int(a[i]) - Int(b[i]))
            d.sum += x; d.max = Swift.max(d.max, x)
            if x > 1 { d.over1 += 1 }
            if x > 2 { d.over2 += 1 }
        }
        return d
    }

    func testKernelsLoad() {
        print("Metal kernels from \(metal.pipeline.librarySource) on \(metal.device.name)")
        XCTAssertFalse(metal.pipeline.librarySource.isEmpty)
    }

    func testSharedRendererIsMetalOnMac() {
        if ProcessInfo.processInfo.environment["MPVFX_COLOR_RENDERER"]?.lowercased() == "cpu" { return }
        XCTAssertEqual(ColorRendering.shared.backend, "metal", "preview and export grade on the GPU on macOS")
    }

    /// Every adjust key, wheel, curve mode, secondary, LUT mode, finish detail and stylize effect (with its settings
    /// and variants), at two sizes (one with rows that need padding in the linear upload texture) and two times.
    /// Tolerance: deterministic controls stay within 1 level on all but 0.1% of channels (a threshold effect such as an
    /// ASCII glyph or a hatch line may flip on a handful of pixels when its input differs by one level); effects
    /// built on sin-hash noise (grain, tape, glitch, film, paper) can flip a pixel when the GPU's sin differs from the
    /// CPU's by an ulp (film dust is a step on a hash: a speck can land in a different cell), so they get 2% of
    /// channels over 2 levels and a mean under 0.5 levels.
    func testEveryControlAndEffectMatchesTheCPUReference() {
        var report = "Metal vs CPU reference:\n"
        for c in GradeReferenceCases.all {
            for (w, h, time) in [(160, 90, 0.7), (101, 57, 2.35)] {
                let r = GradeReferenceCases.renderer(c)
                let src = GradeReferenceCases.card(width: w, height: h)
                var cpu = src; r.apply(&cpu, width: w, height: h, time: time)
                var gpu = src; metal.render(r, &gpu, width: w, height: h, time: time)
                let d = diff(gpu, cpu)
                report += "  \(c.name) \(w)x\(h): \(d)\n"
                if c.noisy {
                    XCTAssertLessThanOrEqual(d.over2, d.count / 50, "\(c.name) \(w)x\(h): \(d)")
                    XCTAssertLessThan(d.mean, 0.5, "\(c.name) \(w)x\(h): \(d)")
                } else {
                    XCTAssertLessThanOrEqual(d.over1, d.count / 1000, "\(c.name) \(w)x\(h): \(d)")
                    XCTAssertLessThanOrEqual(d.over2, d.count / 2000, "\(c.name) \(w)x\(h): \(d)")
                    XCTAssertLessThan(d.mean, 0.02, "\(c.name) \(w)x\(h): \(d)")
                }
            }
        }
        XCTAssertEqual(metal.cpuFallbacks, 0, "every frame was graded on the GPU")
        print(report)
    }

    func testHeavyFrameMatchesAtPreviewSize() {
        let r = ColorGradeRenderer(params: GradeReferenceCases.params(GradeReferenceCases.heavyJSON), seedKey: "clip:heavy")
        let (w, h) = (640, 360)
        let src = GradeReferenceCases.card(width: w, height: h)
        var cpu = src; r.apply(&cpu, width: w, height: h, time: 1.25)
        var gpu = src; metal.render(r, &gpu, width: w, height: h, time: 1.25)
        let d = diff(gpu, cpu)
        print("Metal vs CPU heavy 640x360: \(d)")
        XCTAssertLessThanOrEqual(d.over1, d.count / 1000, "\(d)")
        XCTAssertLessThan(d.mean, 0.02, "\(d)")
    }

    func testRepeatedFramesAndCachedTablesAreStable() {
        let c = GradeReferenceCases.all.first { $0.name == "lut.tetrahedral" }!
        let r = GradeReferenceCases.renderer(c)
        let src = GradeReferenceCases.card(width: 64, height: 48)
        var a = src, b = src
        metal.render(r, &a, width: 64, height: 48, time: 0)
        metal.render(r, &b, width: 64, height: 48, time: 0)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, src)
        // An inactive grade leaves the frame alone.
        var n = src
        ColorGradeRenderer(params: GradeReferenceCases.params(#"{"preset":"neutral"}"#)).render(&n, width: 64, height: 48, time: 0, using: metal)
        XCTAssertEqual(n, src)
    }

    func testConcurrentFramesFromSeveralThreads() {
        let r = GradeReferenceCases.renderer(GradeReferenceCases.all.first { $0.name == "effect.kuwahara" }!)
        let src = GradeReferenceCases.card(width: 96, height: 54)
        var ref = src; r.apply(&ref, width: 96, height: 54, time: 0.5)
        let results = UnsafeMutableBufferPointer<Int>.allocate(capacity: 8); defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            var px = src; metal.render(r, &px, width: 96, height: 54, time: 0.5)
            results[i] = diff(px, ref).max
        }
        XCTAssertTrue(results.allSatisfy { $0 <= 3 }, "\(Array(results))")
    }

    /// 1080p with the heavy stylize effects must grade in under one frame at 30 fps (33.3 ms), measured end to end
    /// (upload, every pass, read back) after warm-up, on a real Apple GPU. On a virtualized GPU (GitHub's hosted macOS
    /// runners report "Apple Paravirtual device", 37 ms) the frame time says nothing about a Mac, so there every
    /// effect is still rendered and timed and no CPU fallback is allowed, but the budget is not asserted (an owner
    /// decision, recorded in docs/STATUS.md, "Visual effects" row).
    func testPerformance1080pHeavyEffects() {
        let (w, h) = (1920, 1080)
        let src = GradeReferenceCases.card(width: w, height: h)
        let budget = 1000.0 / 30
        let realGPU = !metal.device.name.localizedCaseInsensitiveContains("paravirtual")
        var lines = "Metal 1080p frame times (\(metal.device.name)\(realGPU ? "" : "; virtual GPU: 30 fps budget not asserted")):\n"
        func measure(_ name: String, _ json: String, assertBudget: Bool) {
            let r = ColorGradeRenderer(params: GradeReferenceCases.params(json), seedKey: "clip:perf")
            var px = src
            for _ in 0..<3 { px = src; metal.render(r, &px, width: w, height: h, time: 0.5) }
            var times: [Double] = []
            for i in 0..<15 {
                px = src
                let t0 = DispatchTime.now().uptimeNanoseconds
                metal.render(r, &px, width: w, height: h, time: 0.5 + Double(i) / 30)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            times.sort()
            let median = times[times.count / 2], worst = times.last!
            lines += "  \(name): median \(String(format: "%.2f", median)) ms, best \(String(format: "%.2f", times[0])) ms, worst \(String(format: "%.2f", worst)) ms\n"
            if assertBudget && realGPU { XCTAssertLessThan(median, budget, "\(name): median \(median) ms over the 30 fps frame time") }
        }
        measure("kuwahara (radius 16)", #"{"effects":{"kuwahara":1,"kuwaharaRadius":1}}"#, assertBudget: true)
        measure("crosshatch (edges)", #"{"effects":{"crosshatch":1,"crosshatchEdges":1}}"#, assertBudget: true)
        measure("ascii (edge rotation)", #"{"effects":{"ascii":1,"asciiRotation":1}}"#, assertBudget: true)
        measure("kuwahara + crosshatch + ascii + grade", GradeReferenceCases.heavyJSON, assertBudget: true)
        measure("blur 1 + bloom 2 + grain", #"{"effects":{"blur":1,"bloom":2},"details":{"grain":1}}"#, assertBudget: false)
        print(lines)
        XCTAssertEqual(metal.cpuFallbacks, 0)
    }
}
#endif
