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
// Issue #24: startExport's final move never replaces a file that appeared at the output path while the render ran.
// The file is created from the progress callback, which runs on the render thread before the move, so the race is
// reproduced deterministically. Inputs are MOVs written by MediaWriter; no FFmpeg.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime
import OneTakeKeyframes

final class ExportNoReplaceTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("export-no-replace-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    var engine: KeyframeRuntime!
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        engine = try KeyframeRuntime(); installKeyframeEngine(engine)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(root)/red.mov") else { return }
        try TestMedia.write(TestVideo(seconds: 1), to: "\(root)/red.mov")
    }
    var root: String { Self.root }

    func project() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"test","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"red","kind":"video","name":"red","source":"red.mov","durationFrames":10}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"red","assetId":"red","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    /// Acceptance 1 + 2: a file created at the output path during the render is left byte-for-byte unchanged, and the
    /// export fails with ExportOutputExistsError instead of replacing it.
    func testAFileCreatedAtTheOutputDuringTheRenderIsKeptAndTheExportFailsWithATypedError() throws {
        let output = "\(root)/raced.mov"
        let users = Data("the user's own file".utf8)
        let firstFrame = OnFirstFrame { _ = FileManager.default.createFile(atPath: output, contents: users) }
        let job = try startExport(project: try project(), projectDir: root, outputPath: output, settings: ExportSettings(format: .mov),
                                  keyframeEngine: engine, progress: firstFrame.callAsFunction)
        let outcome = job.wait(timeout: 120)
        guard case .failed(let message)? = outcome else { return XCTFail("expected a failure, got \(String(describing: outcome))") }
        XCTAssertEqual(message, ExportOutputExistsError(path: output).message)
        XCTAssertEqual(FileManager.default.contents(atPath: output), users, "the file at the output path is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportMetaPath(output)), "no history record is written for a file that is not ours")
        XCTAssertEqual(try leftovers(root), [])
    }

    /// The typed error names the file and says what to do.
    func testTheOutputExistsErrorIsTypedAndActionable() {
        let e = ExportOutputExistsError(path: "/tmp/out/clip.mp4")
        XCTAssertEqual(e.path, "/tmp/out/clip.mp4")
        XCTAssertTrue(e.message.contains("clip.mp4"), e.message)
        XCTAssertEqual(exportErrorMessage(e), e.message)
        XCTAssertEqual("\(e)", e.message)
    }

    /// A cancel after a foreign file appeared at the output path removes nothing that the export did not write.
    func testCancellingAfterAFileAppearedAtTheOutputLeavesThatFileAlone() throws {
        let output = "\(root)/raced-cancel.mov"
        let meta = exportMetaPath(output)
        let users = Data("keep me".utf8)
        let holder = JobHolder()
        let firstFrame = OnFirstFrame {
            _ = FileManager.default.createFile(atPath: output, contents: users)
            _ = FileManager.default.createFile(atPath: meta, contents: users)
            holder.waitForJob().cancel()
        }
        holder.set(try startExport(project: try project(), projectDir: root, outputPath: output, settings: ExportSettings(format: .mov),
                                   keyframeEngine: engine, progress: firstFrame.callAsFunction))
        let job = holder.waitForJob()
        XCTAssertEqual(job.wait(timeout: 120), .cancelled)
        XCTAssertEqual(FileManager.default.contents(atPath: output), users)
        XCTAssertEqual(FileManager.default.contents(atPath: meta), users)
        XCTAssertEqual(try leftovers(root), [])
    }

    /// The ordinary path still lands the export and its sidecar.
    func testAnUncontestedExportStillMovesIntoPlace() throws {
        let output = "\(root)/plain.mov"
        let job = try startExport(project: try project(), projectDir: root, outputPath: output, settings: ExportSettings(format: .mov),
                                  keyframeEngine: engine)
        guard case .completed(let path, let size, _)? = job.wait(timeout: 120) else { return XCTFail("\(String(describing: job.outcome))") }
        XCTAssertEqual(path, output); XCTAssertGreaterThan(size, 0)
        XCTAssertEqual(try MediaProbe.probe(path: output).video?.frames, 30)
        XCTAssertTrue(try String(contentsOfFile: exportMetaPath(output), encoding: .utf8).hasPrefix(#"{"status":"complete","durationMs":"#))
        XCTAssertEqual(try leftovers(root), [])
    }
}

/// Runs `action` once, on the render thread, at the first progress report past 0 % (rendering has started and the
/// final move has not happened yet).
private final class OnFirstFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func callAsFunction(_ p: ExportProgress) {
        lock.lock()
        let run = p.percent > 0 ? action : nil
        if run != nil { action = nil }
        lock.unlock()
        run?()
    }
}

/// Hands the started job to the render thread's callback, which may run before startExport returns.
private final class JobHolder: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var job: ExportJob?
    func set(_ j: ExportJob) { lock.lock(); job = j; lock.unlock(); ready.signal() }
    func waitForJob() -> ExportJob {
        ready.wait(); ready.signal()
        lock.lock(); defer { lock.unlock() }
        return job!
    }
}
