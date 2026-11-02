// Issue #307: camera moves move the layer in preview and export, over keyframes and Layer moves, covering their own edges.
import XCTest
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes

final class PreviewCameraMovesTests: XCTestCase {
    static let w = 640, h = 360

    /// A 640x360 image clip of 90 frames at 30 fps with `effects` (a JSON array) and optional extra clip JSON.
    static func document(effects: String, extra: String = "") throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse("""
        {"schemaVersion":1,"id":"project:cam","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":\(w),"height":\(h),"background":"#00000000"},
         "assets":[{"id":"i","kind":"image","name":"i.png","source":"i.png","durationFrames":1}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"v","kind":"video","clips":[
           {"id":"A","assetId":"i","startFrame":0,"durationFrames":90,"sourceInFrame":0,"effects":\(effects),"parameterTracks":[]\(extra)}]}]}}
        """), engine: try KeyframeRuntime())
    }

    static func camera(_ parameters: String) -> String { #"[{"id":"fx","effectId":"camera-moves","enabled":true,"parameters":\#(parameters)}]"# }

    func composition(_ d: NativeProjectDocument) throws -> PreviewComposition {
        PreviewComposition(document: d, projectDir: URL(fileURLWithPath: "/project"), engine: try KeyframeRuntime(), fileExists: { _ in true })
    }

    func layer(_ c: PreviewComposition, frame: Int) throws -> PreviewLayer { try XCTUnwrap(c.layers(at: Double(frame) / 30).first) }

    func picture() -> CanvasImage {
        // Left half red, right half blue, so a shift or a scale shows in the pixels.
        var rgba = [UInt8]()
        for _ in 0..<Self.h { for x in 0..<Self.w { rgba += x < Self.w / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] } }
        return CanvasImage(width: Self.w, height: Self.h, rgba: rgba)
    }

    // MARK: Moves in the layer

    func testPunchInSnapsToItsScaleAndEasesBackToOneAndPushGrowsOverTheClip() throws {
        let linear = #""ease":{"type":"linear"}"#
        let c = try composition(Self.document(effects: Self.camera(
            #"{"v":1,"punch":{"v":1,"scale":1.4,"lengthFrames":10,\#(linear),"at":[20]},"push":{"v":1,"startScale":1,"endScale":1.2,\#(linear)}}"#)))
        let push = { (f: Int) in 1 + 0.2 * Double(f) / 89 }
        XCTAssertEqual(try layer(c, frame: 0).scaleX, 1, accuracy: 1e-9, "no punch before its time; the push starts at 1")
        XCTAssertEqual(try layer(c, frame: 20).scaleX, 1.4 * push(20), accuracy: 1e-9, "the punch lands at once")
        XCTAssertEqual(try layer(c, frame: 25).scaleX, 1.2 * push(25), accuracy: 1e-9, "halfway back")
        XCTAssertEqual(try layer(c, frame: 30).scaleX, push(30), accuracy: 1e-9, "settled")
        XCTAssertEqual(try layer(c, frame: 89).scaleX, 1.2, accuracy: 1e-9)
    }

    func testEveryNFramesPunchesRepeat() throws {
        let c = try composition(Self.document(effects: Self.camera(#"{"v":1,"punch":{"v":1,"scale":1.5,"lengthFrames":4,"ease":{"type":"linear"},"everyFrames":30}}"#)))
        for f in [0, 30, 60] { XCTAssertEqual(try layer(c, frame: f).scaleX, 1.5, accuracy: 1e-9, "frame \(f)") }
        XCTAssertEqual(try layer(c, frame: 15).scaleX, 1, accuracy: 1e-9)
    }

    func testCameraMovesGoOverTheLayersOwnMoves() throws {
        let moves = #","moves":{"v":1,"in":{"kind":"slide","frames":10,"direction":"left","ease":{"type":"linear"}}}"#
        let both = try composition(Self.document(effects: Self.camera(#"{"v":1,"allowEdges":true,"push":{"v":1,"startScale":1.2,"endScale":1.2,"drift":10,"direction":"down"}}"#), extra: moves))
        let slide = try composition(Self.document(effects: "[]", extra: moves))
        let a = try layer(both, frame: 3), b = try layer(slide, frame: 3)
        XCTAssertEqual(a.box.x, b.box.x, accuracy: 1e-9, "the slide is still there")
        XCTAssertEqual(a.scaleX, b.scaleX * 1.2, accuracy: 1e-9)
        XCTAssertEqual(a.box.y, b.box.y + 0.1 * Double(Self.h) * 3 / 89, accuracy: 1e-9, "drift down")
    }

    func testADisabledOrNewerCameraMoveDrawsNothing() throws {
        let plain = try layer(try composition(Self.document(effects: "[]")), frame: 7)
        let off = #"[{"id":"fx","effectId":"camera-moves","enabled":false,"parameters":{"v":1,"shake":{"v":1,"amount":30}}}]"#
        let newer = #"[{"id":"fx","effectId":"camera-moves","enabled":true,"parameters":{"v":2,"shake":{"v":1,"amount":30}}}]"#
        XCTAssertEqual(try layer(try composition(Self.document(effects: off)), frame: 7), plain)
        XCTAssertEqual(try layer(try composition(Self.document(effects: newer)), frame: 7), plain)
        let still = Self.camera(#"{"v":1,"shake":{"v":1,"amount":0}}"#)
        XCTAssertEqual(try layer(try composition(Self.document(effects: still)), frame: 7), plain, "amount 0 is exactly no motion")
    }

    // MARK: A4 auto-cover

    func paintedFrames(_ d: NativeProjectDocument, frames: [Int]) throws -> [CanvasImage] {
        let painter = try ExportFramePainter(composition: composition(d), width: Self.w, height: Self.h, pad: .transparent)
        let image = picture()
        return try frames.map { f in try painter.paint(time: Double(f) / 30) { _, _, _, _ in image } }
    }

    func edgeAlphaMin(_ img: CanvasImage) -> UInt8 {
        var m: UInt8 = 255
        for x in 0..<img.width { m = min(m, img.rgba[x * 4 + 3], img.rgba[((img.height - 1) * img.width + x) * 4 + 3]) }
        for y in 0..<img.height { m = min(m, img.rgba[y * img.width * 4 + 3], img.rgba[(y * img.width + img.width - 1) * 4 + 3]) }
        return m
    }

    func testA4NoTransparentEdgePixelAtAnyFrameWithAmountFortyPx() throws {
        let shake = #""shake":{"v":1,"amount":40,"frequency":4,"rotation":3,"seed":5}"#
        let covered = try Self.document(effects: Self.camera(#"{"v":1,\#(shake)}"#))
        for (i, img) in try paintedFrames(covered, frames: Array(0..<90)).enumerated() {
            XCTAssertEqual(edgeAlphaMin(img), 255, "frame \(i) has a transparent edge pixel")
        }
        let open = try Self.document(effects: Self.camera(#"{"v":1,"allowEdges":true,\#(shake)}"#))
        let seen = try paintedFrames(open, frames: Array(0..<90)).contains { edgeAlphaMin($0) < 255 }
        XCTAssertTrue(seen, "with Allow edges the same shake does show the edge (the test can fail)")
    }

    // MARK: A5 preview = export

    func testA5PreviewAndExportAgreeWithinOneLevel() throws {
        let d = try Self.document(effects: Self.camera(
            #"{"v":1,"shake":{"v":1,"amount":25,"frequency":3,"rotation":2,"seed":9},"punch":{"v":1,"scale":1.3,"lengthFrames":6,"at":[10]},"push":{"v":1,"endScale":1.15,"drift":3}}"#))
        let comp = try composition(d)
        let export = try ExportFramePainter(composition: comp, width: Self.w, height: Self.h, pad: .transparent)
        let image = picture()
        for f in [0, 10, 12, 33, 60, 89] {
            let t = Double(f) / 30
            let exported = try export.paint(time: t) { _, _, _, _ in image }
            // The preview path: the composition's layers drawn by PreviewPainter on the stage canvas.
            let stage = try RasterCanvas(width: Self.w, height: Self.h)
            stage.clear(.transparent)
            let frame = CanvasRect(x: 0, y: 0, width: Double(Self.w), height: Double(Self.h))
            for l in comp.layers(at: t) where l.isVisible { PreviewPainter.draw(l, image: image, on: stage, frame: frame, scale: 1) }
            let shown = stage.image()
            XCTAssertEqual(shown.rgba.count, exported.rgba.count)
            let worst = zip(shown.rgba, exported.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1, "frame \(f): preview and export differ by \(worst) levels")
        }
        let plain = try ExportFramePainter(composition: composition(Self.document(effects: "[]")), width: Self.w, height: Self.h, pad: .transparent)
        let still = try plain.paint(time: 10.0 / 30) { _, _, _, _ in image }
        let moved = try export.paint(time: 10.0 / 30) { _, _, _, _ in image }
        XCTAssertNotEqual(still.rgba, moved.rgba, "the exported frame is moved")
    }
}
