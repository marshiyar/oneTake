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
// Golden-value tests for media URLs, silence detection, the extension pattern and their
// edge cases. Every expected value comes from the recorded reference values in Fixtures/mediaParity.json (generator
// and instructions in Fixtures/gen; the engine and ICU versions are recorded in
// the fixture; the generator is not part of this repo). Read via #filePath because Package.swift declares no test resources.
import XCTest
@testable import MpvfxShared

/// A JS number as the generator writes it: JSON number, or "NaN" / "Infinity" / "-Infinity" / "-0".
struct JSNum: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; return }
        switch try c.decode(String.self) {
        case "NaN": value = .nan
        case "Infinity": value = .infinity
        case "-Infinity": value = -.infinity
        case "-0": value = -0.0
        case let s: throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad number \(s)")
        }
    }
}

struct MediaParityFixture: Decodable {
    struct Pow: Decodable { let db: JSNum; let amplitude: JSNum }
    struct Opts: Decodable { let thresholdDb: JSNum?; let minimumSilenceSeconds: JSNum?; let paddingSeconds: JSNum? }
    struct Range: Decodable { let start: JSNum; let end: JSNum }
    struct Silence: Decodable { let sampleRate: JSNum; let options: Opts; let channels: [[JSNum]]; let result: [Range] }
    struct Lower: Decodable { let input: [UInt16]; let toLowerCase: [UInt16]; let classify: String?; let preferredMime: String? }
    struct Encode: Decodable { let input: [UInt16]; let result: String }
    struct Lone: Decodable { let input: [UInt16]; let threw: String?; let result: String? }
    struct Url: Decodable { let id: String; let path: String; let result: String }
    struct Pattern: Decodable { let kinds: [String]; let text: String; let matches: Bool; let source: String }
    struct Mime: Decodable { let path: String; let result: String? }
    struct Trim: Decodable { let input: [UInt16]; let acceptedAsEmptyMime: Bool; let trimmed: [UInt16] }
    let node: String; let v8: String; let icu: String
    let pow: [Pow]; let silence: [Silence]; let lower: [Lower]; let encode: [Encode]; let loneSurrogates: [Lone]
    let urls: [Url]; let pattern: [Pattern]; let mime: [Mime]; let trim: [Trim]

    static let shared: MediaParityFixture = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mediaParity.json")
        return try! JSONDecoder().decode(MediaParityFixture.self, from: Data(contentsOf: url))
    }()
}

private func s16(_ u: [UInt16]) -> String { String(decoding: u, as: UTF16.self) }
private func bits(_ d: Double) -> UInt64 { d.bitPattern }

final class MediaSwiftOnlyParityTests: XCTestCase {
    let f = MediaParityFixture.shared

    func testFixtureProvenance() {
        XCTAssertEqual(f.node, "v20.19.2")
        XCTAssertEqual(f.pow.count, 3518); XCTAssertEqual(f.silence.count, 400)
    }

    // The threshold is `10 ** (thresholdDb / 20)`. Swift uses Foundation pow (user decision: fully native, no
    // copied engine code), so results can drift from the recorded values by an ULP and silence edges can move. The drift is
    // measured against the recorded fixture and must equal the recorded list in Fixtures/mediaDrift.json exactly, so any
    // new or changed drift fails loudly. No tolerance is applied yet (pending the Reviewer's value).
    // To re-record after an intentional change: MPVFX_RECORD_MEDIA_DRIFT=1 swift test --skip-build --filter
    // MediaSwiftOnlyParityTests/testRecordedDrift, then copy swift/.build/port-tmp/mediaDrift.json into Fixtures/.
    struct Drift: Codable, Equatable {
        struct PowMismatch: Codable, Equatable { let index: Int; let db: Double; let swift: Double; let node: Double; let ulps: Int64 }
        struct SilenceMismatch: Codable, Equatable {
            let index: Int; let swiftRanges: Int; let nodeRanges: Int; let maxEdgeShiftSamples: Double
        }
        let powCases: Int, powMismatches: [PowMismatch], maxPowUlps: Int64
        let silenceCases: Int, silenceMismatches: [SilenceMismatch], maxEdgeShiftSamples: Double
    }
    private func ulpDistance(_ a: Double, _ b: Double) -> Int64 {
        func key(_ d: Double) -> Int64 { let b = Int64(bitPattern: d.bitPattern); return b < 0 ? Int64.min - b : b }
        return abs(key(a) &- key(b))
    }
    private func measureDrift() -> Drift {
        var pm: [Drift.PowMismatch] = []
        for (i, p) in f.pow.enumerated() {
            let sw = jsExponentiate(10, p.db.value / 20), node = p.amplitude.value
            if bits(sw) != bits(node) && !(sw.isNaN && node.isNaN) {
                pm.append(.init(index: i, db: p.db.value, swift: sw, node: node, ulps: ulpDistance(sw, node)))
            }
        }
        var sm: [Drift.SilenceMismatch] = []
        for (i, c) in f.silence.enumerated() {
            let channels = c.channels.map { $0.map { Float($0.value) } }
            let options = PartialSilenceRemovalOptions(thresholdDb: c.options.thresholdDb?.value,
                                                       minimumSilenceSeconds: c.options.minimumSilenceSeconds?.value,
                                                       paddingSeconds: c.options.paddingSeconds?.value)
            let got = detectSilences(channels, sampleRate: c.sampleRate.value, options: options)
            let want = c.result.map { SilenceRange(start: $0.start.value, end: $0.end.value) }
            let same = got.count == want.count && zip(got, want).allSatisfy { bits($0.start) == bits($1.start) && bits($0.end) == bits($1.end) }
            if same { continue }
            // Edge shift in samples between paired ranges; unmatched ranges count as their full length.
            var shift = 0.0
            for k in 0..<max(got.count, want.count) {
                if k < got.count && k < want.count {
                    shift = max(shift, abs(got[k].start - want[k].start) * c.sampleRate.value, abs(got[k].end - want[k].end) * c.sampleRate.value)
                } else {
                    let r = k < got.count ? got[k] : want[k]
                    shift = max(shift, (r.end - r.start) * c.sampleRate.value)
                }
            }
            sm.append(.init(index: i, swiftRanges: got.count, nodeRanges: want.count, maxEdgeShiftSamples: shift))
        }
        return .init(powCases: f.pow.count, powMismatches: pm, maxPowUlps: pm.map(\.ulps).max() ?? 0,
                     silenceCases: f.silence.count, silenceMismatches: sm,
                     maxEdgeShiftSamples: sm.map(\.maxEdgeShiftSamples).max() ?? 0)
    }

    func testRecordedDrift() throws {
        let measured = measureDrift()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        if ProcessInfo.processInfo.environment["MPVFX_RECORD_MEDIA_DRIFT"] == "1" {
            let out = here.appendingPathComponent("../../../.build/port-tmp/mediaDrift.json").standardized
            try enc.encode(measured).write(to: out)
            print("recorded drift to \(out.path): pow \(measured.powMismatches.count)/\(measured.powCases), max \(measured.maxPowUlps) ulp; silence \(measured.silenceMismatches.count)/\(measured.silenceCases), max edge shift \(measured.maxEdgeShiftSamples) samples")
            return
        }
        let recorded = try JSONDecoder().decode(Drift.self, from: Data(contentsOf: here.appendingPathComponent("Fixtures/mediaDrift.json")))
        #if os(Linux)
        // The fixture was recorded against glibc's pow; pin the exact mismatch list there.
        XCTAssertEqual(measured.powMismatches.count, recorded.powMismatches.count, "pow drift count changed")
        XCTAssertEqual(measured.powMismatches, recorded.powMismatches, "pow drift list changed")
        XCTAssertEqual(measured.maxPowUlps, recorded.maxPowUlps)
        #else
        // Other libms (Apple's) round a different handful of cases; hold them to the same ulp bound.
        XCTAssertLessThanOrEqual(measured.maxPowUlps, recorded.maxPowUlps, "pow drift exceeds the recorded ulp bound")
        #endif
        XCTAssertEqual(measured.silenceMismatches, recorded.silenceMismatches, "silence drift list changed")
        XCTAssertEqual(measured.maxEdgeShiftSamples, recorded.maxEdgeShiftSamples)
        XCTAssertGreaterThan(f.silence.filter { !$0.result.isEmpty }.count, 30)   // the fixture really exercises detection
    }

    /// JS toLowerCase vs Swift lowercased() on U+0130, final/medial capital sigma etc., and the policy result.
    /// Pins current Swift behavior; docs/IMPLEMENTATION_NOTES.md lists any case where it differs from JS.
    func testLowercaseEdgeCasesAgainstJs() {
        var differ: [String] = [], rawDiffer: [String] = []
        for c in f.lower {
            let input = s16(c.input)
            if Array(jsToLowerCase(input).utf16) != c.toLowerCase { differ.append(input) }
            if Array(input.lowercased().utf16) != c.toLowerCase { rawDiffer.append(input) }
            XCTAssertEqual(classifyMediaImportPath(input)?.rawValue, c.classify, input)
            XCTAssertEqual(preferredMediaImportMimeType(input), c.preferredMime, input)
        }
        XCTAssertEqual(differ, [], "jsToLowerCase differs from JS toLowerCase for: \(differ)")
        // Pinned: plain Swift lowercased() is wrong only on the Final_Sigma inputs — why jsToLowerCase exists.
        XCTAssertEqual(rawDiffer, ["ΣΑΣ", "x.ΑΣ", "x.Σ"])
    }

    func testEncodeMediaPathMatchesTs() throws {
        for c in f.encode { XCTAssertEqual(try encodeMediaPath(utf16: c.input), c.result, s16(c.input)) }
        for c in f.encode where String(decoding: c.input, as: UTF16.self).utf16.elementsEqual(c.input) {
            XCTAssertEqual(encodeMediaPath(s16(c.input)), c.result)
        }
    }

    /// encodeURIComponent throws URIError on a lone surrogate; the UTF-16 overloads throw at the same point.
    func testLoneSurrogateThrowsLikeTs() {
        for c in f.loneSurrogates {
            XCTAssertEqual(c.threw, "URIError: URI malformed")
            XCTAssertThrowsError(try encodeMediaPath(utf16: c.input)) { XCTAssertEqual("\($0)", c.threw) }
        }
    }

    /// Object-prototype hits (".constructor", ".__proto__") are a documented gap: the recorded result is a function/object.
    func testPreferredMimeTypeMatchesTs() {
        for c in f.mime {
            if c.result?.hasPrefix("<") == true { XCTAssertNil(preferredMediaImportMimeType(c.path), "documented gap: \(c.path)"); continue }
            XCTAssertEqual(preferredMediaImportMimeType(c.path), c.result, c.path)
        }
    }

    func testTrimMatchesTs() {
        for c in f.trim {
            XCTAssertEqual(Array(jsTrim(s16(c.input)).utf16), c.trimmed)
            let accepted: Bool = { if case .accepted = inspectMediaImportFile(MediaImportFile(name: "a.png", type: s16(c.input), size: 1)) { return true }; return false }()
            XCTAssertEqual(accepted, c.acceptedAsEmptyMime, "\(c.input)")
        }
        XCTAssertTrue(jsMathMax(0, .nan).isNaN)
    }
}
