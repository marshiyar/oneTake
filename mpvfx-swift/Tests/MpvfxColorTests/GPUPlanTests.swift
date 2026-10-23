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
@testable import MpvfxColor
import CMpvfxColorShared

/// The multipass plan both compute hosts run (MpvfxGpuPlan.h: Vulkan on Linux, Direct3D 11 on Windows): pass order,
/// buffer roles, parameters, buffer sizes and threadgroup counts, checked here without a device.
final class GPUPlanTests: XCTestCase {
    struct Step: Equatable, CustomStringConvertible {
        let kernel: Int32, reads: [Int32], writes: Int32
        var description: String { "k\(kernel) \(reads)->\(writes)" }
    }

    static let src = Int32(MPVFX_GPU_B_SRC.rawValue), out = Int32(MPVFX_GPU_B_OUT.rawValue)
    static let blurA = Int32(MPVFX_GPU_B_BLUR_A.rawValue), blurB = Int32(MPVFX_GPU_B_BLUR_B.rawValue)
    static let bloomA = Int32(MPVFX_GPU_B_BLOOM_A.rawValue), bloomB = Int32(MPVFX_GPU_B_BLOOM_B.rawValue)
    static let moments = Int32(MPVFX_GPU_B_MOMENTS.rawValue), kuwahara = Int32(MPVFX_GPU_B_KUWAHARA.rawValue)
    static let blur = Int32(MPVFX_GPU_K_BLUR.rawValue), mom = Int32(MPVFX_GPU_K_MOMENTS.rawValue)
    static let resolve = Int32(MPVFX_GPU_K_RESOLVE.rawValue), grade = Int32(MPVFX_GPU_K_GRADE.rawValue)

    static func job(_ w: Int32, _ h: Int32, blur: Int32 = 0, bloom: (Int32, Int32) = (0, 0), kuwahara: Int32 = 0) -> MpvfxGpuGradeJob {
        var j = MpvfxGpuGradeJob()
        j.width = w; j.height = h
        j.blurIterations = blur; j.blurRadius = 6; j.blurAmount = 0.5
        j.bloomWidth = bloom.0; j.bloomHeight = bloom.1; j.bloomRadius = 3
        j.kuwaharaRadius = kuwahara; j.kuwaharaExponent = 8; j.kuwaharaSaturation = 1.1
        return j
    }

    static func plan(_ j: MpvfxGpuGradeJob) -> [MpvfxGpuPass] {
        var job = j
        var passes = [MpvfxGpuPass](repeating: MpvfxGpuPass(), count: Int(MPVFX_GPU_MAX_PASSES))
        let n = passes.withUnsafeMutableBufferPointer { mpvfx_gpu_plan(&job, $0.baseAddress) }
        return Array(passes.prefix(Int(n)))
    }

    static func steps(_ passes: [MpvfxGpuPass]) -> [Step] {
        passes.map { p in
            let reads = [p.in.0, p.in.1, p.in.2, p.in.3, p.momIn].filter { $0 != 0 }
            return Step(kernel: p.kernel, reads: reads, writes: p.outPx != 0 ? p.outPx : p.outMom)
        }
    }

    static func params(_ p: MpvfxGpuPass) -> [Float] {
        let all = [p.params.0, p.params.1, p.params.2, p.params.3, p.params.4, p.params.5, p.params.6, p.params.7]
        return Array(all.prefix(Int(p.paramCount)))
    }

    func testAPlainGradeIsOneDispatchOverTheWholeFrame() {
        let p = Self.plan(Self.job(160, 90))
        XCTAssertEqual(Self.steps(p), [Step(kernel: Self.grade, reads: [Self.src], writes: Self.out)])
        XCTAssertEqual(p[0].usesJobUniforms, 1)
        XCTAssertEqual([p[0].groupsX, p[0].groupsY], [10, 12], "160 / 16 and 90 / 8 rounded up")
    }

    /// Blur, bloom and Kuwahara together: the Metal pipeline's order, each pass reading only what earlier passes wrote.
    func testEveryMultipassEffectRunsInTheMetalOrder() {
        let p = Self.plan(Self.job(101, 57, blur: 2, bloom: (51, 29), kuwahara: 4))
        let (s, a, b, ba, bb) = (Self.src, Self.blurA, Self.blurB, Self.bloomA, Self.bloomB)
        XCTAssertEqual(Self.steps(p), [
            Step(kernel: Self.blur, reads: [s], writes: a), Step(kernel: Self.blur, reads: [a], writes: b),
            Step(kernel: Self.blur, reads: [b], writes: a), Step(kernel: Self.blur, reads: [a], writes: b),
            Step(kernel: Self.blur, reads: [s], writes: ba), Step(kernel: Self.blur, reads: [ba], writes: bb),
            Step(kernel: Self.mom, reads: [s, b], writes: Self.moments),
            Step(kernel: Self.resolve, reads: [Self.moments], writes: Self.kuwahara),
            Step(kernel: Self.grade, reads: [s, b, Self.kuwahara, bb], writes: Self.out),
        ])
        XCTAssertEqual(Self.hazards(Self.steps(p)), [], "each pass reads only the source or what earlier passes wrote")
    }

    /// The passes that read a buffer no earlier pass wrote, or the buffer they write themselves.
    static func hazards(_ steps: [Step]) -> [String] {
        var written: Set<Int32> = [src]
        var found: [String] = []
        for (i, step) in steps.enumerated() {
            if !Set(step.reads).isSubset(of: written) { found.append("pass \(i) \(step) reads an unwritten buffer") }
            if step.reads.contains(step.writes) { found.append("pass \(i) \(step) reads what it writes") }
            written.insert(step.writes)
        }
        return found
    }

    /// Every blur and bloom pass carries its own direction, radius, bloom flag, threshold and orientation by value (the
    /// Direct3D 11 host once uploaded a dangling copy of these, which blurred nothing and flipped the picture).
    func testBlurAndBloomPassesCarryTheirParameters() {
        let p = Self.plan(Self.job(101, 57, blur: 1, bloom: (51, 29)))
        XCTAssertEqual(p.count, 5)
        XCTAssertEqual(Self.params(p[0]), [1, 0, 6, 0, -1, 1], "horizontal, radius 6, from the image-oriented source")
        XCTAssertEqual(Self.params(p[1]), [0, 1, 6, 0, -1, 0])
        XCTAssertEqual(Self.params(p[2]), [1, 0, 3, 1, 0.5, 1], "bloom: thresholded, from the source")
        XCTAssertEqual(Self.params(p[3]), [0, 1, 3, 1, -1, 0])
        let job = Self.job(101, 57, blur: 1, bloom: (51, 29))
        XCTAssertEqual(p.dropLast().map { Self.uploaded($0, job) }, p.dropLast().map(Self.params),
                       "a copied pass uploads its own parameters")
    }

    /// The floats the host uploads as `u` for a copy of `pass`.
    static func uploaded(_ pass: MpvfxGpuPass, _ j: MpvfxGpuGradeJob) -> [Float] {
        var copy = pass, job = j
        var count: Int32 = -1
        let u = withUnsafePointer(to: &copy) { mpvfx_gpu_pass_uniforms($0, &job, &count) }
        return u.map { Array(UnsafeBufferPointer(start: $0, count: Int(count))) } ?? []
    }

    /// Bloom writes at its own size from a full-size source: the hdr and the threadgroups follow the output.
    func testBloomPassesUseTheBloomSize() {
        let p = Self.plan(Self.job(96, 54, bloom: (48, 27)))
        XCTAssertEqual(Array([p[0].hdr.0, p[0].hdr.1, p[0].hdr.2, p[0].hdr.3]), [48, 27, 96, 54])
        XCTAssertEqual(Array([p[1].hdr.0, p[1].hdr.1, p[1].hdr.2, p[1].hdr.3]), [48, 27, 48, 27])
        XCTAssertEqual([p[0].groupsX, p[0].groupsY, p[2].groupsX, p[2].groupsY], [3, 4, 6, 7])
        XCTAssertEqual(Array([p[2].hdr.8, p[2].hdr.9]), [48, 27], "the grade samples bloom (slot 3) at the bloom size")
    }

    /// Frame sizes alternate (preview and export interleaved, down to 1 x 1): buffer sizes and dispatches follow each.
    func testBufferSizesAndDispatchesFollowEveryFrameSize() {
        let sizes: [(Int32, Int32, Int32, Int32)] = [(96, 54, 48, 27), (33, 17, 17, 9), (1, 1, 1, 1), (2, 3, 1, 2)]
        XCTAssertEqual(sizes.map { Self.frameReport($0.0, $0.1, ($0.2, $0.3)) }, sizes.map { (w, h, bw, bh) in
            let frame = UInt64(w) * UInt64(h)
            return FrameReport(texels: [frame, frame, frame, frame, UInt64(bw) * UInt64(bh)], passes: 11, misfitDispatches: 0)
        }, "3 blur iterations, bloom, Kuwahara and the grade (6 + 2 + 2 + 1), groups covering each output exactly")
        var off = Self.job(64, 48)
        XCTAssertEqual(mpvfx_gpu_buffer_texels(&off, Self.blurA), 0, "unused pass buffers are not allocated")
        XCTAssertEqual(mpvfx_gpu_buffer_texels(&off, Self.bloomB), 0)
        XCTAssertEqual(mpvfx_gpu_buffer_stride(Self.moments), 16)
        XCTAssertEqual(mpvfx_gpu_buffer_stride(Self.kuwahara), 4)
    }

    struct FrameReport: Equatable {
        let texels: [UInt64], passes: Int, misfitDispatches: Int
    }

    /// Buffer texels (source, output, blur, moments, bloom), the pass count, and the passes whose threadgroups do not
    /// cover their output or add a whole idle group, for one frame size with every effect on.
    static func frameReport(_ w: Int32, _ h: Int32, _ bloom: (Int32, Int32)) -> FrameReport {
        var j = job(w, h, blur: 3, bloom: bloom, kuwahara: 2)
        let texels = [src, out, blurB, moments, bloomA].map { mpvfx_gpu_buffer_texels(&j, $0) }
        let p = plan(j)
        let misfit = p.filter { pass in
            let (ow, oh) = (UInt32(pass.hdr.0), UInt32(pass.hdr.1))
            return pass.groupsX * 16 < ow || pass.groupsY * 8 < oh || (pass.groupsX - 1) * 16 >= ow || (pass.groupsY - 1) * 8 >= oh
        }
        return FrameReport(texels: texels, passes: p.count, misfitDispatches: misfit.count)
    }

    /// More than three blur iterations are capped (the Metal pipeline's bound), so the plan never exceeds its room.
    func testBlurIterationsAreCapped() {
        let p = Self.plan(Self.job(8, 8, blur: 9, bloom: (4, 4), kuwahara: 1))
        XCTAssertEqual(p.count, 11)
        XCTAssertLessThanOrEqual(p.count, Int(MPVFX_GPU_MAX_PASSES))
    }

    /// The reference cases the parity test failed on under Direct3D 11: their frames plan blur passes with a radius.
    func testReferenceEffectsPlanTheirPasses() {
        let names = ["effect.blur", "effect.bloom", "effect.blurStrong", "effect.blurKuwahara"]
        XCTAssertEqual(names.map(Self.referenceSummary), names.map { _ in "blur passes with a radius, the grade last" })
    }

    static func referenceSummary(_ name: String) -> String {
        guard let c = GradeReferenceCases.all.first(where: { $0.name == name }) else { return "no case \(name)" }
        let frame = GradeReferenceCases.renderer(c).gpuFrame(width: 160, height: 90, time: 0.7)
        let passes = frame.withJob(tableKey: name) { plan($0.pointee) }
        let blurs = passes.filter { $0.kernel == blur }
        guard !blurs.isEmpty, blurs.allSatisfy({ $0.params.2 > 0 }) else { return "\(name): a blur pass without a radius" }
        return passes.last?.kernel == grade ? "blur passes with a radius, the grade last" : "\(name): the grade is not last"
    }
    func testSaturationCurveTableReachesSharedGPUJob() throws {
        var params = ColorGradeParams()
        params.curves["saturationVsSaturation"] = [[0, 1], [1, -1]]
        let renderer = ColorGradeRenderer(params: params)
        let frame = renderer.gpuFrame(width: 8, height: 4, time: 0)
        XCTAssertEqual(frame.saturationRows.count, 1024)
        XCTAssertEqual(frame.saturationRows.first?.x, 1)
        frame.withJob(tableKey: renderer.signature) { ptr in
            let job = ptr.pointee
            XCTAssertEqual(job.saturationTexels, 1024)
            XCTAssertEqual(job.hueTexels, 1024)
            XCTAssertEqual(job.saturation?[0], 1)
            XCTAssertEqual(job.saturation?[1023 * 4], 1 / 255)
        }
    }

}
