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
@testable import MpvfxScopes

/// The constants and graticule references equal the published values (`docs/SCOPES.md` section "Sources").
final class ScopeStandardTests: XCTestCase {
    func testDivisorsMatchThePublishedRecommendations() {
        // BT.709-6 item 3.3, BT.601-7 § 2.5.2, BT.2020-2 Table 4.
        let published: [ScopeMatrix: (Double, Double, Double)] = [
            .rec709: (0.7152, 1.8556, 1.5748), .rec601: (0.587, 1.772, 1.402), .rec2020: (0.678, 1.8814, 1.4746),
        ]
        for (m, p) in published {
            XCTAssertEqual(m.kg, p.0, accuracy: 1e-12, "\(m)")
            XCTAssertEqual(m.cbDivisor, p.1, accuracy: 1e-12, "\(m)")
            XCTAssertEqual(m.crDivisor, p.2, accuracy: 1e-12, "\(m)")
            let w = m.decimalWeights
            XCTAssertEqual(w.r + w.g + w.b, 10000, "\(m): the published weights, exactly; greys stay exact")
        }
    }

    func testBT709BarTargetsMatchTheMatrix() {
        let full = ScopeTargets.bars(.rec709, amplitude: 1)
        let expected: [String: (Double, Double)] = [
            "R": (-0.1146, 0.5), "Yl": (-0.5, 0.0458), "G": (-0.3854, -0.4542),
            "Cy": (0.1146, -0.5), "B": (0.5, -0.0458), "Mg": (0.3854, 0.4542),
        ]
        XCTAssertEqual(full.map(\.name), ["R", "Mg", "B", "Cy", "G", "Yl"])
        for t in full {
            let e = expected[t.name] ?? (.nan, .nan)
            XCTAssertEqual(t.cb, e.0, accuracy: 5e-5, t.name)
            XCTAssertEqual(t.cr, e.1, accuracy: 5e-5, t.name)
        }
        for (t75, t100) in zip(ScopeTargets.bars(.rec709, amplitude: 0.75), full) {
            XCTAssertEqual(t75.cb, 0.75 * t100.cb, accuracy: 1e-12, "75 % bars sit at 3/4 of the 100 % distance")
            XCTAssertEqual(t75.cr, 0.75 * t100.cr, accuracy: 1e-12)
        }
    }

    func testSkinToneLineIsTheNTSCIAxisInTheCbCrPlane() {
        XCTAssertEqual(ScopeTargets.skinToneAngle(.rec709) * 180 / .pi, 134.82, accuracy: 0.01)
        XCTAssertEqual(ScopeTargets.skinToneAngle(.rec601) * 180 / .pi, 132.81, accuracy: 0.01)
        // In U/V (U = 0.493 (B'-Y'), V = 0.877 (R'-Y'), BT.470-6 § 2.5) the same axis is the 123 degrees of BT.470-6
        // Fig. 4 (33 degrees from V). The equations give I and Q to two decimals, which moves it to 123.35 degrees;
        // 0.5 degree covers that rounding and nothing more.
        let uv = atan2(0.877, 0.493 * -0.48 / 0.41) * 180 / .pi
        XCTAssertEqual(uv, 123, accuracy: 0.5)
    }

    func testTenBitScalePutsBlackAt64AndNominalPeakAt940() {
        XCTAssertEqual(ScopeScale.code10(0), 64)
        XCTAssertEqual(ScopeScale.code10(1), 940)
        XCTAssertEqual(ScopeScale.code10(0.5), 502)
        XCTAssertEqual(ScopeScale.code10(-3), 64, "clamped")
        let lines = ScopeScale.code10.lines
        XCTAssertEqual(lines.first?.value, 0)
        XCTAssertEqual(lines.last?.value, 1)
        XCTAssertEqual(lines.compactMap(\.label), ["64", "256", "512", "768", "940"])
        XCTAssertEqual(lines.filter(\.major).count, 2)
    }

    func testPercentScaleHasALineEveryTenPercent() {
        let lines = ScopeScale.percent.lines
        XCTAssertEqual(lines.count, 11)
        XCTAssertEqual(lines.compactMap(\.label), ["0", "20", "40", "60", "80", "100"])
        XCTAssertEqual(ScopeScale.percent.text(for: 0.5), "50.0")
        XCTAssertEqual(ScopeScale.code10.text(for: 1), "940")
    }

    func testBT709TransferFunctionPlacesMiddleGreyAt41Percent() {
        XCTAssertEqual(ScopeTargets.bt709OETF(0.18), 0.4090, accuracy: 5e-5)
        XCTAssertEqual(ScopeTargets.bt709OETF(0.01), 0.045, accuracy: 1e-12, "linear segment below 0.018")
        XCTAssertEqual(ScopeTargets.bt709OETF(1), 1, accuracy: 1e-12)
    }

    func testFalseColourBands() throws {
        XCTAssertEqual(FalseColor.band(forLuma: 0)?.name, "Crushed")
        XCTAssertEqual(FalseColor.band(forLuma: 0.05)?.name, "Near black")
        XCTAssertEqual(FalseColor.band(forLuma: ScopeTargets.bt709OETF(0.18))?.name, "Middle grey")
        XCTAssertEqual(FalseColor.band(forLuma: ScopeTargets.bt709OETF(0.36))?.name, "Skin")
        XCTAssertEqual(FalseColor.band(forLuma: 0.95)?.name, "Near clip")
        XCTAssertEqual(FalseColor.band(forLuma: 1)?.name, "Clipped")
        XCTAssertNil(FalseColor.band(forLuma: 0.5), "between bands: grey")
        let bands = FalseColor.bands
        for (a, b) in zip(bands, bands.dropFirst()) { XCTAssertLessThanOrEqual(a.upper, b.lower, "bands do not overlap") }
    }

    func testFalseColourMapPaintsBandsAndKeepsGreyAndAlpha() throws {
        let f = try ScopeFixtures.frame(4, 1) { x, _ in
            [(0, 0, 0, 255), (255, 255, 255, 255), (128, 128, 128, 90), (104, 104, 104, 255)][x]
        }
        let out = FalseColor.map(f)
        XCTAssertEqual(Array(out[0..<4]), [128, 0, 160, 255], "black: crushed")
        XCTAssertEqual(Array(out[4..<8]), [255, 0, 0, 255], "white: clipped")
        XCTAssertEqual(Array(out[8..<12]), [128, 128, 128, 90], "mid level: its own grey, alpha kept")
        XCTAssertEqual(Array(out[12..<16]), [0, 200, 70, 255], "104/255 = 40.8 %: middle grey")
    }

    func testMatrixFromColourSpaceNames() {
        XCTAssertEqual(ScopeMatrix(colorSpace: "rec709"), .rec709)
        XCTAssertEqual(ScopeMatrix(colorSpace: "BT.709"), .rec709)
        XCTAssertEqual(ScopeMatrix(colorSpace: "smpte170m"), .rec601)
        XCTAssertEqual(ScopeMatrix(colorSpace: "bt2020nc"), .rec2020)
        XCTAssertNil(ScopeMatrix(colorSpace: "display-p3"))
    }
}
