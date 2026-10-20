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
// Issue #26, acceptance 2: saves and media moves on one project run one after another on ProjectAccessQueue, with
// every other operation on that project (an import holds it through `withProject`).
import Foundation
import XCTest
@testable import MpvfxBackend
import MpvfxDesktopCore
@testable import MpvfxRuntime
import MpvfxShared

/// Holds the first armed durable write of `.studio/project.json` until `release()`, and logs every document written.
private final class HeldDocumentWrite: DurableWrite, @unchecked Sendable {
    private let base = NativeDurableWrite()
    private let lock = NSLock()
    private var armed = false
    private var _documents: [String] = []
    private let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    var documents: [String] { lock.withLock { _documents } }
    func arm() { lock.withLock { armed = true } }
    func waitUntilHeld() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    func release() { released.signal() }
    func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        if path.hasSuffix("/" + NATIVE_PROJECT_DOCUMENT_PATH) {
            let hold = lock.withLock { () -> Bool in
                _documents.append(String(decoding: data, as: UTF8.self))
                defer { armed = false }
                return armed
            }
            if hold { entered.signal(); released.wait() }
        }
        try base.write(data, to: path, tempName: tempName, preserveMode: preserveMode, beforeRename: beforeRename)
    }
    func syncDirectory(_ path: String) throws { try base.syncDirectory(path) }
}

/// Runs `body` on its own thread, as the UI thread or the autosave queue calls the backend.
private final class OnThread: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private let done = DispatchSemaphore(value: 0)
    init(_ body: @escaping () throws -> Void) {
        Thread { let r = Result(catching: body); self.lock.withLock { self.result = r }; self.done.signal() }.start()
    }
    var finished: Bool { lock.withLock { result != nil } }
    func join() throws { done.wait(); try lock.withLock { result }?.get() }
}

final class ProjectAccessSerialisationTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws { root = try makeTemporaryDirectory(NSTemporaryDirectory() + "mpvfx-serial-") }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    private func document(_ content: String, durationFrames: Double, clip: String) throws -> String {
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(content))
        doc.sequence.durationFrames = durationFrames
        doc.assets = [NativeProjectAsset(id: "asset:clip", kind: .image, name: PosixPath.basename(clip), source: clip, durationFrames: 150)]
        return try serializeNativeProjectDocument(doc)
    }
    private func onDisk(_ project: DesktopProject) throws -> String {
        try String(contentsOfFile: project.directory + "/" + NATIVE_PROJECT_DOCUMENT_PATH, encoding: .utf8)
    }
    /// Waits until `count` operations were queued or `caller` returned without queueing (a call that bypasses the queue).
    private func waitUntilQueued(_ b: RuntimeDesktopBackend, _ count: Int, or caller: OnThread) async {
        let deadline = Date().addingTimeInterval(10)
        while b.projectAccess.submittedCount < count && !caller.finished && Date() < deadline { await Task.yield() }
    }

    func testAConcurrentSaveAndMediaMoveAreSerialised() async throws {
        let held = HeldDocumentWrite()
        let b = RuntimeDesktopBackend(userData: root + "/userData", durableWrite: held)
        let p = try b.createProject(name: "Serial", directory: root + "/Serial")
        try Data("png".utf8).write(to: URL(fileURLWithPath: p.directory + "/clip.png"))
        let placed = try document(p.content, durationFrames: 150, clip: "clip.png")
        try b.saveProject(id: p.id, content: placed)
        let queuedBefore = b.projectAccess.submittedCount

        held.arm()   // the move's document write (asset repointed to moved.png) waits inside the move
        let move = OnThread { _ = try b.renameMedia(projectId: p.id, from: "clip.png", to: "moved.png", content: placed) }
        XCTAssertTrue(held.waitUntilHeld(), "the move reached its document write")
        let mine = try document(placed, durationFrames: 240, clip: "moved.png")
        let save = OnThread { try b.saveProject(id: p.id, content: mine) }
        await waitUntilQueued(b, queuedBefore + 2, or: save)
        let queued = b.projectAccess.submittedCount - queuedBefore
        let saveFinishedEarly = save.finished
        held.release()
        try move.join(); try save.join()

        XCTAssertEqual(queued, 2, "the move and the save both run on the project's access queue")
        XCTAssertFalse(saveFinishedEarly, "the save waited for the move")
        let moved = try document(placed, durationFrames: 150, clip: "moved.png")
        XCTAssertEqual(held.documents.suffix(2), [moved, mine], "the move's document is written before the save's")
        XCTAssertEqual(try onDisk(p), mine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.directory + "/moved.png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.directory + "/clip.png"))
        try await b.close()
    }

    func testASaveWaitsForAnImportHoldingTheProject() async throws {
        let b = RuntimeDesktopBackend(userData: root + "/userData", durableWrite: NativeDurableWrite())
        let p = try b.createProject(name: "Import", directory: root + "/Import")
        let started = expectation(description: "the import holds the project")
        let release = DispatchSemaphore(value: 0)
        // Blocks the import's thread from a sync closure: DispatchSemaphore.wait is unavailable in async code.
        let holdUntilReleased: @Sendable () -> Void = { release.wait() }
        let importing = Task { try await b.withProject(p.id) { started.fulfill(); holdUntilReleased() } }
        await fulfillment(of: [started], timeout: 5)
        let queuedBefore = b.projectAccess.submittedCount
        let mine = try document(p.content, durationFrames: 240, clip: "clip.png")
        let save = OnThread { try b.saveProject(id: p.id, content: mine) }
        await waitUntilQueued(b, queuedBefore + 1, or: save)
        let diskWhileHeld = try onDisk(p)
        let saveFinishedEarly = save.finished
        release.signal()
        try await importing.value
        try save.join()

        XCTAssertFalse(saveFinishedEarly, "the save waited for the import")
        XCTAssertEqual(diskWhileHeld, p.content, "nothing was written while the import held the project")
        XCTAssertEqual(try onDisk(p), mine)
        try await b.close()
    }
}
