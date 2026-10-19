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
import XCTest
@testable import MpvfxAudioGraph

enum Fixtures {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let reference: JSONValue = {
        let text = try! String(contentsOf: dir.appendingPathComponent("reference.json"), encoding: .utf8)
        return try! parseJSON(text)
    }()
    static func f32(_ name: String) -> [Float] {
        let data = try! Data(contentsOf: dir.appendingPathComponent(name))
        return data.withUnsafeBytes { raw in
            (0..<(data.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
    static func planes(_ interleaved: [Float], channels: Int = 2) -> [[Float]] {
        let n = interleaved.count / channels
        return (0..<channels).map { c in (0..<n).map { interleaved[$0 * channels + c] } }
    }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        if case let .object(entries) = self { return entries.first(where: { $0.0 == key })?.1 }
        return nil
    }
    subscript(_ i: Int) -> JSONValue { arrayValue![i] }
    var array: [JSONValue] { arrayValue ?? [] }
    var num: Double {
        switch self {
        case let .number(n): return n
        case let .string(s): return s == "NaN" ? .nan : jsStringToNumber(s)
        default: return .nan
        }
    }
    var str: String { stringValue ?? "" }
    /// Re-serialise for comparisons against JSON.stringify output.
    var json: String { stringifyJSON(self) }
}

/// Peak absolute difference in dBFS (−inf when identical).
func peakDiffDb(_ a: [Float], _ b: [Float]) -> (db: Double, peak: Double, index: Int) {
    var peak = 0.0, at = -1
    for i in 0..<max(a.count, b.count) {
        let d = abs(Double(i < a.count ? a[i] : 0) - Double(i < b.count ? b[i] : 0))
        if d > peak { peak = d; at = i }
    }
    return (peak == 0 ? -Double.infinity : 20 * log10(peak), peak, at)
}

func fmtDb(_ db: Double) -> String { db == -.infinity ? "-inf (bit-exact)" : String(format: "%.1f dBFS", db) }

/// Report line collected for the parity summary.
func parityLog(_ line: String) { print("PARITY \(line)") }

func automationFromJSON(_ v: JSONValue) -> Automation {
    try! AudioAutomation.parse(v.json)
}

func pointsJSON(_ points: [AutomationPoint]) -> String {
    let items = points.map { p -> String in
        var e: [(String, JSONValue)] = [("t", .number(p.t)), ("v", .number(p.v))]
        if let c = p.curve { e.append(("curve", .number(c))) }
        if let x = p.viaX { e.append(("viaX", .number(x))) }
        if let y = p.viaY { e.append(("viaY", .number(y))) }
        return stringifyJSON(.object(e))
    }
    return "[" + items.joined(separator: ",") + "]"
}

func sine(_ freq: Double, seconds: Double, amp: Double = 0.125, sr: Double = 48000) -> [[Float]] {
    let n = Int((seconds * sr).rounded())
    let p = (0..<n).map { (i: Int) -> Float in Float(amp * sin(2 * Double.pi * freq * Double(i) / sr)) }
    return [p, p]
}

/// RMS of the mono downmix over [t, t+0.1) of an interleaved stereo render.
func rms(_ interleaved: [Float], at t: Double, sr: Double = 48000) -> Double {
    let a = Int(t * sr), b = min(interleaved.count / 2, Int((t + 0.1) * sr))
    guard b > a else { return 0 }
    var s = 0.0
    for i in a..<b { let m = (Double(interleaved[2 * i]) + Double(interleaved[2 * i + 1])) / 2; s += m * m }
    return (s / Double(b - a)).squareRoot()
}

/// V8's Math.pow/exp/log (fdlibm-derived) and glibc's libm can differ in the last
/// place; values derived from them are compared within 4 ulp (relative 1e-15).
func ulpClose(_ a: Double, _ b: Double) -> Bool {
    if a == b { return true }
    if a.isNaN && b.isNaN { return true }
    return abs(a - b) <= 4 * max(a.ulp, b.ulp)
}
