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
// Issue #273 A4: one still clip per move kind, exported as MOV (PNG frames, lossless) and read back with the media
// engine. At 3 times inside each clip's move, the exported frame and the preview compositor's frame (PreviewCompositor
// drawing the same document into a raster canvas at the export size) agree within 1 level per channel.
import Foundation
import XCTest
import OneTakeMedia
import OneTakeKeyframes
import MpvfxCanvas
@testable import MpvfxPlayer
@testable import MpvfxShared
@testable import MpvfxRuntime

final class ExportMovesMatchTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("export-moves-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(Self.root)/still.bmp") else { return }
        try TestMedia.bmp(width: 32, height: 16, rgb: [230, 60, 20], to: "\(Self.root)/still.bmp")
    }

    /// (move JSON, clip frames checked): In kinds are checked inside their 10 frames, Out kinds inside their last
    /// 10, loops across two periods.
    static let kinds: [(String, [Int])] = [
        (#"{"v":1,"in":{"kind":"slide","frames":10,"amount":30}}"#, [1, 4, 7]),
        (#"{"v":1,"in":{"kind":"rise","frames":10,"amount":20}}"#, [2, 5, 7]),
        (#"{"v":1,"in":{"kind":"drop","frames":10,"amount":20,"ease":{"type":"linear"}}}"#, [2, 5, 8]),
        (#"{"v":1,"out":{"kind":"grow","frames":10,"amount":60}}"#, [13, 15, 18]),
        (#"{"v":1,"out":{"kind":"shrink","frames":10}}"#, [13, 15, 18]),
        (#"{"v":1,"out":{"kind":"spin","frames":10,"amount":120}}"#, [13, 15, 18]),
        (#"{"v":1,"loop":{"kind":"float","periodFrames":8,"amount":20}}"#, [2, 6, 13]),
        (#"{"v":1,"loop":{"kind":"pulse","periodFrames":8,"amount":40}}"#, [2, 6, 13]),
        (#"{"v":1,"loop":{"kind":"sway","periodFrames":8,"amount":30}}"#, [1, 3, 13]),
        (#"{"v":1,"loop":{"kind":"drift","periodFrames":10,"amount":20}}"#, [2, 6, 13]),
    ]

    /// 96×48 at 10 fps: the ten clips one after another, 20 frames each, a 32×16 still in the middle of the frame.
    func document(engine: KeyframeEngine) throws -> NativeProjectDocument {
        let clips = Self.kinds.enumerated().map { i, k in
            #"{"id":"c\#(i)","assetId":"still","startFrame":\#(i * 20),"durationFrames":20,"sourceInFrame":0,"muted":true,"#
                + #""staticParameters":{"layout.left":32,"layout.top":16,"layout.width":32,"layout.height":16},"effects":[],"parameterTracks":[],"moves":\#(k.0)}"#
        }.joined(separator: ",")
        return try parseNativeProjectDocument(try NativeJSONValue.parse("""
        {"schemaVersion":1,"mediaEngine":"native","id":"moves","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":96,"height":48,"background":"#102030"},
         "assets":[{"id":"still","kind":"image","name":"still","source":"still.bmp","durationFrames":1}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"v","kind":"video","clips":[\(clips)]}]}}
        """), engine: engine)
    }

    /// The preview compositor's frame at `time`, as the stage shows it after a seek: a compositor with nothing cached
    /// decodes each visible still at the size the stage asks for (its on-screen size), then draws the frame.
    func compositorFrame(_ comp: PreviewComposition, at time: Double) throws -> [UInt8] {
        let cx = PreviewCompositor()
        defer { cx.stopAll() }
        cx.composition = comp
        for layer in comp.layers(at: time) where layer.isVisible {
            XCTAssertNotNil(cx.decodeRawNow(layer, time: time, fps: comp.fps, size: cx.decodeSize(layer, scale: 1, backing: 1)))
        }
        let canvas = try RasterCanvas(width: 96, height: 48)
        cx.draw(canvas, in: CanvasRect(x: 0, y: 0, width: 96, height: 48), time: time, elements: [], context: FrameDrawContext())
        return canvas.image().rgba
    }

    func testA4PreviewCompositorAndExportAgreeWithinOneLevelForEveryKindAtThreeTimes() throws {
        let engine = try KeyframeRuntime()
        let doc = try document(engine: engine)
        let output = "\(Self.root)/moves.mov"
        try? FileManager.default.removeItem(atPath: output)
        var input = NativeTimelineRenderInput(project: doc, projectDir: Self.root, outputPath: output, format: .mov, quality: .high)
        input.keyframeEngine = engine
        try renderNativeTimeline(input)
        let file = Exported(path: output)
        let dir = URL(fileURLWithPath: Self.root)
        let moving = PreviewComposition(document: doc, projectDir: dir, engine: engine)
        let unmoved = PreviewComposition(document: try unmovedDocument(engine), projectDir: dir, engine: engine)
        var worst: [String: Int] = [:]
        var moved = 0
        for (i, kind) in Self.kinds.enumerated() {
            for f in kind.1 {
                let time = Double(i * 20 + f) / 10
                let exported = try file.rgba(time), preview = try compositorFrame(moving, at: time)
                XCTAssertEqual(exported.rgba.count, preview.count)
                worst["\(kind.0) @\(f)"] = rgbMaxDiff(exported.rgba, preview)
                if rgbMaxDiff(preview, try compositorFrame(unmoved, at: time)) > 8 { moved += 1 }
            }
        }
        XCTAssertEqual(worst.filter { $0.value > 1 }, [:], "max RGB difference per frame")
        XCTAssertEqual(moved, Self.kinds.count * 3, "every checked frame shows the move (differs from the unmoved layer)")
    }

    /// The same document with every clip's moves removed: what the moves change.
    func unmovedDocument(_ engine: KeyframeEngine) throws -> NativeProjectDocument {
        var d = try document(engine: engine)
        for i in d.sequence.tracks[0].clips.indices { d.sequence.tracks[0].clips[i].moves = nil }
        return d
    }

    func rgbMaxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return .max }
        var m = 0
        for i in stride(from: 0, to: a.count, by: 4) { for c in 0..<3 { m = max(m, abs(Int(a[i + c]) - Int(b[i + c]))) } }
        return m
    }
}
