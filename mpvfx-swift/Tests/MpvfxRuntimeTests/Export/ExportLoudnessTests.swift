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
// Export at a target loudness (#315): the exported sound is measured back with the loudness meter and the true-peak
// reader, never trusting the numbers the export reports about itself. Inputs are MOV (PNG + LPCM) written by MediaWriter.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime
@testable import MpvfxAudioGraph
import OneTakeKeyframes

final class ExportLoudnessTests: XCTestCase {
    nonisolated(unsafe) static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("export-loudness-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    var engine: KeyframeRuntime!
    var root: String { Self.root }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        engine = try KeyframeRuntime(); installKeyframeEngine(engine)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(root)/quiet.mov") else { return }
        // 6 s of a 440 Hz tone at -26 dBFS on both channels (about -26.7 LUFS): under -23 LUFS, so the gain is positive.
        try TestMedia.write(TestVideo(seconds: 6, tone: 440, amplitude: 0.05), to: "\(root)/quiet.mov")
    }

    func project() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"test","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"quiet","kind":"video","name":"quiet","source":"quiet.mov","durationFrames":60}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"quiet","assetId":"quiet","startFrame":0,"durationFrames":60,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    @discardableResult
    func export(_ name: String, _ loudness: MasterLoudnessTarget?, range: ExportFrameRange? = nil) throws -> String {
        let output = "\(root)/\(name).mov"
        try? FileManager.default.removeItem(atPath: output)
        try? FileManager.default.removeItem(atPath: "\(root)/\(name).meta.json")
        let settings = ExportSettings(format: .mov, quality: .draft, fps: .fps30, range: range, loudness: loudness)
        let job = try startExport(project: try project(), projectDir: root, outputPath: output, settings: settings, keyframeEngine: engine)
        guard case .completed? = job.wait(timeout: 120) else { XCTFail("\(String(describing: job.outcome))"); return output }
        return output
    }

    func measure(_ path: String) throws -> (loudness: Double, truePeak: Double, frames: Int) {
        let channels = MasterLoudness.deinterleave(try Exported(path: path).audio())
        return (try LoudnessMeter.integrated(channels, sampleRate: 48_000), try XCTUnwrap(TruePeak.dBTP(channels)), channels[0].count)
    }

    func testA1ExportAtMinus23LUFSMeasuresMinus23AndStaysUnderTheCeiling() throws {
        let before = try measure(try export("off-reference", nil))
        XCTAssertEqual(before.loudness, -26.7, accuracy: 0.3, "the premise: the source sits under the target")
        let out = try measure(try export("lufs23", MasterLoudnessTarget(target: -23, truePeak: -1)))
        XCTAssertEqual(out.loudness, -23, accuracy: 0.5)
        XCTAssertLessThanOrEqual(out.truePeak, -1 + 0.05, "16-bit rounding is the only slack")
        XCTAssertEqual(out.frames, before.frames, "normalising never changes the length")
    }

    func testA1CeilingWinsWhenTheTargetCannotBeReachedUnderIt() throws {
        // -14 LUFS from a -26 dBFS tone needs a peak far over -6 dBTP: the ceiling holds and the output is quieter than asked.
        let out = try measure(try export("lufs14", MasterLoudnessTarget(target: -14, truePeak: -6)))
        XCTAssertLessThanOrEqual(out.truePeak, -6 + 0.05)
        XCTAssertLessThan(out.loudness, -14)
    }

    func testA2OffLeavesTheMixAndTheHistoryRecordAsTheyWere() throws {
        let a = try export("off-a", nil), b = try export("off-b", nil)
        XCTAssertEqual(try Exported(path: a).audio(), try Exported(path: b).audio())
        let tone = try measure(a)
        XCTAssertEqual(tone.loudness, -26.7, accuracy: 0.3, "no gain was applied")
        let meta = try String(contentsOfFile: "\(root)/off-a.meta.json", encoding: .utf8)
        XCTAssertNotNil(meta.range(of: #"^\{"status":"complete","durationMs":\d+\}$"#, options: .regularExpression), meta)
    }

    func testA3HistoryRecordHoldsTargetAndMeasuredValues() throws {
        let out = try measure(try export("history", MasterLoudnessTarget(target: -23, truePeak: -1)))
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/history.meta.json"))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(meta["status"] as? String, "complete")
        let loudness = try XCTUnwrap(meta["loudness"] as? [String: Any])
        XCTAssertEqual(loudness["v"] as? Int, 1)
        XCTAssertEqual(loudness["target"] as? Double, -23)
        XCTAssertEqual(loudness["truePeak"] as? Double, -1)
        XCTAssertEqual(try XCTUnwrap(loudness["measured"] as? Double), out.loudness, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(loudness["measuredTruePeak"] as? Double), out.truePeak, accuracy: 0.2)
    }

    func testRangeExportIsMeasuredOverTheRangeAndKeepsItsLength() throws {
        let out = try measure(try export("range", MasterLoudnessTarget(target: -23, truePeak: -1), range: .init(startFrame: 10, endFrame: 40)))
        XCTAssertEqual(out.loudness, -23, accuracy: 0.5)
        XCTAssertEqual(Double(out.frames), 3 * 48_000, accuracy: 48_000 * 0.05)
    }

    func testAnInvalidTargetIsRefusedBeforeTheExportStarts() throws {
        let settings = ExportSettings(format: .mov, loudness: MasterLoudnessTarget(target: 4, truePeak: -1))
        let plan = planExport(try project(), settings: settings)
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.issues.contains { $0.contains("loudness target") }, "\(plan.issues)")
        XCTAssertThrowsError(try startExport(project: try project(), projectDir: root, outputPath: "\(root)/bad.mov", settings: settings))
    }
}
