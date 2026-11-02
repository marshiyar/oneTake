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
import XCTest
import MpvfxAudioGraph
@testable import MpvfxAudio
#if canImport(Darwin)
import Darwin
#endif

/// The Audio FX rack's meters: how far a dynamics module is reducing, and the levels in and out of every module, read
/// for the sound being heard and published by the feeder without allocating.
final class AudioMeterTests: XCTestCase {
    static let sr = 48000.0, block = 128

    static func sine(frames: Int, amplitude: (Int) -> Double, hz: Double = 1000) -> [[Float]] {
        let plane = (0..<frames).map { Float(amplitude($0) * sin(2 * Double.pi * hz * Double($0) / sr)) }
        return [plane, plane]
    }

    static func source(_ chain: String, amplitude: @escaping (Int) -> Double, hz: Double = 1000,
                       seconds: Double = 2) throws -> GraphAudioSource {
        let stem = sine(frames: Int(seconds * sr), amplitude: amplitude, hz: hz)
        let track = AudioGraphTrack(id: "a", stem: stem, start: 0, end: seconds, fxChain: try AudioFx.parseChain(chain))
        let source = GraphAudioSource(project: AudioGraphProject(duration: seconds, sampleRate: sr, tracks: [track]))
        source.collectsFxMeters = true
        return source
    }

    /// A steady -6 dBFS sine through a compressor at -24 dB and 4:1 is pulled down by 18 dB x (1 - 1/4) = 13.5 dB.
    func testGainReductionReading() throws {
        let source = try Self.source(
            #"{"version":2,"nodes":[{"type":"compressor","id":"c","params":{"threshold":-24,"ratio":4}}]}"#,
            amplitude: { _ in pow(10, -6.0 / 20) })
        _ = source.render(frames: Int(0.1 * Self.sr))
        let snapshot = try XCTUnwrap(source.fxMeters(owner: "clip:a", at: 0.1))
        let reading = try XCTUnwrap(snapshot.nodes[0])
        XCTAssertEqual(reading.gainReductionDb, 13.5, accuracy: 0.5)
        XCTAssertEqual(reading.inputPeakDb, -6, accuracy: 0.1)
        XCTAssertEqual(reading.inputRMSDb, -9, accuracy: 0.2)
        XCTAssertLessThan(reading.outputPeakDb, reading.inputPeakDb - 12)
        XCTAssertEqual(snapshot.chain?.inputPeakDb ?? 0, reading.inputPeakDb, accuracy: 1e-9)
    }

    func testLimiterGateAndDeesserReportTheirReduction() throws {
        let loud = try Self.source(#"{"version":2,"nodes":[{"type":"limiter","id":"l","params":{"limit":-12}}]}"#,
                                   amplitude: { _ in 0.8 })
        _ = loud.render(frames: 24000)
        let limiter = try XCTUnwrap(loud.fxMeters(owner: "clip:a", at: 0.4)?.nodes[0])
        XCTAssertEqual(limiter.gainReductionDb, 20 * log10(0.8 / pow(10, -12.0 / 20)), accuracy: 0.5)

        let quiet = try Self.source(#"{"version":2,"nodes":[{"type":"gate","id":"g","params":{"threshold":-20,"range":-24}}]}"#,
                                    amplitude: { _ in 0.01 })
        _ = quiet.render(frames: 24000)
        XCTAssertGreaterThan(try XCTUnwrap(quiet.fxMeters(owner: "clip:a", at: 0.4)?.nodes[0]).gainReductionDb, 6)

        let deesser = #"{"version":2,"nodes":[{"type":"deesser","id":"d","params":{"threshold":-30}}]}"#
        let sibilant = try Self.source(deesser, amplitude: { _ in pow(10, -6.0 / 20) }, hz: 7000)
        _ = sibilant.render(frames: 9600)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sibilant.fxMeters(owner: "clip:a", at: 0.2)?.nodes[0]).gainReductionDb, 9)
        let hiss = try Self.source(deesser, amplitude: { _ in pow(10, -6.0 / 20) })
        _ = hiss.render(frames: 4800)
        XCTAssertEqual(try XCTUnwrap(hiss.fxMeters(owner: "clip:a", at: 0.1)?.nodes[0]).gainReductionDb, 0, accuracy: 0.1,
                       "a 1 kHz tone is below the sibilance band")
    }

    /// With the switch off nothing is published, and a gain node is never reducing.
    func testMetersAreOffUntilAskedForAndAGainNodeDoesNotReduce() throws {
        let source = try Self.source(#"{"version":2,"nodes":[{"type":"gain","id":"g","params":{"gain":-6}}]}"#, amplitude: { _ in 0.5 })
        source.collectsFxMeters = false
        _ = source.render(frames: 1280)
        XCTAssertNil(source.fxMeters(owner: "clip:a", at: 0.02)?.nodes[0])
        source.collectsFxMeters = true
        _ = source.render(frames: 1280)
        let reading = try XCTUnwrap(source.fxMeters(owner: "clip:a", at: 0.05)?.nodes[0])
        XCTAssertEqual(reading.gainReductionDb, 0, accuracy: 1e-9)
        XCTAssertEqual(reading.outputPeakDb - reading.inputPeakDb, -6, accuracy: 0.05)
        XCTAssertNil(source.fxMeters(owner: "clip:missing", at: 0.05))
    }

    /// The feeder renders ahead of what is heard: the reading for a time is the one rendered for that time. The ring
    /// holds the last 256 blocks (0.68 s), far more than the output buffer the feeder runs ahead by.
    func testMeterFollowsTheHeardTime() throws {
        // 0.1 until 1.5 s, then 0.8: a change of level every reader can tell apart.
        let source = try Self.source(#"{"version":2,"nodes":[{"type":"gain","id":"g","params":{"gain":0}}]}"#,
                                     amplitude: { $0 < 72000 ? 0.1 : 0.8 })
        _ = source.render(frames: 96000) // queued: everything
        for (time, level) in [(1.4, 0.1), (1.49, 0.1), (1.51, 0.8), (1.9, 0.8)] {
            let reading = try XCTUnwrap(source.fxMeters(owner: "clip:a", at: time)?.nodes[0], "t=\(time)")
            let frame = Int(time * Self.sr)
            XCTAssertLessThanOrEqual(reading.frame, frame)
            XCTAssertLessThan(frame - reading.frame, Self.block, "within one block of t=\(time)")
            XCTAssertEqual(Double(reading.inputPeak), level, accuracy: 0.01, "t=\(time)")
        }
        XCTAssertNil(source.fxMeters(owner: "clip:a", at: 0.3)?.nodes[0], "a time the ring no longer holds is not answered with a newer block")
    }

    /// A module that delays its output (the lookahead limiter) is tagged with the time its output is heard.
    func testALatentModuleIsTaggedWhereItIsHeard() throws {
        let source = try Self.source(#"{"version":2,"nodes":[{"type":"limiter","id":"l","params":{"limit":0,"lookahead":5}}]}"#,
                                     amplitude: { $0 < 72000 ? 0.1 : 0.8 })
        _ = source.render(frames: 96000)
        let before = try XCTUnwrap(source.fxMeters(owner: "clip:a", at: 1.48)?.nodes[0])
        let after = try XCTUnwrap(source.fxMeters(owner: "clip:a", at: 1.52)?.nodes[0])
        XCTAssertLessThan(before.outputPeak, 0.2)
        XCTAssertGreaterThan(after.outputPeak, 0.7)
        XCTAssertEqual(Double(before.inputPeak), 0.1, accuracy: 0.01)
    }

    // MARK: no allocation on the feeder

    #if canImport(Darwin)
    /// Counts every heap allocation the process makes through malloc while `body` runs.
    private static func allocations(_ body: () -> Void) -> Int {
        guard let hook = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return -1 }
        let slot = hook.assumingMemoryBound(to: AllocationHook?.self)
        allocationCount = 0
        slot.pointee = { type, _, _, _, _, _ in if type & 2 != 0 { allocationCount += 1 } }
        body()
        slot.pointee = nil
        return allocationCount
    }

    /// Metering adds nothing to the allocations a block of the feeder already makes.
    func testTheFeederMakesNoAllocationPerBlockWithMetersOn() throws {
        let chain = #"{"version":2,"nodes":[{"type":"compressor","id":"c","params":{"threshold":-24,"ratio":4}},{"type":"limiter","id":"l","params":{}},{"type":"peaking","id":"p","params":{"gain":3}}]}"#
        func blocks(meters: Bool) throws -> Int {
            let source = try Self.source(chain, amplitude: { _ in 0.5 })
            source.collectsFxMeters = meters
            _ = source.render(frames: 128 * 40) // warm-up: lazy runtime tables, protocol caches
            return Self.allocations { for _ in 0..<200 { _ = source.render(frames: 128) } }
        }
        let off = try blocks(meters: false), on = try blocks(meters: true)
        XCTAssertGreaterThanOrEqual(off, 0, "the allocation hook must be available")
        XCTAssertGreaterThan(off, 0, "the counter sees the feeder's own allocations")
        XCTAssertEqual(on, off, "meters on made \(on - off) more allocations over 200 blocks")
    }
    #endif
}

#if canImport(Darwin)
private typealias AllocationHook = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
private nonisolated(unsafe) var allocationCount = 0
#endif
