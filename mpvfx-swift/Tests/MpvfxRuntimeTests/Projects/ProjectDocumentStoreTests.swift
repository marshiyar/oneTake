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

final class ProjectDocumentStoreTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "mpvfx-docstore-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    private func documentText(_ dir: String) throws -> String {
        try String(contentsOfFile: dir + "/" + NATIVE_PROJECT_DOCUMENT_PATH, encoding: .utf8)
    }
    private func edited(_ content: String, durationFrames: Double) throws -> String {
        var doc = try ProjectDocuments.validate(content)
        doc.sequence.durationFrames = durationFrames
        return try serializeNativeProjectDocument(doc)
    }

    func testCreateWritesAValidStarterDocumentAndOpenReadsItBack() throws {
        let dir = root + "/My Film"
        let created = try ProjectDocumentStore.create(at: dir, name: "My Film", id: "project-1", durableWrite: TestDurableWrite())
        XCTAssertEqual(created.id, "project-1")
        let onDisk = try documentText(dir)
        XCTAssertEqual(onDisk, created.savedContent)
        let doc = try ProjectDocuments.validate(onDisk)
        XCTAssertEqual(doc.sequence.name, "My Film")
        XCTAssertEqual(doc.canvas.width, 1920); XCTAssertEqual(doc.frameRate.numerator, 30)
        XCTAssertEqual(doc.mediaEngine, .native)
        XCTAssertTrue(onDisk.contains(#""mediaEngine":"native""#) || onDisk.contains(#""mediaEngine": "native""#), onDisk)

        let opened = try ProjectDocumentStore.open(dir, durableWrite: TestDurableWrite())
        XCTAssertEqual(opened.opened, created.opened)
        // The document path itself and its .studio folder open the same project.
        XCTAssertEqual(try ProjectDocumentStore.open(dir + "/.studio/project.json", durableWrite: TestDurableWrite()).directory, opened.directory)
        XCTAssertEqual(try ProjectDocumentStore.open(dir + "/.studio", durableWrite: TestDurableWrite()).directory, opened.directory)
    }

    func testSaveRoundTripsAndLeavesNoJournalBehind() throws {
        let dir = root + "/p"
        let store = try ProjectDocumentStore.create(at: dir, name: "P", durableWrite: TestDurableWrite())
        let next = try edited(store.savedContent, durationFrames: 300)
        try store.save(next)
        XCTAssertEqual(try documentText(dir), next)
        XCTAssertEqual(store.savedContent, next)
        let reopened = try ProjectDocumentStore.open(dir, durableWrite: TestDurableWrite())
        XCTAssertEqual(try ProjectDocuments.validate(reopened.savedContent).sequence.durationFrames, 300)
        // Saved twice more (including a no-op) from the reopened store.
        let third = try edited(next, durationFrames: 450)
        try reopened.save(third); try reopened.save(third)
        XCTAssertEqual(try documentText(dir), third)
        let journals = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/" + JOURNAL_PARENT + "/studio-transactions")) ?? []
        XCTAssertEqual(journals.filter { $0.hasSuffix(".json") }, [])
    }

    func testSaveRefusesToOverwriteAnExternalEdit() throws {
        let dir = root + "/p"
        let store = try ProjectDocumentStore.create(at: dir, name: "P", durableWrite: TestDurableWrite())
        let external = try edited(store.savedContent, durationFrames: 99)
        try external.write(toFile: dir + "/" + NATIVE_PROJECT_DOCUMENT_PATH, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.save(try edited(store.savedContent, durationFrames: 300))) { error in
            XCTAssertEqual((error as? ProjectDocumentError)?.kind, .conflict)
        }
        XCTAssertEqual(try documentText(dir), external)
        // Taking the disk version makes the next save go through.
        XCTAssertEqual(try store.reload(), external)
        let mine = try edited(external, durationFrames: 300)
        try store.save(mine)
        XCTAssertEqual(try documentText(dir), mine)
    }

    func testRejectsInvalidDocumentsExistingDirectoriesAndNonProjects() throws {
        let store = try ProjectDocumentStore.create(at: root + "/p", name: "P", durableWrite: TestDurableWrite())
        XCTAssertThrowsError(try store.save("{\"schemaVersion\":1}")) { XCTAssertEqual(($0 as? ProjectDocumentError)?.kind, .invalidDocument) }
        XCTAssertThrowsError(try ProjectDocumentStore.create(at: root + "/p", name: "Again", durableWrite: TestDurableWrite())) {
            XCTAssertEqual(($0 as? ProjectDocumentError)?.kind, .alreadyExists)
        }
        try FileManager.default.createDirectory(atPath: root + "/plain", withIntermediateDirectories: true)
        XCTAssertThrowsError(try ProjectDocumentStore.open(root + "/plain", durableWrite: TestDurableWrite())) {
            XCTAssertEqual(($0 as? ProjectDocumentError)?.kind, .notAProject)
        }
        // An empty existing directory is fine to create into.
        XCTAssertNoThrow(try ProjectDocumentStore.create(at: root + "/plain", name: "Plain", durableWrite: TestDurableWrite()))
    }

    func testOpenRollsBackASaveInterruptedByACrash() throws {
        let dir = root + "/p"
        let store = try ProjectDocumentStore.create(at: dir, name: "P", durableWrite: TestDurableWrite())
        let original = store.savedContent
        // Power loss after the target was written but before the journal was marked committed.
        let crashing = DurableFileTransactionStore(.init(projectRoot: dir, durableWrite: TestDurableWrite(),
                                                         afterTargetWrite: { _, _ in throw PowerLoss("after write") }))
        XCTAssertThrowsError(try crashing.commit(DurableFileTransactionInput(id: "save-crash", files: [
            .init(path: NATIVE_PROJECT_DOCUMENT_PATH, expectedBefore: original, after: try edited(original, durationFrames: 300)),
        ])))
        let reopened = try ProjectDocumentStore.open(dir, durableWrite: TestDurableWrite())
        XCTAssertEqual(reopened.savedContent, original)
        XCTAssertEqual(try documentText(dir), original)
    }

    func testDescribeImportedMediaReadsDurationsAndReportsUnreadableFiles() throws {
        let dir = root + "/p"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let blue = TestMedia.solid((0, 0, 255), width: 64, height: 32)
        try TestMedia.writeMOV(dir + "/clip.mov", frames: Array(repeating: blue, count: 20), width: 64, height: 32, fps: 10)
        try TestMedia.wav(TestMedia.tone(seconds: 1, rate: 8000), rate: 8000, channels: 1).write(to: URL(fileURLWithPath: dir + "/tone.wav"))
        try TestMedia.png(blue, width: 64, height: 32).write(to: URL(fileURLWithPath: dir + "/still.png"))
        try "not png".write(toFile: dir + "/broken.png", atomically: false, encoding: .utf8)
        try "not audio".write(toFile: dir + "/broken.mp3", atomically: false, encoding: .utf8)
        let r = describeImportedMedia(projectDir: dir, files: ["clip.mov", "tone.wav", "still.png", "broken.png", "broken.mp3"])
        XCTAssertEqual(r.media.map(\.path), ["clip.mov", "tone.wav", "still.png"])
        XCTAssertEqual(r.media.map(\.kind), [.video, .audio, .image])
        XCTAssertEqual(r.media[0].duration, 2, accuracy: 0.05); XCTAssertTrue(r.media[0].hasVideo); XCTAssertFalse(r.media[0].hasAudio)
        XCTAssertEqual(r.media[0].width, 64); XCTAssertEqual(r.media[0].height, 32)
        XCTAssertEqual(r.media[1].duration, 1, accuracy: 0.05); XCTAssertTrue(r.media[1].hasAudio); XCTAssertNil(r.media[1].width)
        XCTAssertEqual(r.media[2].width, 64); XCTAssertEqual(r.media[2].duration, 0)
        XCTAssertEqual(r.invalid.map(\.name), ["broken.png", "broken.mp3"])
    }
}
