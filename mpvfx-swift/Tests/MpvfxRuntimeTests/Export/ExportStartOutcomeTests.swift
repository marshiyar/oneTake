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
// startExport, the path the Renders tab exports through (RenderRunner → startExport): a project with an audio group
// mixes through the bus graph, an unreadable FX chain fails the job with no output, an older project's undrawn element
// layer is skipped while the project stays unchanged, and an existing output is refused before rendering.
// Inputs are MOV files written by MediaWriter.
import Foundation
import XCTest
@testable import MpvfxShared
@testable import MpvfxRuntime

final class ExportStartOutcomeTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        installAppExportFrames()
        root = try makeMediaTempDir("export-start-")
        try TestMedia.write(TestVideo(color: { $0 < 1 ? [255, 0, 0] : [255, 255, 0] }, tone: 440), to: "\(root)/red.mov")
        try TestMedia.write(TestVideo(color: { _ in [0, 0, 255] }, tone: 880), to: "\(root)/blue.mov")
    }
    override func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }

    private let projectJSON = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"test","revision":0,"frameRate":{"numerator":10,"denominator":1},
     "canvas":{"width":64,"height":32,"background":"#000000"},
     "assets":[{"id":"red","kind":"video","name":"red","source":"red.mov","durationFrames":20},
               {"id":"blue","kind":"video","name":"blue","source":"blue.mov","durationFrames":20}],
     "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
       {"id":"red","assetId":"red","startFrame":0,"durationFrames":5,"sourceInFrame":5,"playbackRate":{"numerator":2,"denominator":1},"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"blue","assetId":"blue","startFrame":10,"durationFrames":5,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
    """#
    private let settings = ExportSettings(format: .mp4, quality: .draft, fps: .fps30)

    private func document(_ json: String) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(json))
    }
    private func export(_ json: String, to name: String) throws -> (ExportOutcome?, String) {
        let output = "\(root)/\(name)"
        let job = try startExport(project: try document(json), projectDir: root, outputPath: output, settings: settings)
        return (job.wait(timeout: 120), output)
    }

    func testAGroupedProjectExportsThroughTheBusGraph() throws {
        let grouped = projectJSON.replacingOccurrences(of: #""id":"red","assetId":"red","#, with: #""id":"red","assetId":"red","audioGroupId":"dialogue","#)
            .replacingOccurrences(of: #""name":"Sequence","#, with: #""name":"Sequence","audioGroups":[{"id":"dialogue"}],"#)
        let (outcome, output) = try export(grouped, to: "grouped.mp4")
        guard case .completed? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
    }

    func testAnUnreadableFXChainFailsTheJobAndLeavesNoOutput() throws {
        let broken = projectJSON.replacingOccurrences(of: #""id":"red","assetId":"red","#, with: #""id":"red","assetId":"red","audioFxChain":"not json","#)
        let (outcome, output) = try export(broken, to: "broken-fx.mp4")
        guard case .failed(let message)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(message.contains("Audio cannot be exported"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        let meta = try String(contentsOfFile: "\(root)/broken-fx.meta.json", encoding: .utf8)
        XCTAssertTrue(meta.hasPrefix(#"{"status":"failed","durationMs":"#), meta)
        XCTAssertEqual(try leftovers(root), [])
    }

    func testAnOlderProjectWithAnUndrawnElementLayerExportsAndKeepsTheLayer() throws {
        // No stored engine name (an older project) and an element layer over the whole sequence that the renderer
        // cannot draw: the export completes, the layer is skipped (the blue clip shows through) and the saved project
        // keeps it.
        let legacy = projectJSON.replacingOccurrences(of: #""mediaEngine":"native","#, with: "")
            .replacingOccurrences(of: #"{"id":"blue","kind":"video""#, with: #"{"id":"card","kind":"element","name":"card","durationFrames":20},{"id":"blue","kind":"video""#)
            .replacingOccurrences(of: #"]}]}}"#, with: #"]},{"id":"over","kind":"video","clips":[{"id":"card","assetId":"card","startFrame":0,"durationFrames":15,"sourceInFrame":0,"binding":{"sourceFile":"index.html","domId":"card"},"effects":[],"parameterTracks":[]}]}]}}"#)
        XCTAssertFalse(legacy.contains("mediaEngine")); XCTAssertTrue(legacy.contains(#""assetId":"card""#))
        try FileManager.default.createDirectory(atPath: "\(root)/.studio", withIntermediateDirectories: false)
        try legacy.write(toFile: "\(root)/.studio/project.json", atomically: false, encoding: .utf8)
        let (outcome, output) = try export(try String(contentsOfFile: "\(root)/.studio/project.json", encoding: .utf8), to: "legacy.mp4")
        guard case .completed? = outcome else { return XCTFail("\(String(describing: outcome))") }
        let pixel = try Exported(path: output).rgb(1.2)
        XCTAssertGreaterThan(pixel[(16 * 64 + 32) * 3 + 2], 200, "the blue clip at 1.2 s, under the skipped layer")
        XCTAssertEqual(try String(contentsOfFile: "\(root)/.studio/project.json", encoding: .utf8), legacy)
    }

    func testRefusesAnExistingOutputBeforeRendering() throws {
        try "keep".write(toFile: "\(root)/exists.mp4", atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try startExport(project: try document(projectJSON), projectDir: root, outputPath: "\(root)/exists.mp4",
                                             settings: settings)) {
            XCTAssertEqual(($0 as? ExportStartError)?.issues, ["The output file already exists."])
        }
        XCTAssertEqual(try String(contentsOfFile: "\(root)/exists.mp4", encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/.studio-render-tmp"))
    }
}
