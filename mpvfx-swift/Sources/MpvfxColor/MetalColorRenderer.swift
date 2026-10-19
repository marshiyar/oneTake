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
import Foundation
import Metal
import MpvfxMetal
import MpvfxShared

/// The grade on the GPU (macOS): packs a `ColorGradeRenderer` frame into a `MetalGradeJob` and runs it through
/// MpvfxMetal's pipelines (kernels in Sources/MpvfxMetal/Shaders/MpvfxColor.metal). A frame the GPU cannot grade is
/// graded by the CPU port instead, so preview and export never lose a frame.
public final class MetalColorRenderer: ColorRenderer, @unchecked Sendable {
    public var backend: String { "metal" }
    public let pipeline: MetalGradePipeline
    public var device: MTLDevice { pipeline.device }
    let lock = NSLock()
    /// Frames that failed on the GPU and were graded on the CPU instead (diagnostics, tests).
    public private(set) var cpuFallbacks = 0

    /// Memory pressure drops the pipeline's idle targets and tables.
    var pressureToken: MemoryPressureMonitor.Token?

    public init(pipeline: MetalGradePipeline) {
        self.pipeline = pipeline
        pressureToken = MemoryPressureMonitor.shared.observe { [weak pipeline] _ in pipeline?.purgeIdle() }
    }

    /// The system default device's renderer, or nil when there is no device or the kernels do not load.
    public static func makeDefault() -> MetalColorRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do { return MetalColorRenderer(pipeline: try MetalGradePipeline(device: device)) } catch {
            FileHandle.standardError.write(Data("MpvfxColor: Metal grade unavailable, using the CPU renderer: \(error)\n".utf8))
            return nil
        }
    }

    public func render(_ grade: ColorGradeRenderer, _ rgba: inout [UInt8], width: Int, height: Int, time: Double, sourceKey: String?) {
        guard grade.isActive, width > 0, height > 0, rgba.count >= width * height * 4 else { return }
        let f = grade.gpuFrame(width: width, height: height, time: time)
        let job = MetalGradeJob(width: width, height: height, uniforms: f.uniforms, curveRows: f.curveRows, hueRows: f.hueRows,
                                secondaryTexels: f.secondaryTexels, lutSize: f.lutSize, lut: f.lut, blurRadius: f.blurRadius,
                                blurIterations: f.blurIterations, blurAmount: f.blurAmount, bloomWidth: f.bloomWidth, bloomHeight: f.bloomHeight,
                                bloomRadius: f.bloomRadius, kuwaharaRadius: f.kuwaharaRadius, kuwaharaExponent: f.kuwaharaExponent,
                                kuwaharaSaturation: f.kuwaharaSaturation, tableKey: grade.signature)
        var j = job; j.sourceKey = sourceKey
        do { try pipeline.render(j, &rgba) } catch {
            lock.lock(); cpuFallbacks += 1; let first = cpuFallbacks == 1; lock.unlock()
            if first { FileHandle.standardError.write(Data("MpvfxColor: Metal grade failed (\(error)); graded on the CPU\n".utf8)) }
            grade.apply(&rgba, width: width, height: height, time: time)
        }
    }
}
#endif
