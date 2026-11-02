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
import MpvfxAudioGraph
import MpvfxPanels
@testable import MpvfxDesktop

/// The Loudness readout's feed: a background measurement per source, saved in the project's cache folder.
final class ClipLoudnessFeedTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("loudness-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.wav(440, seconds: 2, to: dir.appendingPathComponent("tone.wav").path, amplitude: 0.1)
        try Self.wav(440, seconds: 2, to: dir.appendingPathComponent("silent.wav").path, amplitude: 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A feed on `folder`; its redraw runs `redraw`, and background results come back on the main queue.
    func feed(_ folder: URL, redraw: @escaping () -> Void = {}) -> ClipLoudnessFeed {
        ClipLoudnessFeed(projectDir: { folder.path }, postToUI: { work in DispatchQueue.main.async { work() } }, redraw: redraw)
    }

    /// The integrated loudness of the tone as the decoder hands it over: 16-bit mono, duplicated to both channels.
    func expectedToneLoudness() throws -> Double {
        let quantized = (0..<96_000).map { i -> Float in
            let s = (0.1 * sin(2 * Double.pi * 440 * Double(i) / 48_000) * 32768).rounded()
            return Float(max(-32768, min(32767, s)) / 32768)
        }
        return try LoudnessMeter.integrated([quantized, quantized], sampleRate: 48_000)
    }

    func testMeasuresInTheBackgroundThenReadsTheValue() throws {
        let expected = try expectedToneLoudness()
        let measured = expectation(description: "redraw after the measurement")
        let f = feed(dir, redraw: { measured.fulfill() })
        XCTAssertEqual(f.reading(for: "tone.wav"), .measuring, "the first read starts the measurement")
        XCTAssertEqual(f.reading(for: "tone.wav"), .measuring, "a second read does not start another")
        wait(for: [measured], timeout: 20)
        guard case .lufs(let lufs) = f.reading(for: "tone.wav") else {
            return XCTFail("the tone should be measured, got \(f.reading(for: "tone.wav"))")
        }
        XCTAssertEqual(lufs, expected, accuracy: 0.05)
    }

    func testTheReadingIsSavedInTheProjectCacheFolder() throws {
        let measured = expectation(description: "redraw after the measurement")
        let f = feed(dir, redraw: { measured.fulfill() })
        _ = f.reading(for: "tone.wav")
        wait(for: [measured], timeout: 20)
        let cache = dir.appendingPathComponent(".loudness-cache/v1.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        XCTAssertEqual(root["v"] as? Int, 1)
        let entries = try XCTUnwrap(root["entries"] as? [String: Any])
        XCTAssertEqual(entries.keys.filter { $0.hasPrefix("tone.wav|") }.count, 1, "one entry keyed by source, size and mtime")
    }

    func testASecondFeedReadsTheSavedValueWithoutMeasuring() throws {
        let measured = expectation(description: "redraw after the measurement")
        let first = feed(dir, redraw: { measured.fulfill() })
        _ = first.reading(for: "tone.wav")
        wait(for: [measured], timeout: 20)
        guard case .lufs(let saved) = first.reading(for: "tone.wav") else { return XCTFail("the first feed should measure the tone") }

        let second = feed(dir)
        XCTAssertEqual(second.reading(for: "tone.wav"), .lufs(saved), "read at once from the cache file, not measured again")
    }

    func testASilentFileReadsSilent() throws {
        let measured = expectation(description: "redraw after the measurement")
        let f = feed(dir, redraw: { measured.fulfill() })
        _ = f.reading(for: "silent.wav")
        wait(for: [measured], timeout: 20)
        XCTAssertEqual(f.reading(for: "silent.wav"), .silent)
        XCTAssertEqual(feed(dir).reading(for: "silent.wav"), .silent, "silence is saved too")
    }

    func testAMissingFileReadsNotAvailable() {
        XCTAssertEqual(feed(dir).reading(for: "nothere.wav"), .unavailable)
    }

    static func wav(_ frequency: Double, seconds: Double, to path: String, amplitude: Float) throws {
        let samples = (0..<Int(seconds * 48_000)).map { i in amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / 48_000)) }
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + samples.count * 2); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(samples.count * 2)
        for s in samples { var x = Int16(max(-32768, min(32767, (s * 32768).rounded()))).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        try d.write(to: URL(fileURLWithPath: path))
    }
}
