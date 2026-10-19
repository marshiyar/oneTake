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
#if canImport(CMpvfxVulkan) || (os(Windows) && canImport(CMpvfxWin32))
import Foundation
import XCTest
@testable import MpvfxColor
import MpvfxShared

/// The compute grade against the CPU reference (`GradeProgram`), control by control and effect by effect, with the
/// Metal parity tests' tolerances (MetalColorRendererTests). Linux: Vulkan on Mesa lavapipe (software Vulkan; the CI
/// image installs mesa-vulkan-drivers); Windows: Direct3D 11 on WARP (the windows-2022 runner has no GPU).
final class ComputeColorRendererTests: XCTestCase {
    var gpu: ComputeColorRenderer!

    override func setUpWithError() throws {
        #if canImport(CMpvfxVulkan)
        do { gpu = try VulkanColorRenderer(allowSoftware: true) } catch {
            XCTFail("no Vulkan device (install mesa-vulkan-drivers for lavapipe): \(error)")
            throw error
        }
        #else
        gpu = try D3D11ColorRenderer(warp: true)
        #endif
    }

    func testDeviceLoads() {
        print("compute grade (\(gpu.backend)) on \(gpu.deviceName), software: \(gpu.isSoftware)")
        XCTAssertFalse(gpu.deviceName.isEmpty)
    }

    /// Every adjust key, wheel, curve mode, secondary, LUT mode, finish detail and stylize effect (with its settings
    /// and variants), at two sizes and two times: the case list and the thresholds of the Metal test. Deterministic
    /// controls stay within 1 level on all but 0.1% of channels (over 2 levels on at most 0.05%, mean under 0.02);
    /// effects built on sin-hash noise get 2% of channels over 2 levels and a mean under 0.5 levels.
    func testEveryControlAndEffectMatchesTheCPUReference() {
        print(assertEveryCaseMatches(gpu, "\(gpu.backend)"))
        XCTAssertEqual(gpu.cpuFallbacks, 0, "every frame was graded on the GPU")
    }

    func testHeavyFrameMatchesAtPreviewSize() {
        let r = ColorGradeRenderer(params: GradeReferenceCases.params(GradeReferenceCases.heavyJSON), seedKey: "clip:heavy")
        let (w, h) = (640, 360)
        let src = GradeReferenceCases.card(width: w, height: h)
        var cpu = src; r.apply(&cpu, width: w, height: h, time: 1.25)
        var out = src; gpu.render(r, &out, width: w, height: h, time: 1.25)
        let d = GradeDiff(out, cpu)
        print("\(gpu.backend) vs CPU heavy 640x360: \(d)")
        XCTAssertLessThanOrEqual(d.over1, d.count / 1000, "\(d)")
        XCTAssertLessThan(d.mean, 0.02, "\(d)")
        XCTAssertEqual(gpu.cpuFallbacks, 0)
    }

    func testRepeatedFramesAndCachedTablesAreStable() {
        let c = GradeReferenceCases.all.first { $0.name == "lut.tetrahedral" }!
        let r = GradeReferenceCases.renderer(c)
        let src = GradeReferenceCases.card(width: 64, height: 48)
        var a = src, b = src
        gpu.render(r, &a, width: 64, height: 48, time: 0)
        gpu.render(r, &b, width: 64, height: 48, time: 0)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, src)
        // A different grade after the cached one, then the first again: the tables follow the grade.
        let other = GradeReferenceCases.renderer(GradeReferenceCases.all.first { $0.name == "curve.rgb" }!)
        var o = src; gpu.render(other, &o, width: 64, height: 48, time: 0)
        var cpuOther = src; other.apply(&cpuOther, width: 64, height: 48, time: 0)
        GradeDiff(o, cpuOther).assertWithinParityTolerance(noisy: false, "curve.rgb after lut.tetrahedral")
        var again = src; gpu.render(r, &again, width: 64, height: 48, time: 0)
        XCTAssertEqual(again, a)
        // An inactive grade leaves the frame alone.
        var n = src
        ColorGradeRenderer(params: GradeReferenceCases.params(#"{"preset":"neutral"}"#)).render(&n, width: 64, height: 48, time: 0, using: gpu)
        XCTAssertEqual(n, src)
    }

    /// Frame sizes change between calls (preview and export interleaved): each size grades correctly.
    func testAlternatingFrameSizes() {
        let r = GradeReferenceCases.renderer(GradeReferenceCases.all.first { $0.name == "effect.bloom" }!)
        assertFrameMatches(r, 96, 54)
        assertFrameMatches(r, 33, 17)
        assertFrameMatches(r, 96, 54)
        assertFrameMatches(r, 1, 1)
        assertFrameMatches(r, 2, 3)
        XCTAssertEqual(gpu.cpuFallbacks, 0)
    }

    func assertFrameMatches(_ r: ColorGradeRenderer, _ w: Int, _ h: Int, line: UInt = #line) {
        let src = GradeReferenceCases.card(width: w, height: h)
        var cpu = src; r.apply(&cpu, width: w, height: h, time: 0.3)
        var out = src; gpu.render(r, &out, width: w, height: h, time: 0.3)
        GradeDiff(out, cpu).assertWithinParityTolerance(noisy: false, "\(w)x\(h)", line: line)
    }

    #if canImport(CMpvfxVulkan)
    /// A memory-pressure warning frees the device buffers; the next frame allocates them again and still matches.
    func testMemoryPressureFreesTheDeviceBuffers() throws {
        let monitor = MemoryPressureMonitor()
        let vk = try VulkanColorRenderer(allowSoftware: true, pressure: monitor)
        let r = GradeReferenceCases.renderer(GradeReferenceCases.all.first { $0.name == "effect.blurKuwahara" }!)
        let src = GradeReferenceCases.card(width: 120, height: 68)
        var cpu = src; r.apply(&cpu, width: 120, height: 68, time: 0.4)
        var a = src; vk.render(r, &a, width: 120, height: 68, time: 0.4)
        XCTAssertGreaterThanOrEqual(vk.residentBytes, Int64(120 * 68 * 4 * 6), "upload, read-back, source, output, blur, Kuwahara")
        monitor.simulate(.warning)
        XCTAssertEqual(vk.residentBytes, 0)
        var b = src; vk.render(r, &b, width: 120, height: 68, time: 0.4)
        XCTAssertEqual(a, b)
        GradeDiff(b, cpu).assertWithinParityTolerance(noisy: false, "after the pressure release")
        XCTAssertEqual(vk.cpuFallbacks, 0)
    }
    #endif

    func testConcurrentFramesFromSeveralThreads() {
        let r = GradeReferenceCases.renderer(GradeReferenceCases.all.first { $0.name == "effect.kuwahara" }!)
        let src = GradeReferenceCases.card(width: 96, height: 54)
        var ref = src; r.apply(&ref, width: 96, height: 54, time: 0.5)
        let results = UnsafeMutableBufferPointer<Int>.allocate(capacity: 8); defer { results.deallocate() }
        let renderer = gpu!
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            var px = src; renderer.render(r, &px, width: 96, height: 54, time: 0.5)
            results[i] = GradeDiff(px, ref).max
        }
        XCTAssertTrue(results.allSatisfy { $0 <= 3 }, "\(Array(results))")
    }
}

#if canImport(CMpvfxVulkan)
/// The Direct3D 11 kernels' source (scripts/gpu/generated/grade.hlsl, which d3dcompiler compiles on Windows) run here:
/// glslang's HLSL front end turns it into SPIR-V for lavapipe, so every case of the parity test checks the Windows
/// shader text on Linux too. Needs glslang-tools and spirv-tools (installed in CI).
final class HLSLSourceOnVulkanTests: XCTestCase {
    static func shell(_ command: String) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testDirect3DShaderSourceMatchesTheCPUReference() throws {
        let tools = ["glslangValidator", "spirv-opt", "spirv-val", "spirv-as"]
        let missing = tools.filter { Self.shell("command -v \($0)").status != 0 }
        try XCTSkipUnless(missing.isEmpty, "\(missing.joined(separator: ", ")) not installed (glslang-tools, spirv-tools)")
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = package.appendingPathComponent("scripts/gpu/gen-compute-shaders.py").path
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-hlsl-\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: dir) }
        let built = Self.shell("python3 -I '\(script)' --hlsl-spirv-only '\(dir.path)'")
        XCTAssertEqual(built.status, 0, built.output)
        let gpu = try VulkanColorRenderer(allowSoftware: true, spirvDirectory: dir.path)
        print(assertEveryCaseMatches(gpu, "HLSL source on \(gpu.deviceName)"))
        XCTAssertEqual(gpu.cpuFallbacks, 0)
    }
}
#endif

/// The renderer choice: `MPVFX_GPU=0` forces the CPU, `software` accepts lavapipe/WARP, the default only hardware.
final class GPUPolicyTests: XCTestCase {
    func testEnvironmentSelectsThePolicy() {
        XCTAssertEqual(GPUPolicy(environment: [:]), .hardware)
        XCTAssertEqual(GPUPolicy(environment: ["MPVFX_GPU": "0"]), .off)
        XCTAssertEqual(GPUPolicy(environment: ["MPVFX_GPU": "off"]), .off)
        XCTAssertEqual(GPUPolicy(environment: ["MPVFX_COLOR_RENDERER": "cpu"]), .off)
        XCTAssertEqual(GPUPolicy(environment: ["MPVFX_GPU": "software"]), .software)
        XCTAssertEqual(GPUPolicy(environment: ["MPVFX_GPU": "1"]), .hardware)
    }

    /// The default policy takes hardware devices only; a DXGI adapter is software when it says so or when it is the
    /// Microsoft Basic Render Driver (what a GPU-less Windows runner reports, without the software flag).
    func testSoftwareDevicesNeedTheSoftwarePolicy() {
        XCTAssertTrue(GPUPolicy.hardware.accepts(isSoftware: false))
        XCTAssertFalse(GPUPolicy.hardware.accepts(isSoftware: true))
        XCTAssertTrue(GPUPolicy.software.accepts(isSoftware: true))
        XCTAssertTrue(GPUPolicy.software.accepts(isSoftware: false))
        XCTAssertFalse(GPUPolicy.off.accepts(isSoftware: false))
        XCTAssertTrue(GPUPolicy.isSoftwareAdapter(vendorID: 0x1414, deviceID: 0x8c, flags: 0), "Basic Render Driver")
        XCTAssertTrue(GPUPolicy.isSoftwareAdapter(vendorID: 0x1414, deviceID: 0x8c, flags: 2))
        XCTAssertTrue(GPUPolicy.isSoftwareAdapter(vendorID: 0x10de, deviceID: 0x2684, flags: 2), "DXGI_ADAPTER_FLAG_SOFTWARE")
        XCTAssertFalse(GPUPolicy.isSoftwareAdapter(vendorID: 0x10de, deviceID: 0x2684, flags: 0), "an NVIDIA GPU")
        XCTAssertFalse(GPUPolicy.isSoftwareAdapter(vendorID: 0x8086, deviceID: 0x8c, flags: 1), "Intel, remote flag only")
        XCTAssertFalse(GPUPolicy.isSoftwareAdapter(vendorID: 0x1002, deviceID: 0x1414, flags: 0), "AMD")
        let defaultPolicy = GPUPolicy(environment: [:]), softwarePolicy = GPUPolicy(environment: ["MPVFX_GPU": "software"])
        XCTAssertFalse(defaultPolicy.accepts(isSoftware: GPUPolicy.isSoftwareAdapter(vendorID: 0x1414, deviceID: 0x8c, flags: 0)))
        XCTAssertTrue(softwarePolicy.accepts(isSoftware: GPUPolicy.isSoftwareAdapter(vendorID: 0x1414, deviceID: 0x8c, flags: 0)))
    }

    func testGPUZeroForcesTheCPU() {
        XCTAssertEqual(ColorRendering.make(environment: ["MPVFX_GPU": "0"]).backend, "cpu")
    }

    /// With software devices allowed the shared choice is the compute renderer (lavapipe / WARP are present in CI).
    func testSoftwarePolicyPicksTheComputeRenderer() {
        let r = ColorRendering.make(environment: ["MPVFX_GPU": "software"])
        #if canImport(CMpvfxVulkan)
        XCTAssertEqual(r.backend, "vulkan")
        #else
        XCTAssertEqual(r.backend, "d3d11")
        #endif
    }

    /// The default never picks a software device: without a hardware GPU it is the CPU port.
    func testDefaultPolicyRefusesSoftwareDevices() {
        let r = ColorRendering.make(environment: [:])
        let compute = r as? ComputeColorRenderer
        XCTAssertFalse(compute?.isSoftware ?? false, "\(compute?.deviceName ?? "") is a software device")
        XCTAssertTrue(compute != nil || r.backend == "cpu", r.backend)
    }
}

/// Every reference case (the Metal parity test's list) at two sizes and two times through `gpu`, each held to the
/// Metal parity tolerance; returns the per-case report.
func assertEveryCaseMatches(_ gpu: ColorRenderer, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> String {
    var report = "\(label) vs CPU reference:\n"
    for c in GradeReferenceCases.all {
        for (w, h, time) in [(160, 90, 0.7), (101, 57, 2.35)] {
            let r = GradeReferenceCases.renderer(c)
            let src = GradeReferenceCases.card(width: w, height: h)
            var cpu = src; r.apply(&cpu, width: w, height: h, time: time)
            var out = src; gpu.render(r, &out, width: w, height: h, time: time)
            let d = GradeDiff(out, cpu)
            report += "  \(c.name) \(w)x\(h): \(d)\n"
            d.assertWithinParityTolerance(noisy: c.noisy, "\(label) \(c.name) \(w)x\(h)", file: file, line: line)
        }
    }
    return report
}
#endif
