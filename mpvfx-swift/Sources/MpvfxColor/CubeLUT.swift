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

public struct CubeLUTParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let line: Int?
    public init(_ message: String, line: Int? = nil) { self.message = message; self.line = line }
    public var description: String { line.map { "\(message) at line \($0)" } ?? message }
}

/// A 3D `.cube` LUT (`parseCubeLut`): TITLE, DOMAIN_MIN/MAX,
/// LUT_3D_INPUT_RANGE, LUT_3D_SIZE up to 64; 1D LUTs are rejected. Data rows run red fastest, then green, then blue.
public struct CubeLUT: Equatable, Sendable {
    public enum Interpolation: Sendable { case trilinear, tetrahedral }
    public static let maxSize = 64

    public var title: String?
    public var size: Int
    public var domainMin: SIMD3<Float>, domainMax: SIMD3<Float>
    /// size³ RGB entries, index = (b * size + g) * size + r.
    public var table: [SIMD3<Float>]

    public init(size: Int, table: [SIMD3<Float>], domainMin: SIMD3<Float> = .zero, domainMax: SIMD3<Float> = .one, title: String? = nil) {
        self.size = size; self.table = table; self.domainMin = domainMin; self.domainMax = domainMax; self.title = title
    }

    /// Identity LUT of `size` (tests, neutral bake).
    public static func identity(size: Int) -> CubeLUT {
        var t: [SIMD3<Float>] = []; t.reserveCapacity(size * size * size)
        let k = Float(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size { t.append(SIMD3(Float(r) / k, Float(g) / k, Float(b) / k)) } } }
        return CubeLUT(size: size, table: t)
    }

    public init(parsing text: String, maxSize: Int = CubeLUT.maxSize) throws {
        var title: String?
        var dmin = SIMD3<Float>(0, 0, 0), dmax = SIMD3<Float>(1, 1, 1)
        var size1d: Int?, size3d: Int?
        var rows: [Float] = []
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        func num(_ s: Substring, _ line: Int) throws -> Float {
            guard let d = Double(s), d.isFinite else { throw CubeLUTParseError("Invalid number \"\(s)\"", line: line) }
            return Float(d)
        }
        func vec(_ p: [Substring], _ kw: String, _ line: Int) throws -> SIMD3<Float> {
            guard p.count == 3 else { throw CubeLUTParseError("\(kw) expects three numbers", line: line) }
            return SIMD3(try num(p[0], line), try num(p[1], line), try num(p[2], line))
        }
        func sizeValue(_ p: [Substring], _ kw: String, _ line: Int) throws -> Int {
            guard let s = p.first else { throw CubeLUTParseError("\(kw) expects a size", line: line) }
            guard let d = Double(s), d == d.rounded(), d >= 2, d < 1e6 else { throw CubeLUTParseError("\(kw) must be an integer greater than 1", line: line) }
            return Int(d)
        }
        for (i, raw) in lines.enumerated() {
            let line = i + 1
            var l = raw.hasSuffix("\r") ? raw.dropLast() : raw[...]
            // Comments start at an unquoted '#'.
            var inQuote = false
            if let hash = l.indices.first(where: { idx in
                if l[idx] == "\"" { inQuote.toggle() }
                return l[idx] == "#" && !inQuote
            }) { l = l[..<hash] }
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let kw = parts[0].uppercased(), rest = Array(parts.dropFirst())
            switch kw {
            case "TITLE":
                if let q = trimmed.range(of: "^TITLE\\s+\"([^\"]*)\"\\s*$", options: [.regularExpression, .caseInsensitive]) {
                    let s = trimmed[q]; let a = s.firstIndex(of: "\"")!, b = s.lastIndex(of: "\"")!
                    title = String(s[s.index(after: a)..<b])
                } else {
                    let t = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces); title = t.isEmpty ? nil : t
                }
            case "DOMAIN_MIN": dmin = try vec(rest, kw, line)
            case "DOMAIN_MAX": dmax = try vec(rest, kw, line)
            case "LUT_3D_INPUT_RANGE":
                guard rest.count == 2 else { throw CubeLUTParseError("\(kw) expects two numbers", line: line) }
                let a = try num(rest[0], line), b = try num(rest[1], line)
                guard b > a else { throw CubeLUTParseError("LUT_3D_INPUT_RANGE max must exceed min", line: line) }
                dmin = SIMD3(repeating: a); dmax = SIMD3(repeating: b)
            case "LUT_1D_SIZE": size1d = try sizeValue(rest, kw, line)
            case "LUT_3D_SIZE":
                let s = try sizeValue(rest, kw, line)
                guard s <= maxSize else { throw CubeLUTParseError("LUT_3D_SIZE \(s) exceeds max \(maxSize)", line: line) }
                size3d = s
            default:
                guard let c = kw.first, c.isNumber || ((c == "+" || c == "-" || c == ".") && kw.dropFirst().first.map { $0.isNumber || $0 == "." } == true) else {
                    if kw.hasPrefix("LUT_") { throw CubeLUTParseError("Unsupported cube keyword \(kw)", line: line) }
                    continue
                }
                guard size3d != nil else {
                    throw CubeLUTParseError(size1d != nil ? "1D cube LUTs are not supported yet" : "LUT data appears before LUT_3D_SIZE", line: line)
                }
                guard parts.count == 3 else { throw CubeLUTParseError("LUT data rows must contain three numbers", line: line) }
                rows.append(try num(parts[0], line)); rows.append(try num(parts[1], line)); rows.append(try num(parts[2], line))
            }
        }
        if size1d != nil && size3d != nil { throw CubeLUTParseError("Mixed 1D and 3D cube LUTs are not supported yet") }
        guard let n = size3d else { throw CubeLUTParseError(size1d != nil ? "1D cube LUTs are not supported yet" : "Missing LUT_3D_SIZE") }
        guard dmax.x > dmin.x, dmax.y > dmin.y, dmax.z > dmin.z else { throw CubeLUTParseError("DOMAIN_MAX values must be greater than DOMAIN_MIN values") }
        guard rows.count == n * n * n * 3 else { throw CubeLUTParseError("Expected \(n * n * n) LUT rows for size \(n), found \(rows.count / 3)") }
        self.init(size: n, table: stride(from: 0, to: rows.count, by: 3).map { SIMD3(rows[$0], rows[$0 + 1], rows[$0 + 2]) },
                  domainMin: dmin, domainMax: dmax, title: title)
    }

    public init(contentsOf path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try self.init(parsing: String(decoding: data, as: UTF8.self))
    }

    /// The table as the shader samples it: every entry clamped to 0…1 and rounded to 8 bits (`packCubeLutToRgba8`).
    public var quantized8: CubeLUT {
        var q = self
        q.table = table.map { v in (simdClamp(v, .zero, .one) * 255).rounded(.toNearestOrAwayFromZero) / 255 }
        return q
    }

    /// `.cube` text (LUT_3D_SIZE, then rows red fastest), for saving a baked grade.
    public var cubeText: String {
        var s = "LUT_3D_SIZE \(size)\n"
        if domainMin != .zero { s += "DOMAIN_MIN \(domainMin.x) \(domainMin.y) \(domainMin.z)\n" }
        if domainMax != .one { s += "DOMAIN_MAX \(domainMax.x) \(domainMax.y) \(domainMax.z)\n" }
        for v in table { s += String(format: "%.6f %.6f %.6f\n", v.x, v.y, v.z) }
        return s
    }

    @inline(__always) func entry(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { table[(b * size + g) * size + r] }

    /// Samples the LUT at `color` (inputs outside the domain clamp to its edge), as the shader's `applyLut` does
    /// for trilinear; tetrahedral splits each cell into six tetrahedra (smoother on diagonals, fewer fetches).
    public func sample(_ color: SIMD3<Float>, interpolation: Interpolation = .trilinear) -> SIMD3<Float> {
        let n = Float(Swift.max(size, 2))
        let span = simdMax(domainMax - domainMin, SIMD3(repeating: 0.00001))
        let scaled = simdClamp((color - domainMin) / span, .zero, .one) * (n - 1)
        let lo = scaled.rounded(.down)
        let hi = simdMin(lo + 1, SIMD3(repeating: n - 1))
        let f = scaled - lo
        let r0 = Int(lo.x), g0 = Int(lo.y), b0 = Int(lo.z), r1 = Int(hi.x), g1 = Int(hi.y), b1 = Int(hi.z)
        switch interpolation {
        case .trilinear:
            let c00 = mix(entry(r0, g0, b0), entry(r1, g0, b0), f.x), c10 = mix(entry(r0, g1, b0), entry(r1, g1, b0), f.x)
            let c01 = mix(entry(r0, g0, b1), entry(r1, g0, b1), f.x), c11 = mix(entry(r0, g1, b1), entry(r1, g1, b1), f.x)
            return mix(mix(c00, c10, f.y), mix(c01, c11, f.y), f.z)
        case .tetrahedral:
            let c000 = entry(r0, g0, b0), c111 = entry(r1, g1, b1)
            let (x, y, z) = (f.x, f.y, f.z)
            if x > y {
                if y > z {        // x > y > z
                    let c100 = entry(r1, g0, b0), c110 = entry(r1, g1, b0)
                    return c000 + x * (c100 - c000) + y * (c110 - c100) + z * (c111 - c110)
                } else if x > z { // x > z >= y
                    let c100 = entry(r1, g0, b0), c101 = entry(r1, g0, b1)
                    return c000 + x * (c100 - c000) + z * (c101 - c100) + y * (c111 - c101)
                } else {          // z >= x > y
                    let c001 = entry(r0, g0, b1), c101 = entry(r1, g0, b1)
                    return c000 + z * (c001 - c000) + x * (c101 - c001) + y * (c111 - c101)
                }
            } else {
                if z > y {        // z > y >= x
                    let c001 = entry(r0, g0, b1), c011 = entry(r0, g1, b1)
                    return c000 + z * (c001 - c000) + y * (c011 - c001) + x * (c111 - c011)
                } else if z > x { // y >= z > x
                    let c010 = entry(r0, g1, b0), c011 = entry(r0, g1, b1)
                    return c000 + y * (c010 - c000) + z * (c011 - c010) + x * (c111 - c011)
                } else {          // y >= x >= z
                    let c010 = entry(r0, g1, b0), c110 = entry(r1, g1, b0)
                    return c000 + y * (c010 - c000) + x * (c110 - c010) + z * (c111 - c110)
                }
            }
        }
    }

    /// `sample` blended with the input by `strength` (0…1), the LUT strength slider.
    public func apply(_ color: SIMD3<Float>, strength: Float, interpolation: Interpolation = .trilinear) -> SIMD3<Float> {
        mix(color, sample(color, interpolation: interpolation), Swift.min(1, Swift.max(0, strength)))
    }
}

/// Loaded LUTs by absolute path (file modification time checked), shared by preview and export.
public final class CubeLUTCache: @unchecked Sendable {
    public static let shared = CubeLUTCache()
    let lock = NSLock()
    var entries: [String: (mtime: Date?, lut: Result<CubeLUT, CubeLUTParseError>)] = [:]
    public init() {}

    /// The LUT at `path`, 8-bit quantized as the shader samples it; nil when unreadable or invalid.
    public func lut(at path: String) -> CubeLUT? { try? load(path).get() }

    public func load(_ path: String) -> Result<CubeLUT, CubeLUTParseError> {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        lock.lock()
        if let e = entries[path], e.mtime == mtime { lock.unlock(); return e.lut }
        lock.unlock()
        let r: Result<CubeLUT, CubeLUTParseError>
        do { r = .success(try CubeLUT(contentsOf: path).quantized8) }
        catch let e as CubeLUTParseError { r = .failure(e) }
        catch { r = .failure(CubeLUTParseError("LUT failed to load")) }
        lock.lock(); if entries.count >= 16 { entries.removeAll() }; entries[path] = (mtime, r); lock.unlock()
        return r
    }

    /// Resolves a grade's `lut.src` (project-relative path or absolute path) against the project folder.
    public static func resolve(_ src: String, projectDir: String?) -> String? {
        let s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.lowercased().hasPrefix("http:"), !s.lowercased().hasPrefix("https:"), !s.lowercased().hasPrefix("data:") else { return nil }
        var path = s.lowercased().hasPrefix("file://") ? (URL(string: s)?.path ?? s) : s
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("./") { path.removeFirst(2) }
        guard let projectDir else { return nil }
        return URL(fileURLWithPath: projectDir).appendingPathComponent(path).standardizedFileURL.path
    }
}

@inline(__always) func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
@inline(__always) func simdClamp(_ v: SIMD3<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> SIMD3<Float> { simdMin(simdMax(v, lo), hi) }
@inline(__always) func simdMin(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z)) }
@inline(__always) func simdMax(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z)) }
