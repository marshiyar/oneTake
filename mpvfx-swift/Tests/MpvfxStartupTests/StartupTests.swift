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
// Startup wiring checks: the shared desktop startup installs the real the keyframe engine keyframe engine, and a project
// with keyframes then validates and parses. Plus an on-disk round trip of a clip crop in the native document.
import Foundation
import XCTest
@testable import MpvfxShared
import OneTakeKeyframes
import MpvfxRuntime

private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private func scratchDir(_ name: String) throws -> URL {
    let dir = packageRoot.appendingPathComponent(".build/port-tmp/\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".studio"), withIntermediateDirectories: true)
    return dir
}

final class KeyframeEngineStartupTests: XCTestCase {
    func keyframedProjectJSON() throws -> String {
        var project = try parseNativeProjectDocument(NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"project:kf","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#000000"},
         "assets":[{"id":"asset:1","kind":"video","name":"clip.mp4","durationFrames":180}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:v1","kind":"video","clips":[
           {"id":"clip:1","assetId":"asset:1","startFrame":0,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#))
        project.sequence.tracks[0].clips[0].parameterTracks = [try createNativeParameterTrack(.init(
            id: "parameter:rotation", parameterId: "transform.rotation", valueType: .number, frameRate: .init(numerator: 30, denominator: 1),
            keyframes: [.init(id: "start", frame: 0, value: .number(0), outgoing: .linear), .init(id: "end", frame: 90, value: .number(-180), outgoing: .linear)]))]
        return try serializeNativeProjectDocument(project)
    }

    func testStartupInstallsEngineAndKeyframedProjectValidates() throws {
        // Nothing else in this test bundle installs an engine, so this starts from the app's cold state.
        installKeyframeEngine(nil)
        XCTAssertThrowsError(try keyframeEngine()) { XCTAssertTrue("\($0)".contains("keyframe engine is not loaded")) }

        XCTAssertNil(installDefaultKeyframeEngineAtStartup())
        XCTAssertTrue(keyframeEngineInstalled())
        XCTAssertTrue(try keyframeEngine() is KeyframeRuntime)
        XCTAssertNil(installDefaultKeyframeEngineAtStartup())   // idempotent

        let json = try keyframedProjectJSON()
        XCTAssertEqual(validateNativeProjectDocument(try NativeJSONValue.parse(json)), [])
        let dir = try scratchDir("keyframed")
        defer { try? FileManager.default.removeItem(at: dir) }
        try json.write(to: dir.appendingPathComponent(".studio/project.json"), atomically: true, encoding: .utf8)
        let onDisk = try String(contentsOf: dir.appendingPathComponent(".studio/project.json"), encoding: .utf8)
        XCTAssertNoThrow(try parseNativeProjectDocument(NativeJSONValue.parse(onDisk)))   // keyframed document parses with the engine
        let parsed = try parseNativeProjectDocument(NativeJSONValue.parse(json))
        XCTAssertEqual(try evaluateNativeParameterTrack(parsed.sequence.tracks[0].clips[0].parameterTracks[0], projectFrame: 45, engine: keyframeEngine()), .number(-90))
    }
}

final class CropRoundTripTests: XCTestCase {
    let json = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"project:crop","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#000000"},
     "assets":[{"id":"asset:1","kind":"video","name":"clip.mp4","durationFrames":300}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:v1","kind":"video","clips":[
       {"id":"clip:1","assetId":"asset:1","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """#

    func testCropIsSavedInTheNativeDocumentAndReloads() throws {
        let dir = try scratchDir("crop")
        defer { try? FileManager.default.removeItem(at: dir) }
        var doc = try parseNativeProjectDocument(NativeJSONValue.parse(json))
        XCTAssertNil(doc.sequence.tracks[0].clips[0].crop)
        doc.sequence.tracks[0].clips[0].crop = NativeClipCrop(top: 12, right: 0, bottom: 8.5, left: 4)
        let path = dir.appendingPathComponent(".studio/project.json")
        try serializeNativeProjectDocument(doc).write(to: path, atomically: true, encoding: .utf8)
        let reloaded = try parseNativeProjectDocument(NativeJSONValue.parse(String(contentsOf: path, encoding: .utf8)))
        XCTAssertEqual(reloaded.sequence.tracks[0].clips[0].crop, NativeClipCrop(top: 12, right: 0, bottom: 8.5, left: 4))
    }

    func testInvalidCropIsRejected() throws {
        var raw = try NativeJSONValue.parse(json)
        var sequence = raw["sequence"]!
        var tracks = sequence["tracks"]!.arrayValue!
        var clips = tracks[0]["clips"]!.arrayValue!
        clips[0]["crop"] = .object(["top": .number(-1), "right": .number(0), "bottom": .number(0), "left": .number(0)])
        tracks[0]["clips"] = .array(clips); sequence["tracks"] = .array(tracks); raw["sequence"] = sequence
        let issues = validateNativeProjectDocument(raw)
        XCTAssertEqual(issues.map(\.path), ["sequence.tracks[0].clips[0].crop"])
    }
}
