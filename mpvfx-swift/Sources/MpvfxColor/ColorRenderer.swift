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
import CMpvfxColorShared
import MpvfxShared

/// Draws a clip's grade and stylize effects onto RGBA8 frames (straight alpha, rows top first).
///
/// The shared renderer is the GPU's where there is one: `MetalColorRenderer` on macOS (Metal compute kernels in
/// Sources/MpvfxMetal/Shaders/MpvfxColor.metal), `VulkanColorRenderer` on Linux and `D3D11ColorRenderer` on Windows
/// (compute kernels generated from the same shading body by scripts/gpu/gen-compute-shaders.py). Without a usable
/// device, or with `MPVFX_GPU=0`, it is `CPUColorRenderer`, the CPU implementation of the same shader and the reference
/// every GPU path is tested against. Preview and export both draw through `ColorRendering.shared`, so they produce the
/// same pixels on one machine.
public protocol ColorRenderer: AnyObject, Sendable {
    /// "metal" or "cpu" (diagnostics, tests).
    var backend: String { get }
    /// Grades `rgba` (width * height * 4 bytes) in place at composition `time` (seconds). `sourceKey` names the
    /// source picture (lane, frame, size): a renderer may keep it resident and skip uploading it again when only the
    /// grade changed (nil: no reuse).
    func render(_ grade: ColorGradeRenderer, _ rgba: inout [UInt8], width: Int, height: Int, time: Double, sourceKey: String?)
}

extension ColorRenderer {
    public func render(_ grade: ColorGradeRenderer, _ rgba: inout [UInt8], width: Int, height: Int, time: Double) {
        render(grade, &rgba, width: width, height: height, time: time, sourceKey: nil)
    }
}

/// The CPU port (`GradeProgram`): the renderer without a GPU and the reference for every GPU path.
public final class CPUColorRenderer: ColorRenderer {
    public init() {}
    public var backend: String { "cpu" }
    public func render(_ grade: ColorGradeRenderer, _ rgba: inout [UInt8], width: Int, height: Int, time: Double, sourceKey: String?) {
        grade.apply(&rgba, width: width, height: height, time: time)
    }
}

/// The Vulkan and Direct3D 11 renderers' frame path (ComputeColorRenderer.swift): the frame packed by `gpuFrame`, graded
/// by the device, or by the CPU port when the device fails.
public class ComputeColorRenderer: ColorRenderer, @unchecked Sendable {
    public var backend: String { "gpu" }
    /// The device's name (diagnostics, benchmark reports).
    public let deviceName: String
    /// A CPU implementation of the API (lavapipe, WARP): correct, not fast.
    public let isSoftware: Bool
    let device: ComputeGradeDevice
    let lock = NSLock()
    var fallbacks = 0
    /// Frames that failed on the device and were graded on the CPU instead (diagnostics, tests).
    public var cpuFallbacks: Int { lock.lock(); defer { lock.unlock() }; return fallbacks }

    /// Memory pressure frees the device's frame buffers and tables (rebuilt by the next frame).
    var pressureToken: MemoryPressureMonitor.Token?

    init(device: ComputeGradeDevice, deviceName: String, isSoftware: Bool, pressure: MemoryPressureMonitor?) {
        self.device = device; self.deviceName = deviceName; self.isSoftware = isSoftware
        pressureToken = pressure?.observe { [weak device] _ in device?.releaseBuffers() }
    }

    /// Frees the device's frame-size buffers and cached tables now.
    public func releaseBuffers() { device.releaseBuffers() }

    public func render(_ grade: ColorGradeRenderer, _ rgba: inout [UInt8], width: Int, height: Int, time: Double, sourceKey: String?) {
        guard grade.isActive, width > 0, height > 0, rgba.count >= width * height * 4 else { return }
        let frame = grade.gpuFrame(width: width, height: height, time: time)
        let status = frame.withJob(tableKey: grade.signature) { job in
            rgba.withUnsafeMutableBufferPointer { px in px.baseAddress.map { device.grade(job, $0) } ?? -1 }
        }
        guard status != 0 else { return }
        lock.lock(); fallbacks += 1; let first = fallbacks == 1; lock.unlock()
        if first { FileHandle.standardError.write(Data("MpvfxColor: \(backend) grade failed (\(device.lastError)); graded on the CPU\n".utf8)) }
        grade.apply(&rgba, width: width, height: height, time: time)
    }
}

public enum ColorRendering {
    /// The renderer preview and export use: the GPU's (Metal, Vulkan or Direct3D 11) when this machine has a usable
    /// device and the kernels built, else the CPU port. `MPVFX_GPU=0` (or `MPVFX_COLOR_RENDERER=cpu`) forces the CPU
    /// port; `MPVFX_GPU=software` also accepts a software Vulkan/Direct3D device (see `GPUPolicy`).
    public static let shared: ColorRenderer = make()

    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> ColorRenderer {
        let policy = GPUPolicy(environment: environment)
        if policy == .off { return CPUColorRenderer() }
        #if canImport(MpvfxMetal)
        if let metal = MetalColorRenderer.makeDefault() { return metal }
        #endif
        if let compute = makeCompute(policy) { return compute }
        return CPUColorRenderer()
    }
}

extension ColorGradeRenderer {
    /// Grades `rgba` in place with `renderer` (default: the shared renderer, Metal on macOS).
    public func render(_ rgba: inout [UInt8], width: Int, height: Int, time: Double, sourceKey: String? = nil,
                       using renderer: ColorRenderer = ColorRendering.shared) {
        guard isActive, width > 0, height > 0, rgba.count >= width * height * 4 else { return }
        renderer.render(self, &rgba, width: width, height: height, time: time, sourceKey: sourceKey)
    }
}

// MARK: GPU inputs (platform independent, so the packing is checked on every platform)

/// One frame's GPU work (uniform layout: MpvfxColorShared.h): the uniform array, the advanced tables, the LUT and the multipass plan, all computed by
/// the same code the CPU port runs (`GradeProgram` setup), so both paths start from identical numbers.
struct GradeGPUFrame {
    var width: Int, height: Int
    var uniforms: [Float]
    /// 1024 texels each (RGB curves r,g,b,master; hue curves), empty when the grade has none.
    var curveRows: [SIMD4<Float>]
    var hueRows: [SIMD4<Float>]
    /// Five texels per enabled secondary.
    var secondaryTexels: [SIMD4<Float>]
    /// size³ entries, red fastest (the 3D texture's own layout), empty without a LUT.
    var lutSize: Int
    var lut: [SIMD4<Float>]
    /// Separable blur: radius and iteration count (0 = no blur pass).
    var blurRadius: Float, blurIterations: Int
    /// Half-size bloom target (0 x 0 = no bloom pass) and its pass radius.
    var bloomWidth: Int, bloomHeight: Int, bloomRadius: Float
    /// Kuwahara: radius in texels (0 = no pass), weight exponent and saturation.
    var kuwaharaRadius: Int, kuwaharaExponent: Float, kuwaharaSaturation: Float
    var blurAmount: Float
}

extension ColorGradeRenderer {
    func gpuFrame(width: Int, height: Int, time: Double) -> GradeGPUFrame {
        let p = base
        let u = p.u
        var a = [Float](repeating: 0, count: Int(GU_COUNT.rawValue) + EK.allCases.count)
        func set(_ k: MpvfxGU, _ v: Float) { a[Int(k.rawValue)] = v }
        func flag(_ b: Bool) -> Float { b ? 1 : 0 }
        set(GU_resX, Float(width)); set(GU_resY, Float(height))
        set(GU_exposure, u.exposure); set(GU_contrast, u.contrast); set(GU_highlights, u.highlights); set(GU_shadows, u.shadows)
        set(GU_whites, u.whites); set(GU_blacks, u.blacks); set(GU_temperature, u.temperature); set(GU_tint, u.tint)
        set(GU_vibrance, u.vibrance); set(GU_saturation, u.saturation)
        set(GU_vignette, u.vignette); set(GU_vignetteMidpoint, u.vignetteMidpoint); set(GU_vignetteRoundness, u.vignetteRoundness)
        set(GU_vignetteFeather, u.vignetteFeather); set(GU_grain, u.grain); set(GU_grainSize, u.grainSize); set(GU_grainRoughness, u.grainRoughness)
        let t = Swift.max(0, time)
        set(GU_effectTime, Float(t))
        set(GU_grainSeed, Float(seed) + Float((t * 60).rounded(.down)))
        set(GU_shadowHue, u.shadowWheel.x); set(GU_shadowAmount, u.shadowWheel.y); set(GU_shadowLevel, u.shadowWheel.z)
        set(GU_midHue, u.midtoneWheel.x); set(GU_midAmount, u.midtoneWheel.y); set(GU_midLevel, u.midtoneWheel.z)
        set(GU_highHue, u.highlightWheel.x); set(GU_highAmount, u.highlightWheel.y); set(GU_highLevel, u.highlightWheel.z)
        set(GU_rgbCurves, flag(u.rgbCurvesEnabled && p.curveRows.count == ColorCurves.lutSize))
        set(GU_hueCurves, flag(u.hueCurvesEnabled && p.hueRows.count == ColorCurves.lutSize))
        set(GU_secondaryCount, Float(Swift.min(u.secondaryCount, p.secondaryTexels.count / 5)))
        var lutTexels: [SIMD4<Float>] = []
        var lutSize = 0
        if u.lutEnabled, let lut = p.lut, lut.size >= 2, lut.table.count == lut.size * lut.size * lut.size {
            set(GU_lutEnabled, 1); set(GU_lutIntensity, u.lutIntensity); set(GU_lutSize, Float(lut.size))
            set(GU_lutTetra, flag(p.interpolation == .tetrahedral))
            set(GU_lutMinR, lut.domainMin.x); set(GU_lutMinG, lut.domainMin.y); set(GU_lutMinB, lut.domainMin.z)
            set(GU_lutMaxR, lut.domainMax.x); set(GU_lutMaxG, lut.domainMax.y); set(GU_lutMaxB, lut.domainMax.z)
            lutSize = lut.size
            lutTexels = lut.table.map { SIMD4($0.x, $0.y, $0.z, 1) }
        }
        set(GU_intensity, u.intensity); set(GU_paletteSize, u.paletteSize)
        set(GU_whiteBalanceGains, flag(u.whiteBalanceGains)); set(GU_pivot, u.pivot); set(GU_balanceOn, flag(u.balanceOn))
        set(GU_liftHue, u.liftWheel.x); set(GU_liftAmount, u.liftWheel.y); set(GU_liftLevel, u.liftWheel.z)
        set(GU_gammaHue, u.gammaWheel.x); set(GU_gammaAmount, u.gammaWheel.y); set(GU_gammaLevel, u.gammaWheel.z)
        set(GU_gainHue, u.gainWheel.x); set(GU_gainAmount, u.gainWheel.y); set(GU_gainLevel, u.gainWheel.z)
        set(GU_offsetHue, u.offsetWheel.x); set(GU_offsetAmount, u.offsetWheel.y); set(GU_offsetLevel, u.offsetWheel.z)
        for i in 0..<6 {
            let c = i < u.palette.count ? u.palette[i] : V3.zero
            a[Int(GU_p0r.rawValue) + i * 3] = c.x; a[Int(GU_p0r.rawValue) + i * 3 + 1] = c.y; a[Int(GU_p0r.rawValue) + i * 3 + 2] = c.z
        }
        for k in EK.allCases { a[Int(GU_COUNT.rawValue) + k.rawValue] = u.e[k.rawValue] }

        // Multipass plan: the same numbers `apply` hands prepareBlur / prepareBloom / prepareKuwahara.
        var f = GradeGPUFrame(width: width, height: height, uniforms: [], curveRows: p.curveRows,
                              hueRows: p.hueRows, secondaryTexels: p.secondaryTexels, lutSize: lutSize, lut: lutTexels,
                              blurRadius: 0, blurIterations: 0, bloomWidth: 0, bloomHeight: 0, bloomRadius: 0,
                              kuwaharaRadius: 0, kuwaharaExponent: 1, kuwaharaSaturation: 0, blurAmount: p.blurAmount)
        if p.blurAmount > 0 {
            f.blurRadius = 0.75 + pow(p.blurAmount, 1.35) * 32
            f.blurIterations = p.blurAmount > 0.55 ? 3 : 2
            a[Int(GU_blurOn.rawValue)] = 1
        }
        if p.bloomAmount > 0 {
            f.bloomWidth = Swift.max(1, Int((Float(width) / 2).rounded(.up))); f.bloomHeight = Swift.max(1, Int((Float(height) / 2).rounded(.up)))
            f.bloomRadius = p.ef(.bloomRadius) / 2
            a[Int(GU_bloomOn.rawValue)] = 1
        }
        if p.kuwaharaAmount > 0 {
            f.kuwaharaRadius = Int((mixf(2, 16, clampf(p.ef(.kuwaharaRadius), 0, 1)) + 0.5).rounded(.down))
            f.kuwaharaExponent = 1 + clampf(p.ef(.kuwaharaSharpness), 0, 1) * 8
            f.kuwaharaSaturation = clampf(p.ef(.kuwaharaSaturation), 0, 1) * 2
            a[Int(GU_kuwaharaOn.rawValue)] = 1
        }
        f.uniforms = a
        return f
    }
}
