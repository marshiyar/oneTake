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
#if canImport(Metal)
import Foundation
import Metal
import CMpvfxColorShared

/// One frame of grading work, as plain numbers (built by MpvfxColor's `ColorGradeRenderer.gpuFrame`): the flat
/// uniform array (layout in MpvfxColorShared.h), the 1D tables, the 3D LUT and the multipass plan.
public struct MetalGradeJob {
    public var width: Int, height: Int
    public var uniforms: [Float]
    public var curveRows: [SIMD4<Float>], hueRows: [SIMD4<Float>], secondaryTexels: [SIMD4<Float>]
    public var lutSize: Int, lut: [SIMD4<Float>]
    public var blurRadius: Float, blurIterations: Int, blurAmount: Float
    public var bloomWidth: Int, bloomHeight: Int, bloomRadius: Float
    public var kuwaharaRadius: Int, kuwaharaExponent: Float, kuwaharaSaturation: Float
    /// Identifies the tables and LUT (the grade's signature): equal keys reuse the textures built for them.
    public var tableKey: String
    /// Identifies the source picture (lane, frame, size). A frame whose key matches one already resident on the GPU is
    /// not uploaded again, so a parameter change re-runs only the kernels. nil: always upload.
    public var sourceKey: String? = nil
    public init(width: Int, height: Int, uniforms: [Float], curveRows: [SIMD4<Float>], hueRows: [SIMD4<Float>], secondaryTexels: [SIMD4<Float>],
                lutSize: Int, lut: [SIMD4<Float>], blurRadius: Float, blurIterations: Int, blurAmount: Float,
                bloomWidth: Int, bloomHeight: Int, bloomRadius: Float, kuwaharaRadius: Int, kuwaharaExponent: Float, kuwaharaSaturation: Float,
                tableKey: String) {
        self.width = width; self.height = height; self.uniforms = uniforms; self.curveRows = curveRows; self.hueRows = hueRows
        self.secondaryTexels = secondaryTexels; self.lutSize = lutSize; self.lut = lut; self.blurRadius = blurRadius
        self.blurIterations = blurIterations; self.blurAmount = blurAmount; self.bloomWidth = bloomWidth; self.bloomHeight = bloomHeight
        self.bloomRadius = bloomRadius; self.kuwaharaRadius = kuwaharaRadius; self.kuwaharaExponent = kuwaharaExponent
        self.kuwaharaSaturation = kuwaharaSaturation; self.tableKey = tableKey
    }
}

public struct MetalGradeError: Error, CustomStringConvertible { public let description: String }

/// Pipelines and dispatch for the kernels in Shaders/MpvfxColor.metal.
///
/// The library is the bundle's precompiled default.metallib when the build produced one; otherwise the bundled
/// MpvfxColor.metal (with MpvfxColorShared.h inlined) is compiled at runtime with precise math. The frame is copied
/// once into a shared-storage buffer that a linear texture views directly (unified memory: no staging texture, no
/// blit); every intermediate stays in private GPU textures; the graded frame lands in a second buffer-backed texture
/// that is read back. The 3D LUT and the 1D curve / hue-curve / secondary tables are built once per `tableKey`.
public final class MetalGradePipeline: @unchecked Sendable {
    public let device: MTLDevice
    /// Where the kernels came from: "default.metallib" or "MpvfxColor.metal (compiled at runtime)".
    public let librarySource: String
    let queue: MTLCommandQueue
    let blurPipe: MTLComputePipelineState, momentsPipe: MTLComputePipelineState
    let resolvePipe: MTLComputePipelineState, gradePipe: MTLComputePipelineState
    let dummy2D: MTLTexture, dummy1D: MTLTexture, dummy3D: MTLTexture

    let lock = NSLock()
    var pool: [Targets] = []
    var tables: [String: (tables: Tables, tick: Int)] = [:]
    var tick = 0
    /// Frames whose upload was skipped because their source was already on the GPU (diagnostics, tests).
    public private(set) var uploadsSkipped = 0

    /// SwiftPM's resource bundle for this target (package "Mpvfx", target "MpvfxMetal").
    public static let resourceBundleName = "Mpvfx_MpvfxMetal.bundle"

    /// The kernels' resource bundle, or nil when it is nowhere it can be. Never `Bundle.module`: SwiftPM's accessor
    /// falls back to the absolute build folder of the machine that built the app and calls fatalError without it, so
    /// the installed app (bundle in Contents/Resources, packaging/macos/package.sh) crashed at launch on every Mac but
    /// the one that built it, and launched there only because of that machine's build folder. Searched, all inside
    /// what runs: the app's Resources and folder (installed app), the executable's folder (`swift run`), and only
    /// under XCTest the folder of the test bundle (`swift test`); never a path recorded at build time.
    public static func resourceBundle() -> Bundle? {
        let host = Bundle(for: MetalGradePipeline.self).bundleURL
        return resourceBundle(searching: [Bundle.main.resourceURL, Bundle.main.bundleURL,
                                          Bundle.main.executableURL?.deletingLastPathComponent(),
                                          host.pathExtension == "xctest" ? host.deletingLastPathComponent() : nil])
    }

    /// The first `resourceBundleName` inside one of `places`, in order; nil when none holds it.
    public static func resourceBundle(searching places: [URL?]) -> Bundle? {
        for case let dir? in places {
            if let bundle = Bundle(url: dir.appendingPathComponent(resourceBundleName)) { return bundle }
        }
        return nil
    }

    public static func loadLibrary(device: MTLDevice) throws -> (library: MTLLibrary, source: String) {
        guard let bundle = resourceBundle() else {
            throw MetalGradeError(description: "\(resourceBundleName) is missing beside the app and the executable")
        }
        if let lib = try? device.makeDefaultLibrary(bundle: bundle), lib.functionNames.contains("mpvfx_grade") {
            return (lib, "default.metallib")
        }
        func resource(_ name: String, _ ext: String) -> URL? {
            bundle.url(forResource: name, withExtension: ext) ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Shaders")
        }
        guard let shaderURL = resource("MpvfxColor", "metal"), let headerURL = resource("MpvfxColorShared", "h") else {
            throw MetalGradeError(description: "MpvfxColor.metal is missing from the MpvfxMetal resource bundle")
        }
        let header = try String(contentsOf: headerURL, encoding: .utf8)
        let shader = try String(contentsOf: shaderURL, encoding: .utf8)
        let include = "#include \"MpvfxColorShared.h\""
        guard shader.contains(include) else { throw MetalGradeError(description: "MpvfxColor.metal does not include MpvfxColorShared.h") }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        return (try device.makeLibrary(source: shader.replacingOccurrences(of: include, with: header), options: options),
                "MpvfxColor.metal (compiled at runtime)")
    }

    public init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw MetalGradeError(description: "no command queue") }
        queue = q
        let (library, source) = try Self.loadLibrary(device: device)
        librarySource = source
        func pipe(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw MetalGradeError(description: "missing kernel \(name)") }
            return try device.makeComputePipelineState(function: f)
        }
        blurPipe = try pipe("mpvfx_blur_pass"); momentsPipe = try pipe("mpvfx_kuwahara_moments")
        resolvePipe = try pipe("mpvfx_kuwahara_resolve"); gradePipe = try pipe("mpvfx_grade")
        func tex(_ d: MTLTextureDescriptor) throws -> MTLTexture {
            d.usage = .shaderRead; d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { throw MetalGradeError(description: "texture allocation failed") }
            return t
        }
        dummy2D = try tex(MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false))
        let d1 = MTLTextureDescriptor(); d1.textureType = .type1D; d1.pixelFormat = .rgba32Float; d1.width = 1
        dummy1D = try tex(d1)
        let d3 = MTLTextureDescriptor(); d3.textureType = .type3D; d3.pixelFormat = .rgba32Float; d3.width = 1; d3.height = 1; d3.depth = 1
        dummy3D = try tex(d3)
    }

    // MARK: Kernel parameters (MpvfxColorShared.h)

    func blurParams(dx: Float, dy: Float, radius: Float, bloom: Bool, threshold: Float, flipped: Bool) -> [Float] {
        var p = [Float](repeating: 0, count: Int(BLUR_PARAM_COUNT.rawValue))
        p[Int(BLUR_DIR_X.rawValue)] = dx; p[Int(BLUR_DIR_Y.rawValue)] = dy; p[Int(BLUR_RADIUS.rawValue)] = radius
        p[Int(BLUR_BLOOM_PASS.rawValue)] = bloom ? 1 : 0; p[Int(BLUR_THRESHOLD.rawValue)] = threshold
        p[Int(BLUR_SOURCE_FLIPPED.rawValue)] = flipped ? 1 : 0
        return p
    }
    func momentsParams(radius: Int, blurAmount: Float) -> [Float] {
        var p = [Float](repeating: 0, count: Int(MOMENTS_PARAM_COUNT.rawValue))
        p[Int(MOMENTS_RADIUS.rawValue)] = Float(radius); p[Int(MOMENTS_BLUR_AMOUNT.rawValue)] = blurAmount
        return p
    }
    func resolveParams(radius: Int, exponent: Float, saturation: Float) -> [Float] {
        var p = [Float](repeating: 0, count: Int(RESOLVE_PARAM_COUNT.rawValue))
        p[Int(RESOLVE_RADIUS.rawValue)] = Float(radius); p[Int(RESOLVE_EXPONENT.rawValue)] = exponent; p[Int(RESOLVE_SATURATION.rawValue)] = saturation
        return p
    }

    // MARK: Per-size targets

    final class Targets {
        let width: Int, height: Int, rowBytes: Int
        /// The `sourceKey` of the picture currently in `srcBuffer` (nil: unknown).
        var uploadedKey: String?
        let srcBuffer: MTLBuffer, outBuffer: MTLBuffer
        let src: MTLTexture, out: MTLTexture
        var blurA: MTLTexture?, blurB: MTLTexture?, bloomA: MTLTexture?, bloomB: MTLTexture?, moments: MTLTexture?, kuwahara: MTLTexture?
        init(width: Int, height: Int, rowBytes: Int, srcBuffer: MTLBuffer, outBuffer: MTLBuffer, src: MTLTexture, out: MTLTexture) {
            self.width = width; self.height = height; self.rowBytes = rowBytes
            self.srcBuffer = srcBuffer; self.outBuffer = outBuffer; self.src = src; self.out = out
        }
        /// Approximate GPU memory: the two shared buffers plus whichever pass textures were allocated.
        var bytes: Int {
            var n = srcBuffer.length + outBuffer.length
            let rgba8: [MTLTexture?] = [blurA, blurB, bloomA, bloomB, kuwahara]
            for case let t? in rgba8 { n += t.width * t.height * 4 }
            if let m = moments { n += m.width * m.height * 16 }
            return n
        }
    }

    func makeTargets(width: Int, height: Int) throws -> Targets {
        let align = max(1, device.minimumLinearTextureAlignment(for: .rgba8Unorm))
        let rowBytes = (width * 4 + align - 1) / align * align
        guard let sb = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let ob = device.makeBuffer(length: rowBytes * height, options: .storageModeShared) else {
            throw MetalGradeError(description: "buffer allocation failed (\(width)x\(height))")
        }
        func view(_ b: MTLBuffer, _ usage: MTLTextureUsage) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .shared; d.usage = usage
            guard let t = b.makeTexture(descriptor: d, offset: 0, bytesPerRow: rowBytes) else {
                throw MetalGradeError(description: "linear texture failed (\(width)x\(height))")
            }
            return t
        }
        return Targets(width: width, height: height, rowBytes: rowBytes, srcBuffer: sb, outBuffer: ob,
                       src: try view(sb, .shaderRead), out: try view(ob, .shaderWrite))
    }

    func privateTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
        guard let t = device.makeTexture(descriptor: d) else { throw MetalGradeError(description: "texture allocation failed (\(w)x\(h))") }
        return t
    }

    func acquire(width: Int, height: Int, sourceKey: String?) throws -> Targets {
        lock.lock()
        // Prefer the targets that already hold this source picture.
        if let k = sourceKey, let i = pool.firstIndex(where: { $0.width == width && $0.height == height && $0.uploadedKey == k }) {
            let t = pool.remove(at: i); lock.unlock(); return t
        }
        if let i = pool.firstIndex(where: { $0.width == width && $0.height == height }) { let t = pool.remove(at: i); lock.unlock(); return t }
        lock.unlock()
        return try makeTargets(width: width, height: height)
    }

    /// Idle per-size targets kept for reuse: at most 6, and at most `poolBudgetBytes` of buffers and textures
    /// (a 4K frame with every pass allocated is ~270 MB), always keeping the most recent one.
    public var poolBudgetBytes = 256 << 20

    func release(_ t: Targets) {
        lock.lock(); defer { lock.unlock() }
        pool.append(t)
        while pool.count > 6 || (pool.count > 1 && pool.reduce(0, { $0 + $1.bytes }) > poolBudgetBytes) { pool.removeFirst() }
    }

    /// Bytes held by idle targets (tests, diagnostics).
    public var pooledBytes: Int { lock.lock(); defer { lock.unlock() }; return pool.reduce(0) { $0 + $1.bytes } }

    /// Memory pressure: drops idle targets and cached tables (rebuilt on the next frame that needs them).
    public func purgeIdle() {
        lock.lock(); pool = []; tables = [:]; lock.unlock()
    }

    // MARK: Per-grade tables (LUT as a 3D texture, curves as 1D textures)

    struct Tables { var curves: MTLTexture, hue: MTLTexture, secondaries: MTLTexture, lut: MTLTexture }

    func texture1D(_ texels: [SIMD4<Float>]) throws -> MTLTexture {
        guard !texels.isEmpty else { return dummy1D }
        let d = MTLTextureDescriptor(); d.textureType = .type1D; d.pixelFormat = .rgba32Float; d.width = texels.count
        d.usage = .shaderRead; d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw MetalGradeError(description: "1D texture failed") }
        texels.withUnsafeBytes { b in
            t.replace(region: MTLRegionMake1D(0, texels.count), mipmapLevel: 0, withBytes: b.baseAddress!, bytesPerRow: texels.count * 16)
        }
        return t
    }

    func texture3D(_ texels: [SIMD4<Float>], size n: Int) throws -> MTLTexture {
        guard n >= 2, texels.count == n * n * n else { return dummy3D }
        let d = MTLTextureDescriptor(); d.textureType = .type3D; d.pixelFormat = .rgba32Float; d.width = n; d.height = n; d.depth = n
        d.usage = .shaderRead; d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw MetalGradeError(description: "3D LUT texture failed") }
        texels.withUnsafeBytes { b in
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: b.baseAddress!,
                      bytesPerRow: n * 16, bytesPerImage: n * n * 16)
        }
        return t
    }

    func tables(for f: MetalGradeJob) throws -> Tables {
        let key = f.tableKey
        lock.lock()
        tick += 1
        if let hit = tables[key] { tables[key] = (hit.tables, tick); lock.unlock(); return hit.tables }
        lock.unlock()
        let t = Tables(curves: try texture1D(f.curveRows), hue: try texture1D(f.hueRows), secondaries: try texture1D(f.secondaryTexels),
                       lut: try texture3D(f.lut, size: f.lutSize))
        lock.lock()
        if tables.count >= 8, let oldest = tables.min(by: { $0.value.tick < $1.value.tick })?.key { tables[oldest] = nil }
        tables[key] = (t, tick)
        lock.unlock()
        return t
    }

    // MARK: Encoding

    func dispatch(_ cb: MTLCommandBuffer, _ pipe: MTLComputePipelineState, textures: [MTLTexture], params: [Float], width: Int, height: Int) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { throw MetalGradeError(description: "no compute encoder") }
        enc.setComputePipelineState(pipe)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        params.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        let tw = max(1, pipe.threadExecutionWidth), th = max(1, pipe.maxTotalThreadsPerThreadgroup / tw)
        let group = MTLSize(width: tw, height: th, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1), threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    /// Grades `rgba` (width * height * 4 bytes, rows top first, straight alpha) in place. Throws when the GPU work
    /// could not be encoded or did not complete; the caller falls back to the CPU.
    ///
    /// Runs in its own autorelease pool: the command buffer and encoders are autoreleased, and export and off-main
    /// grading call this from loops that never return to a run loop, where every frame's command buffer (and the
    /// targets it retains) would otherwise stay alive until the loop ends.
    public func render(_ f: MetalGradeJob, _ rgba: inout [UInt8]) throws {
        try autoreleasepool { try encodeAndWait(f, &rgba) }
    }

    func encodeAndWait(_ f: MetalGradeJob, _ rgba: inout [UInt8]) throws {
        let width = f.width, height = f.height
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { throw MetalGradeError(description: "bad frame \(width)x\(height)") }
        let tab = try tables(for: f)
        let t = try acquire(width: width, height: height, sourceKey: f.sourceKey)
        defer { release(t) }
        // The source picture is already on the GPU: re-run only the kernels.
        let resident = f.sourceKey != nil && t.uploadedKey == f.sourceKey

        // Upload: straight into the buffer the source texture views.
        let rowBytes = width * 4
        if resident { lock.lock(); uploadsSkipped += 1; lock.unlock() } else {
            t.uploadedKey = nil
            rgba.withUnsafeBytes { src in
                let dst = t.srcBuffer.contents()
                if t.rowBytes == rowBytes { dst.copyMemory(from: src.baseAddress!, byteCount: rowBytes * height) }
                else { for y in 0..<height { (dst + y * t.rowBytes).copyMemory(from: src.baseAddress! + y * rowBytes, byteCount: rowBytes) } }
            }
            t.uploadedKey = f.sourceKey
        }

        guard let cb = queue.makeCommandBuffer() else { throw MetalGradeError(description: "no command buffer") }
        var blur: MTLTexture = dummy2D
        if f.blurIterations > 0 {
            if t.blurA == nil { t.blurA = try privateTexture(.rgba8Unorm, width, height); t.blurB = try privateTexture(.rgba8Unorm, width, height) }
            var current = t.src
            var flip = true
            for _ in 0..<f.blurIterations {
                try dispatch(cb, blurPipe, textures: [current, t.blurA!], params: blurParams(dx: 1, dy: 0, radius: f.blurRadius, bloom: false, threshold: -1, flipped: flip), width: width, height: height)
                try dispatch(cb, blurPipe, textures: [t.blurA!, t.blurB!], params: blurParams(dx: 0, dy: 1, radius: f.blurRadius, bloom: false, threshold: -1, flipped: false), width: width, height: height)
                current = t.blurB!; flip = false
            }
            blur = t.blurB!
        }
        var bloom: MTLTexture = dummy2D
        if f.bloomWidth > 0 && f.bloomHeight > 0 {
            if t.bloomA == nil { t.bloomA = try privateTexture(.rgba8Unorm, f.bloomWidth, f.bloomHeight); t.bloomB = try privateTexture(.rgba8Unorm, f.bloomWidth, f.bloomHeight) }
            try dispatch(cb, blurPipe, textures: [t.src, t.bloomA!], params: blurParams(dx: 1, dy: 0, radius: f.bloomRadius, bloom: true, threshold: 0.5, flipped: true), width: f.bloomWidth, height: f.bloomHeight)
            try dispatch(cb, blurPipe, textures: [t.bloomA!, t.bloomB!], params: blurParams(dx: 0, dy: 1, radius: f.bloomRadius, bloom: true, threshold: -1, flipped: false), width: f.bloomWidth, height: f.bloomHeight)
            bloom = t.bloomB!
        }
        var kuwahara: MTLTexture = dummy2D
        if f.kuwaharaRadius > 0 {
            if t.moments == nil { t.moments = try privateTexture(.rgba32Float, width, height); t.kuwahara = try privateTexture(.rgba8Unorm, width, height) }
            try dispatch(cb, momentsPipe, textures: [t.src, blur, t.moments!], params: momentsParams(radius: f.kuwaharaRadius, blurAmount: f.blurIterations > 0 ? f.blurAmount : 0),
                         width: width, height: height)
            try dispatch(cb, resolvePipe, textures: [t.moments!, t.kuwahara!], params: resolveParams(radius: f.kuwaharaRadius, exponent: f.kuwaharaExponent, saturation: f.kuwaharaSaturation),
                         width: width, height: height)
            kuwahara = t.kuwahara!
        }
        var slots = [MTLTexture](repeating: dummy2D, count: Int(GRADE_TEX_COUNT.rawValue))
        func put(_ k: MpvfxGradeTexture, _ tex: MTLTexture) { slots[Int(k.rawValue)] = tex }
        put(GRADE_TEX_SOURCE, t.src); put(GRADE_TEX_BLUR, blur); put(GRADE_TEX_KUWAHARA, kuwahara); put(GRADE_TEX_BLOOM, bloom)
        put(GRADE_TEX_CURVES, tab.curves); put(GRADE_TEX_HUE, tab.hue); put(GRADE_TEX_SECONDARIES, tab.secondaries); put(GRADE_TEX_LUT, tab.lut)
        put(GRADE_TEX_OUTPUT, t.out)
        try dispatch(cb, gradePipe, textures: slots, params: f.uniforms, width: width, height: height)
        cb.commit()
        cb.waitUntilCompleted()
        if cb.status != .completed { throw MetalGradeError(description: "command buffer \(cb.status.rawValue): \(cb.error.map { "\($0)" } ?? "no error")") }

        rgba.withUnsafeMutableBytes { dst in
            let src = t.outBuffer.contents()
            if t.rowBytes == rowBytes { dst.baseAddress!.copyMemory(from: src, byteCount: rowBytes * height) }
            else { for y in 0..<height { (dst.baseAddress! + y * rowBytes).copyMemory(from: src + y * t.rowBytes, byteCount: rowBytes) } }
        }
    }
}
#endif
