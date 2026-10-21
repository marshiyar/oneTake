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
import MpvfxColor
import MpvfxShared
#if canImport(Metal)
import Metal
#endif

// Grade speed, CPU port vs the GPU renderer (Vulkan on Linux, Direct3D 11 on Windows, Metal on macOS), per frame size, end to
// end (upload, every pass, read-back), and the two outputs' difference at that size. Build with -c release:
//   swift run -c release MpvfxColorBench [frames]        (default 5 timed frames after one warm-up)
// MPVFX_GPU=software also benchmarks a software device (lavapipe, WARP): its numbers show correctness, not speed.
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
let frames = CommandLine.arguments.count > 1 ? max(1, Int(CommandLine.arguments[1]) ?? 5) : 5

func params(_ s: String) -> ColorGradeParams {
    do {
        if case .object(let o) = try JSONDecoder().decode(NativeJSONValue.self, from: Data(s.utf8)), let p = ColorGradeParams(json: o) { return p }
    } catch { fatalError("bad grade json \(s): \(error)") }
    fatalError("not a grade: \(s)")
}

/// Gradients, a hard edge and fine texture (the parity tests' card, regenerated here).
func card(_ w: Int, _ h: Int) -> [UInt8] {
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4, fx = Double(x) / Double(max(1, w - 1)), fy = Double(y) / Double(max(1, h - 1))
        let r = fx + sin(Double(x) * 0.9 + Double(y) * 0.3) * 0.03, g = fy, b = x < w / 2 ? 0.16 : 0.86
        px[i] = UInt8(max(0, min(255, (r * 255).rounded()))); px[i + 1] = UInt8((g * 255).rounded()); px[i + 2] = UInt8((b * 255).rounded())
    } }
    return px
}

func median(_ r: ColorRenderer, _ g: ColorGradeRenderer, _ src: [UInt8], _ size: SIMD2<Int>) -> (ms: Double, out: [UInt8]) {
    var out = src
    r.render(g, &out, width: size.x, height: size.y, time: 0.5)  // warm-up: pipelines, buffers, tables
    var times: [Double] = []
    for i in 0..<frames {
        out = src
        let t = now()
        r.render(g, &out, width: size.x, height: size.y, time: 0.5 + Double(i) / 30)
        times.append((now() - t) * 1000)
    }
    return (times.sorted()[times.count / 2], out)
}

/// The GPU renderer under test, with what the report needs from it: Vulkan on Linux, Direct3D 11 on Windows, Metal
/// on macOS (the system default device, the app's own `ColorRendering.shared` choice).
struct GPU {
    let renderer: any ColorRenderer
    let backend: String
    let deviceName: String
    let isSoftware: Bool
    let cpuFallbacks: () -> Int
}

/// Whether this build has a GPU renderer at all: Linux has one only when the Vulkan headers were installed at build
/// time (Package.swift adds CMpvfxVulkan then), so a Linux build without them benchmarks the CPU port alone.
#if canImport(CMpvfxVulkan) || os(Windows) || canImport(MpvfxMetal)
let gpuBuilt = true
#else
let gpuBuilt = false
#endif

func gpuRenderer() -> GPU? {
    #if canImport(CMpvfxVulkan) || os(Windows) || canImport(MpvfxMetal)
    let software = ProcessInfo.processInfo.environment["MPVFX_GPU"]?.lowercased() == "software"
    do {
        #if canImport(CMpvfxVulkan)
        let r = try VulkanColorRenderer(allowSoftware: software)
        return GPU(renderer: r, backend: r.backend, deviceName: r.deviceName, isSoftware: r.isSoftware, cpuFallbacks: { r.cpuFallbacks })
        #elseif os(Windows)
        let r: D3D11ColorRenderer
        do { r = try D3D11ColorRenderer(warp: false) } catch { if !software { throw error }; r = try D3D11ColorRenderer(warp: true) }
        return GPU(renderer: r, backend: r.backend, deviceName: r.deviceName, isSoftware: r.isSoftware, cpuFallbacks: { r.cpuFallbacks })
        #else
        guard let r = MetalColorRenderer.makeDefault() else { print("GPU compute renderer unavailable: no Metal device or the kernels did not load"); return nil }
        // GitHub's hosted macOS runners expose "Apple Paravirtual device": a virtual GPU, not the speed of a real one.
        let name = r.device.name
        return GPU(renderer: r, backend: r.backend, deviceName: name, isSoftware: name.contains("Paravirtual"), cpuFallbacks: { r.cpuFallbacks })
        #endif
    } catch {
        print("GPU compute renderer unavailable: \(error)")
        return nil
    }
    #else
    print("GPU compute renderer unavailable: built without a GPU backend (Linux without the Vulkan headers, libvulkan-dev)")
    return nil
    #endif
}

let cases: [(String, String)] = [
    ("grade (primary, wheels, curves)", #"{"adjust":{"exposure":0.3,"contrast":0.2,"saturation":0.15,"temperature":0.2},"wheels":{"shadows":{"hue":210,"amount":0.4,"level":0.1}},"curves":{"master":[[0,0.05],[0.5,0.55],[1,0.95]]}}"#),
    ("heavy: kuwahara + crosshatch + ascii + grade", #"{"adjust":{"exposure":0.2,"contrast":0.2,"saturation":0.1},"effects":{"kuwahara":1,"kuwaharaRadius":1,"crosshatch":0.6,"crosshatchEdges":1,"ascii":0.5,"asciiSize":0.1,"asciiRotation":1}}"#),
    ("blur 1 + bloom 2 + grain", #"{"effects":{"blur":1,"bloom":2},"details":{"grain":1}}"#),
]
let cpu = CPUColorRenderer()
let gpu = gpuRenderer()
if gpu == nil && gpuBuilt {
    print("no GPU compute device (MPVFX_GPU=software accepts lavapipe / WARP; macOS needs a Metal device)")
    exit(1)
}
if let gpu {
    print("CPU port: \(ProcessInfo.processInfo.activeProcessorCount) cores; GPU: \(gpu.backend) on \(gpu.deviceName)\(gpu.isSoftware ? " (software device: correctness only, not GPU speed)" : ""); median of \(frames) frames")
    print("| frame | grade | CPU ms | GPU ms | speed-up | max diff | channels > 1 |")
    print("|---|---|---:|---:|---:|---:|---:|")
} else {
    print("CPU port: \(ProcessInfo.processInfo.activeProcessorCount) cores; GPU: unavailable in this build (CPU port only); median of \(frames) frames")
    print("| frame | grade | CPU ms |")
    print("|---|---|---:|")
}
for (w, h) in [(1920, 1080), (3840, 2160)] {
    let src = card(w, h)
    for (name, json) in cases {
        let g = ColorGradeRenderer(params: params(json), seedKey: "clip:bench")
        let c = median(cpu, g, src, SIMD2(w, h))
        guard let gpu else {
            print(String(format: "| %dx%d | %@ | %.1f |", w, h, name, c.ms))
            continue
        }
        let q = median(gpu.renderer, g, src, SIMD2(w, h))
        var maxDiff = 0, over1 = 0
        for i in 0..<c.out.count { let d = abs(Int(c.out[i]) - Int(q.out[i])); maxDiff = max(maxDiff, d); if d > 1 { over1 += 1 } }
        print(String(format: "| %dx%d | %@ | %.1f | %.1f | %.1fx | %d | %d |", w, h, name, c.ms, q.ms, c.ms / q.ms, maxDiff, over1))
    }
}
if let gpu, gpu.cpuFallbacks() > 0 { print("GPU frames that fell back to the CPU: \(gpu.cpuFallbacks())"); exit(1) }
