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
import MpvfxShared
@testable import MpvfxRuntime

/// A DurableWrite that records each path it publishes, or refuses every write.
private final class CaptionRecordingWrite: DurableWrite, @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.withLock { _paths } }
    let failing: Bool
    private let inner = TestDurableWrite()
    init(failing: Bool = false) { self.failing = failing }
    func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        lock.withLock { _paths.append(path) }
        try inner.write(data, to: path, tempName: tempName, preserveMode: preserveMode) {
            try beforeRename()
            if failing { throw CaptionFileError("refused by the test") }
        }
    }
    func syncDirectory(_ path: String) throws { try inner.syncDirectory(path) }
}

/// SRT export (acceptance 4) and import into a project (acceptances 1 and 3: save and open, never partly applied).
final class ProjectCaptionsTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws { root = try makeTempDir("captions-") }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    private func file(_ name: String, _ text: String) throws -> String {
        let path = root + "/" + name
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }
    private func documentOnDisk(_ dir: String) throws -> String {
        try String(contentsOfFile: dir + "/" + NATIVE_PROJECT_DOCUMENT_PATH, encoding: .utf8)
    }

    private let cues = [
        NativeCaptionCue(id: "cue-1", startMs: 0, endMs: 999, text: "First"),
        NativeCaptionCue(id: "cue-2", startMs: 999, endMs: 61_001, text: "<b>Two</b>\n  indented line\twith a tab"),
        NativeCaptionCue(id: "cue-3", startMs: 360_000_000, endMs: NATIVE_CAPTION_MAX_MILLISECONDS, text: "Ünïcödé 字幕 🎬"),
    ]

    func testExportWritesAFileThatImportsBackIntoIdenticalCues() throws {
        let text = SRTWriter.text(cues)
        XCTAssertTrue(text.hasPrefix("1\r\n00:00:00,000 --> 00:00:00,999\r\nFirst\r\n\r\n2\r\n00:00:00,999 --> 00:01:01,001\r\n"), text)
        XCTAssertTrue(text.contains("3\r\n100:00:00,000 --> 999:59:59,999\r\n"), text)
        XCTAssertEqual(try SRTReader.read(Data(text.utf8)), cues)
    }

    func testExportPublishesThroughTheDurableWritePath() throws {
        let store = try ProjectDocumentStore.create(at: root + "/p", name: "P", durableWrite: TestDurableWrite())
        var doc = try ProjectDocuments.validate(store.savedContent)
        doc.sequence.captions = NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues)
        let content = try serializeNativeProjectDocument(doc)
        let target = root + "/out.srt"
        let recording = CaptionRecordingWrite()
        try SRTWriter.write(cues, to: target, durableWrite: recording)
        XCTAssertEqual(recording.paths, [target])
        XCTAssertEqual(try SRTReader.read(try Data(contentsOf: URL(fileURLWithPath: target))), cues)
        // The store's export uses the same path; a failed write leaves the earlier file as it was.
        XCTAssertEqual(try store.exportCaptions(toSRT: target, content: content), 3)
        try Data("old".utf8).write(to: URL(fileURLWithPath: target))
        XCTAssertThrowsError(try SRTWriter.write(cues, to: target, durableWrite: CaptionRecordingWrite(failing: true)))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root).filter { $0.hasSuffix(".tmp") }, [])
    }

    func testExportRefusesADocumentWithoutCaptionsAndCuesSRTCannotCarry() throws {
        let store = try ProjectDocumentStore.create(at: root + "/p", name: "P", durableWrite: TestDurableWrite())
        XCTAssertThrowsError(try store.exportCaptions(toSRT: root + "/none.srt", content: store.savedContent)) {
            XCTAssertEqual(($0 as? CaptionExportError)?.kind, .noCaptions)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/none.srt"))
        let bad = [NativeCaptionCue(id: "a", startMs: 0, endMs: 10, text: "x\n\ny")]
        XCTAssertThrowsError(try SRTWriter.write(bad, to: root + "/bad.srt", durableWrite: TestDurableWrite())) {
            XCTAssertEqual(($0 as? CaptionExportError)?.kind, .invalidCaptions)
        }
        XCTAssertThrowsError(try SRTWriter.validateCues([NativeCaptionCue(id: "a", startMs: -5, endMs: 10, text: "x")]))
    }

    func testImportSavesTheCaptionTrackAndItSurvivesReopening() throws {
        let dir = root + "/p"
        let store = try ProjectDocumentStore.create(at: dir, name: "P", durableWrite: TestDurableWrite())
        let srt = try file("in.srt", SRTWriter.text(cues))
        let result = try store.importCaptions(fromSRT: srt, content: store.savedContent)
        XCTAssertEqual(result.cueCount, 3)
        XCTAssertEqual(try documentOnDisk(dir), result.content)
        let reopened = try ProjectDocumentStore.open(dir, durableWrite: TestDurableWrite())
        let captions = try ProjectDocuments.validate(reopened.savedContent).sequence.captions
        XCTAssertEqual(captions, NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues))
        // A second import replaces the cues and keeps the track id.
        var doc = try ProjectDocuments.validate(reopened.savedContent)
        doc.sequence.captions?.id = "captions:custom"
        let renamed = try serializeNativeProjectDocument(doc)
        let again = try reopened.importCaptions(fromSRT: try file("one.srt", "1\n00:00:01,000 --> 00:00:02,000\nOnly\n"), content: renamed)
        XCTAssertEqual(try ProjectDocuments.validate(again.content).sequence.captions,
                       NativeCaptionTrack(id: "captions:custom", cues: [NativeCaptionCue(id: "cue-1", startMs: 1000, endMs: 2000, text: "Only")]))
    }

    func testAMalformedFileFailsNamingItsLineAndNeverPartlyApplies() throws {
        let dir = root + "/p"
        let store = try ProjectDocumentStore.create(at: dir, name: "P", durableWrite: TestDurableWrite())
        let before = try documentOnDisk(dir)
        // Two good cues, then a bad timestamp on line 11: nothing of the file reaches the document.
        let srt = try file("bad.srt", SRTWriter.text(Array(cues.prefix(2))).replacingOccurrences(of: "\r\n", with: "\n")
            + "3\n00:00:70,000 --> 00:01:00,000\nBad\n")
        XCTAssertThrowsError(try store.importCaptions(fromSRT: srt, content: store.savedContent)) { error in
            XCTAssertEqual((error as? SRTReadError)?.line, 11, "\(error)")
            XCTAssertTrue("\(error)".hasPrefix("Line 11: "), "\(error)")
        }
        XCTAssertEqual(try documentOnDisk(dir), before)
        XCTAssertEqual(store.savedContent, before)
        XCTAssertThrowsError(try store.importCaptions(fromSRT: root + "/missing.srt", content: store.savedContent)) {
            XCTAssertTrue($0 is CaptionFileError, "\($0)")
        }
        XCTAssertThrowsError(try store.importCaptions(fromSRT: root, content: store.savedContent)) { XCTAssertTrue($0 is CaptionFileError) }
        XCTAssertEqual(try documentOnDisk(dir), before)
    }
}
