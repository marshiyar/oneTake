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
#if canImport(CMpvfxVulkan)
import CMpvfxVulkan
#endif
#if os(Windows) && canImport(CMpvfxWin32)
import CMpvfxWin32
#endif

// The grade as GPU compute outside macOS: Vulkan on Linux (CMpvfxVulkan), Direct3D 11 on Windows (CMpvfxWin32's
// d3d11_grade.cpp). Both run kernels generated from the Metal shading body (scripts/gpu/gen-compute-shaders.py) on the
// frame `gpuFrame` packs, so the three GPU paths and the CPU port start from identical numbers. A frame the device
// cannot grade is graded by the CPU port instead, so preview and export never lose a frame.

/// Which renderer `ColorRendering.shared` may pick, from the environment: `MPVFX_GPU=0` (or the older
/// `MPVFX_COLOR_RENDERER=cpu`) forces the CPU port; `MPVFX_GPU=software` also accepts a software device (Mesa lavapipe,
/// Direct3D WARP), which is otherwise skipped because the CPU port is the better use of the same cores.
public enum GPUPolicy: Equatable, Sendable {
    case off, hardware, software

    public init(environment: [String: String]) {
        let gpu = environment["MPVFX_GPU"]?.lowercased()
        if gpu == "0" || gpu == "off" || gpu == "cpu" || environment["MPVFX_COLOR_RENDERER"]?.lowercased() == "cpu" { self = .off }
        else if gpu == "software" { self = .software }
        else { self = .hardware }
    }

    /// Whether a device may grade under this policy: a software device (lavapipe, WARP, the Microsoft Basic Render
    /// Driver) only under `.software`.
    public func accepts(isSoftware: Bool) -> Bool {
        switch self {
        case .off: return false
        case .hardware: return !isSoftware
        case .software: return true
        }
    }

    /// Whether a DXGI adapter is a software rasteriser (MpvfxGpuPlan.h, the test d3d11_grade.cpp applies):
    /// DXGI_ADAPTER_FLAG_SOFTWARE, or the Microsoft Basic Render Driver (vendor 0x1414, device 0x8c).
    public static func isSoftwareAdapter(vendorID: UInt32, deviceID: UInt32, flags: UInt32) -> Bool {
        mpvfx_dxgi_adapter_is_software(vendorID, deviceID, flags) != 0
    }
}

extension GradeGPUFrame {
    /// Calls `body` with the C job (MpvfxGpuJob.h) viewing this frame's arrays; the pointers live for the call only.
    func withJob<R>(tableKey: String, _ body: (UnsafePointer<MpvfxGpuGradeJob>) -> R) -> R {
        Self.withFloats([curveRows, hueRows, secondaryTexels, lut][...]) { tables in
            uniforms.withUnsafeBufferPointer { u in
                tableKey.withCString { key in
                    var job = MpvfxGpuGradeJob()
                    job.width = Int32(width); job.height = Int32(height)
                    job.uniforms = u.baseAddress; job.uniformCount = Int32(u.count)
                    job.curves = tables[0]; job.curveTexels = Int32(curveRows.count)
                    job.hue = tables[1]; job.hueTexels = Int32(hueRows.count)
                    job.secondaries = tables[2]; job.secondaryTexels = Int32(secondaryTexels.count)
                    job.lut = tables[3]; job.lutSize = Int32(lut.isEmpty ? 0 : lutSize)
                    job.blurRadius = blurRadius; job.blurAmount = blurAmount; job.blurIterations = Int32(blurIterations)
                    job.bloomWidth = Int32(bloomWidth); job.bloomHeight = Int32(bloomHeight); job.bloomRadius = bloomRadius
                    job.kuwaharaRadius = Int32(kuwaharaRadius); job.kuwaharaExponent = kuwaharaExponent
                    job.kuwaharaSaturation = kuwaharaSaturation; job.tableKey = key
                    return withUnsafePointer(to: &job) { body($0) }
                }
            }
        }
    }

    /// Float pointers to each array's storage (nil for an empty one), valid inside `body`.
    static func withFloats<R>(_ arrays: ArraySlice<[SIMD4<Float>]>, _ pinned: [UnsafePointer<Float>?] = [],
                              _ body: ([UnsafePointer<Float>?]) -> R) -> R {
        guard let first = arrays.first else { return body(pinned) }
        return first.withUnsafeBytes { raw in
            withFloats(arrays.dropFirst(), pinned + [raw.isEmpty ? nil : raw.bindMemory(to: Float.self).baseAddress], body)
        }
    }
}

/// A compute device behind a flat C interface: grades one packed frame in place, 0 on success.
protocol ComputeGradeDevice: AnyObject {
    func grade(_ job: UnsafePointer<MpvfxGpuGradeJob>, _ rgba: UnsafeMutablePointer<UInt8>) -> Int32
    var lastError: String { get }
    /// Frees the frame-size buffers and cached tables (memory pressure).
    func releaseBuffers()
}

/// Both native create functions write a NUL-terminated UTF-8 diagnostic into a fixed buffer.
/// Ignore padding after the first NUL and repair invalid UTF-8, as String(cString:) does.
func computeErrorMessage(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

#if canImport(CMpvfxVulkan)
/// The grade as Vulkan compute (Linux).
public final class VulkanColorRenderer: ComputeColorRenderer, @unchecked Sendable {
    public override var backend: String { "vulkan" }

    final class Device: ComputeGradeDevice {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { mpvfx_vk_destroy(handle) }
        func grade(_ job: UnsafePointer<MpvfxGpuGradeJob>, _ rgba: UnsafeMutablePointer<UInt8>) -> Int32 { mpvfx_vk_render(handle, job, rgba) }
        var lastError: String { String(cString: mpvfx_vk_last_error(handle)) }
        func releaseBuffers() { mpvfx_vk_release_buffers(handle) }
    }

    public struct Unavailable: Error, CustomStringConvertible { public let description: String }

    /// - Parameters:
    ///   - allowSoftware: accept Mesa lavapipe (tests, `MPVFX_GPU=software`).
    ///   - spirvDirectory: kernels from hlsl_<kernel>.spv files there instead of the built-in ones (tests: the
    ///     Direct3D 11 shader source compiled by glslang).
    ///   - pressure: memory-pressure warnings free the device buffers (nil: none).
    public init(allowSoftware: Bool, spirvDirectory: String? = nil, pressure: MemoryPressureMonitor? = .shared) throws {
        var err = [CChar](repeating: 0, count: 512)
        let made: OpaquePointer? = err.withUnsafeMutableBufferPointer { e in
            if let dir = spirvDirectory { return dir.withCString { mpvfx_vk_create(allowSoftware ? MPVFX_VK_ALLOW_SOFTWARE : 0, $0, e.baseAddress, Int32(e.count)) } }
            return mpvfx_vk_create(allowSoftware ? MPVFX_VK_ALLOW_SOFTWARE : 0, nil, e.baseAddress, Int32(e.count))
        }
        guard let handle = made else { throw Unavailable(description: computeErrorMessage(err)) }
        super.init(device: Device(handle), deviceName: String(cString: mpvfx_vk_device_name(handle)),
                   isSoftware: mpvfx_vk_device_is_software(handle) != 0, pressure: pressure)
    }

    /// Bytes of device memory held for the current frame size (tests).
    public var residentBytes: Int64 { (device as? Device).map { mpvfx_vk_resident_bytes($0.handle) } ?? 0 }
}
#endif

#if os(Windows) && canImport(CMpvfxWin32)
/// The grade as Direct3D 11 compute (Windows).
public final class D3D11ColorRenderer: ComputeColorRenderer, @unchecked Sendable {
    public override var backend: String { "d3d11" }

    final class Device: ComputeGradeDevice {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { mpvfx_d3d11_grade_destroy(handle) }
        func grade(_ job: UnsafePointer<MpvfxGpuGradeJob>, _ rgba: UnsafeMutablePointer<UInt8>) -> Int32 { mpvfx_d3d11_grade_render(handle, UnsafeRawPointer(job), rgba) }
        var lastError: String { String(cString: mpvfx_d3d11_grade_last_error(handle)) }
        func releaseBuffers() { mpvfx_d3d11_grade_release_buffers(handle) }
    }

    public struct Unavailable: Error, CustomStringConvertible { public let description: String }

    /// - Parameter warp: the WARP software device (tests on machines without a GPU, `MPVFX_GPU=software` fallback).
    public init(warp: Bool, pressure: MemoryPressureMonitor? = .shared) throws {
        var err = [CChar](repeating: 0, count: 512)
        let made: OpaquePointer? = err.withUnsafeMutableBufferPointer { e in
            mpvfx_d3d11_grade_create(warp ? MPVFX_D3D11_WARP : 0, e.baseAddress, Int32(e.count))
        }
        guard let handle = made else { throw Unavailable(description: computeErrorMessage(err)) }
        super.init(device: Device(handle), deviceName: String(cString: mpvfx_d3d11_grade_device_name(handle)),
                   isSoftware: warp || mpvfx_d3d11_grade_device_is_software(handle) != 0, pressure: pressure)
    }
}
#endif

extension ColorRendering {
    /// The compute renderer for this platform under `policy`, or nil (no device, no API, or the policy is off). The
    /// reason a device was refused goes to stderr once.
    static func makeCompute(_ policy: GPUPolicy) -> ColorRenderer? {
        guard policy != .off else { return nil }
        var reasons: [String] = []
        /// The device when the policy accepts it; a software device under the default policy is refused here too, so
        /// a backend that misreports its adapter still cannot take the frames from the CPU port.
        func accepted(_ r: ComputeColorRenderer) -> ComputeColorRenderer? {
            if policy.accepts(isSoftware: r.isSoftware) { return r }
            reasons.append("\(r.backend): \(r.deviceName) is a software device")
            return nil
        }
        #if canImport(CMpvfxVulkan)
        do { if let r = accepted(try VulkanColorRenderer(allowSoftware: policy == .software)) { return r } } catch {
            reasons.append("Vulkan: \(error)")
        }
        #endif
        #if os(Windows) && canImport(CMpvfxWin32)
        do { if let r = accepted(try D3D11ColorRenderer(warp: false)) { return r } } catch { reasons.append("Direct3D 11: \(error)") }
        if policy == .software {
            do { if let r = accepted(try D3D11ColorRenderer(warp: true)) { return r } } catch { reasons.append("WARP: \(error)") }
        }
        #endif
        if !reasons.isEmpty {
            FileHandle.standardError.write(Data("MpvfxColor: no GPU grade (\(reasons.joined(separator: "; "))); grading on the CPU\n".utf8))
        }
        return nil
    }
}
