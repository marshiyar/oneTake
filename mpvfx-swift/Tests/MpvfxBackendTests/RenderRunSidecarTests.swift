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
// Issue #24: a Renders-tab export writes its `<jobId>.meta.json` history record once. startExport writes it; RenderRun
// used to write it a second time through recordRender. The record's file identity (inode) is taken when startExport
// reports 100 % (after its write, before the completion callback) and compared once the run has finished: a second
// write (an atomic replace) gives the path a new inode.
import Foundation
import XCTest
import MpvfxBackend
import MpvfxDesktopCore
import OneTakeMedia
import MpvfxPlayer
import MpvfxRuntime
import MpvfxShared

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    func update(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
}

final class RenderRunSidecarTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "mpvfx-render-sidecar-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    private func redMov(_ path: String) throws {
        var config = MediaWriter.Config(container: .mov, width: 64, height: 32)
        config.fpsNumerator = 10
        let writer = try MediaWriter(path: path, config: config)
        let red = [UInt8]((0..<(64 * 32)).flatMap { _ -> [UInt8] in [255, 0, 0, 255] })
        for _ in 0..<10 { try writer.addVideo(red) }
        try writer.finish()
    }

    private func fileNumber(_ path: String) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    func testRenderRunWritesTheRenderHistorySidecarOnce() throws {
        NativeExportFrames.defaultRenderer = PreviewExportFrames.factory   // as main.swift installs it
        let backend = RuntimeDesktopBackend(userData: root + "/userData", durableWrite: NativeDurableWrite())
        let project = try backend.createProject(name: "Sidecar", directory: nil)
        try redMov(project.directory + "/red.mov")
        let document = try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"sidecar","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"red","kind":"video","name":"red","source":"red.mov","durationFrames":10}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"c","assetId":"red","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
        """#))
        var request = RenderRequest(projectId: project.id, document: document,
                                    settings: ExportSettings(format: .mov, quality: .draft, fps: .fps30),
                                    settingsJSON: .object(["format": .string("mov")]))
        request.jobId = "render-sidecar"
        let meta = try backend.rendersDirectory(projectId: project.id) + "/render-sidecar.meta.json"
        let atComplete = Locked<(UInt64?, Data?)>((nil, nil))
        let outcome = Locked<ExportOutcome?>(nil)
        let done = expectation(description: "render finished")
        var callbacks = RenderCallbacks { o, _ in outcome.update { $0 = o }; done.fulfill() }
        callbacks.progress = { [self] p in
            guard p.stage == "Complete" else { return }
            let id = fileNumber(meta), bytes = FileManager.default.contents(atPath: meta)
            atComplete.update { $0 = (id, bytes) }
        }
        _ = try RenderRun.start(backend: backend, request, callbacks)
        wait(for: [done], timeout: 120)
        guard case .completed? = outcome.value else { return XCTFail("\(String(describing: outcome.value))") }
        let (firstId, firstBytes) = atComplete.value
        XCTAssertNotNil(firstId, "startExport wrote the history record before reporting completion")
        XCTAssertEqual(fileNumber(meta), firstId, "the history record was not written a second time")
        XCTAssertEqual(FileManager.default.contents(atPath: meta), firstBytes)
        let history = try backend.renders(projectId: project.id)
        XCTAssertEqual(history.map(\.id), ["render-sidecar"])
        XCTAssertEqual(history.first?.status, "complete")
        backend.closeProject(id: project.id)
    }
}
