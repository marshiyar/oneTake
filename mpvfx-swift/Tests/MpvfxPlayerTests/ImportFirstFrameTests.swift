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
@testable import MpvfxPlayer
import MpvfxTimeline
import MpvfxCanvas
import MpvfxShared

/// A freshly imported file carries the natural size probed during the import (nativeImportedMediaAsset), so the very
/// first stage and preview render of its clip is already the fitted box on every insert path: never a full-frame
/// picture that snaps to size once a later probe answers. A clip whose size is still being probed is not drawn.
final class ImportFirstFrameTests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"id":"project:import","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#000000"},"assets":[],
     "sequence":{"id":"seq","name":"Sequence","tracks":[{"id":"v1","kind":"video","clips":[]},{"id":"v2","kind":"video","clips":[]}]}}
    """#
    /// (kind, file, natural size from the import probe, its fitted box in the 1920×1080 canvas)
    static let files: [(NativeProjectAssetKind, String, NativeMediaNaturalSize, NativeClipLayoutBox)] = [
        (.video, "square.mp4", .init(width: 1080, height: 1080), .init(left: 420, top: 0, width: 1080, height: 1080)),
        (.image, "portrait.jpg", .init(width: 1080, height: 1920), .init(left: 656, top: 0, width: 608, height: 1080)),
        (.video, "wide.mp4", .init(width: 3840, height: 1080), .init(left: 0, top: 270, width: 1920, height: 540)),
        (.image, "small.png", .init(width: 320, height: 200), .init(left: 800, top: 440, width: 320, height: 200)),
    ]

    /// What the stage and the preview draw for `clipId` in the first composition built after the edit.
    func firstRender(_ e: TimelineEditor, _ clipId: String, pending: Set<String> = []) -> (stage: CanvasRect, preview: CanvasRect?) {
        let comp = PreviewComposition(document: e.document, projectDir: URL(fileURLWithPath: "/import"), engine: nil,
                                      naturalSize: e.naturalSize, sizePending: { pending.contains($0.source ?? "") }, fileExists: { _ in true })
        let c = e.clip(clipId)!.clip
        let t = (c.startFrame + 1) / e.fps
        let kind: TimelineClipKind = e.document.assets.first { $0.id == c.assetId }?.kind == .image ? .image : .video
        let stage = StageGeometry.rect(base: StageGeometry.baseRect(editor: e, clipId: clipId, kind: kind, time: t), e.transform(clipId: clipId, time: t))
        return (stage, comp.layers(at: t).first { $0.clipId == clipId }?.box)
    }

    func rect(_ b: NativeClipLayoutBox) -> CanvasRect { CanvasRect(x: b.left, y: b.top, width: b.width, height: b.height) }

    func importAll(_ e: TimelineEditor) -> [String] {
        var d = e.document
        for (i, f) in Self.files.enumerated() {
            d.assets.append(nativeImportedMediaAsset(id: "asset:\(i)", kind: f.0, name: f.1, source: f.1, durationSeconds: 10, fps: e.fps,
                                                     width: f.2.width, height: f.2.height))
        }
        e.replaceDocument(d, inverse: .restoreDocument(e.document))
        return Self.files.indices.map { "asset:\($0)" }
    }

    func assertFitted(_ e: TimelineEditor, _ clipId: String, _ expected: NativeClipLayoutBox, _ path: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let r = firstRender(e, clipId)
        XCTAssertEqual(r.stage, rect(expected), "\(path): stage box", file: file, line: line)
        XCTAssertEqual(r.preview, rect(expected), "\(path): preview box", file: file, line: line)
    }

    func testImportedAssetsCarryTheirProbedSize() throws {
        let e = try TimelineEditor(json: Self.json)
        let ids = importAll(e)
        for (i, id) in ids.enumerated() { XCTAssertEqual(e.document.assets.first { $0.id == id }?.naturalSize, Self.files[i].2) }
        let audio = nativeImportedMediaAsset(id: "a", kind: .audio, name: "a.wav", source: "a.wav", durationSeconds: 2, fps: 30, width: 1, height: 1)
        XCTAssertNil(audio.naturalSize); XCTAssertEqual(audio.durationFrames, 60)
        XCTAssertEqual(nativeImportedMediaAsset(id: "s", kind: .image, name: "s.jpg", source: "s.jpg", durationSeconds: 0, fps: 30,
                                                width: 10, height: 10).durationFrames, 150, "stills last 5 s")
    }

    /// Bin import then double-click / Add to timeline, a bin drag onto the timeline, a bin drag onto the stage, Add at
    /// playhead and a Finder / file-manager drop over the tracks all place through TimelineEditor.insertClip.
    func testEveryInsertPathDrawsTheFittedBoxFirst() throws {
        let paths: [(String, (TimelineEditor, String) -> String?)] = [
            ("bin import + add to timeline", { e, a in e.insertClip(assetId: a, at: 0) }),
            ("timeline drop", { e, a in e.insertClip(assetId: a, at: 2, trackId: "v2") }),
            ("stage drop (at the playhead)", { e, a in e.insertClip(assetId: a, at: 1.5) }),
            ("add at playhead", { e, a in e.insertClip(assetId: a, at: 4) }),
            ("file-manager drop over the tracks", { e, a in e.insertClip(assetId: a, at: 6, trackId: "v1") }),
        ]
        for (name, insert) in paths {
            let e = try TimelineEditor(json: Self.json)
            for (i, a) in importAll(e).enumerated() {
                let id = try XCTUnwrap(insert(e, a), name)
                assertFitted(e, id, Self.files[i].3, "\(name) \(Self.files[i].1)")
            }
        }
    }

    func testPasteDrawsTheFittedBoxFirst() throws {
        let e = try TimelineEditor(json: Self.json)
        for (i, a) in importAll(e).enumerated() {
            let id = try XCTUnwrap(e.insertClip(assetId: a, at: Double(i) * 20))
            let pasted = e.paste(try XCTUnwrap(e.copyClips([id])), at: Double(i) * 20 + 11)
            XCTAssertEqual(pasted.count, 1)
            assertFitted(e, pasted[0], Self.files[i].3, "paste \(Self.files[i].1)")
        }
    }

    func testAClipWhoseSizeIsStillProbingIsNotDrawn() throws {
        let e = try TimelineEditor(json: Self.json)
        var d = e.document
        d.assets.append(nativeImportedMediaAsset(id: "u", kind: .video, name: "unknown.mp4", source: "unknown.mp4", durationSeconds: 10, fps: 30,
                                                 width: nil, height: nil))
        e.replaceDocument(d, inverse: .restoreDocument(e.document))
        let id = try XCTUnwrap(e.insertClip(assetId: "u", at: 0))
        XCTAssertNil(firstRender(e, id, pending: ["unknown.mp4"]).preview, "no full-frame picture while the probe runs")
        // The probe answers: the first picture drawn is the fitted box.
        e.naturalSize = { $0.naturalSize ?? ($0.id == "u" ? NativeMediaNaturalSize(width: 3840, height: 1080) : nil) }
        XCTAssertEqual(firstRender(e, id).preview, CanvasRect(x: 0, y: 270, width: 1920, height: 540))
        XCTAssertEqual(firstRender(e, id).stage, CanvasRect(x: 0, y: 270, width: 1920, height: 540))
    }
}
