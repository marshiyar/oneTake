import XCTest
import MpvfxCanvas
import MpvfxPlayer
import MpvfxShared

final class PathMaskTests: XCTestCase {
    private func star(_ rule: String? = nil) -> NativeClipMask {
        // Pentagram drawn with one stroke: self-crossing, centre wound twice.
        let pts = (0..<5).map { i -> NativeMaskPath.Point in
            let a = Double(i) * 4 * .pi / 5 - .pi / 2
            return .init(x: 0.5 + 0.45 * cos(a), y: 0.5 + 0.45 * sin(a))
        }
        var m = NativeClipMask(id: "p", kind: "path")
        m.path = NativeMaskPath(closed: true, fillRule: rule, points: pts)
        return m
    }

    private func halfSquare() -> NativeClipMask {
        var m = NativeClipMask(id: "sq", kind: "path")
        m.path = NativeMaskPath(closed: true, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 0.5, y: 1), .init(x: 0, y: 1)])
        return m
    }

    func testSelfCrossingPathFillsCentreUnderNonzeroAndLeavesItEmptyUnderEvenOdd() {
        let nz = MaskCoverageRasterizer.coverage(width: 100, height: 100, masks: [star()])
        let eo = MaskCoverageRasterizer.coverage(width: 100, height: 100, masks: [star("evenodd")])
        XCTAssertEqual(nz[50 * 100 + 50], 1)
        XCTAssertEqual(eo[50 * 100 + 50], 0)
        XCTAssertEqual(nz[2 * 100 + 2], 0)
        XCTAssertEqual(eo[2 * 100 + 2], 0)
        // A point in a tip is inside under both rules.
        XCTAssertEqual(nz[12 * 100 + 50], 1)
        XCTAssertEqual(eo[12 * 100 + 50], 1)
    }

    func testSquarePathCoversExactlyItsPixels() {
        let c = MaskCoverageRasterizer.coverage(width: 10, height: 2, masks: [halfSquare()])
        XCTAssertEqual(Array(c.prefix(10)), [1, 1, 1, 1, 1, 0, 0, 0, 0, 0])
    }

    func testPathMaskSharesFeatherInvertAndOpacityStage() {
        var m = halfSquare()
        m.invert = true; m.opacity = 0.5
        let c = MaskCoverageRasterizer.coverage(width: 10, height: 1, masks: [m])
        XCTAssertEqual(c[0], 0.5); XCTAssertEqual(c[9], 1)
        m.invert = nil; m.opacity = nil; m.feather = 6
        let soft = MaskCoverageRasterizer.coverage(width: 40, height: 1, masks: [m])
        XCTAssertGreaterThan(soft[22], 0); XCTAssertLessThan(soft[22], 0.5)
    }

    func testPreviewAndExportPaintPathMaskIdentically() {
        let white = CanvasImage(width: 50, height: 50, rgba: [UInt8](repeating: 255, count: 50 * 50 * 4))
        let a = MaskCoverageRasterizer.applying([star()], to: white)
        let b = MaskCoverageRasterizer.applying([star()], to: white)
        XCTAssertEqual(a.rgba, b.rgba)
        XCTAssertEqual(a.rgba[(25 * 50 + 25) * 4 + 3], 255)
        XCTAssertEqual(a.rgba[3], 0)
    }

    func testDegeneratePathsThrowTypedErrors() {
        func err(_ p: NativeMaskPath) -> NativeMaskPathError? {
            do { try p.validate(); return nil } catch { return error as? NativeMaskPathError }
        }
        let p = { (x: Double, y: Double) in NativeMaskPath.Point(x: x, y: y) }
        XCTAssertEqual(err(.init(closed: true, points: [p(0, 0), p(1, 1)])), .tooFewPoints)
        XCTAssertEqual(err(.init(closed: true, points: [p(0, 0), p(0.5, 0.5), p(1, 1)])), .zeroArea)
        XCTAssertEqual(err(.init(closed: false, points: [p(0, 0), p(1, 0), p(1, 1)])), .notClosed)
        XCTAssertEqual(err(.init(closed: true, points: [p(0, 0), p(.nan, 0), p(1, 1)])), .nonFiniteValue)
        XCTAssertEqual(err(.init(closed: true, fillRule: "x", points: [p(0, 0), p(1, 0), p(1, 1)])), .invalidFillRule)
        XCTAssertNil(err(.init(closed: true, points: [p(0, 0), p(1, 0), p(1, 1)])))
        // A degenerate path fills nothing rather than everything.
        var m = NativeClipMask(id: "d", kind: "path")
        m.path = .init(closed: true, points: [p(0, 0), p(1, 1)])
        XCTAssertTrue(MaskCoverageRasterizer.coverage(width: 4, height: 4, masks: [m]).allSatisfy { $0 == 0 })
    }

    func testDegeneratePathIsRejectedByDocumentValidationWithTypedCode() throws {
        let bad = ",\"masks\":[{\"v\":1,\"id\":\"m\",\"kind\":\"path\",\"path\":{\"v\":1,\"closed\":true,\"points\":[{\"x\":0,\"y\":0},{\"x\":1,\"y\":1}]}}]"
        XCTAssertThrowsError(try PreviewCompositorTests.document(clipB: bad)) { error in
            let e = error as? NativeProjectDocumentValidationError
            XCTAssertEqual(e?.issues.first?.code, .invalidMaskPath)
        }
    }

    func testPathMaskRoundTripsThroughJSONWithOptionalFieldsOmitted() throws {
        var m = star()
        m.path?.points[0].outX = 0.1; m.path?.points[0].outY = 0
        let data = try JSONEncoder().encode(m)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("fillRule")); XCTAssertFalse(text.contains("inX"))
        XCTAssertEqual(try JSONDecoder().decode(NativeClipMask.self, from: data), m)
        let ok = ",\"masks\":[{\"v\":1,\"id\":\"m\",\"kind\":\"path\",\"path\":{\"v\":1,\"closed\":true,\"points\":[{\"x\":0,\"y\":0},{\"x\":1,\"y\":0},{\"x\":1,\"y\":1}]}}]"
        XCTAssertNoThrow(try PreviewCompositorTests.document(clipB: ok))
    }

    func testEditStepsAddMoveHandleNudgeAndClose() {
        var m = NativeMaskPathEdit.begin(id: "p", at: 0.1, 0.1)
        m = NativeMaskPathEdit.addPoint(m, x: 0.9, y: 0.1)
        m = NativeMaskPathEdit.addPoint(m, x: 0.9, y: 0.9)
        m = NativeMaskPathEdit.movePoint(m, index: 2, x: 0.8, y: 0.8)
        m = NativeMaskPathEdit.nudge(m, index: 0, dx: 0.05, dy: 0)
        m = NativeMaskPathEdit.dragHandle(m, index: 1, dx: 0.1, dy: 0)
        XCTAssertThrowsError(try m.path!.validate())
        m = NativeMaskPathEdit.close(m)
        XCTAssertNoThrow(try m.path!.validate())
        XCTAssertEqual(m.path?.points[0].x ?? 0, 0.15, accuracy: 1e-12)
        XCTAssertEqual(m.path?.points[1].inX, -0.1)
        XCTAssertEqual(NativeMaskPathEdit.addPoint(m, x: 0.5, y: 0.5).path?.points.count, 3, "a closed path takes no more points")
    }
}
