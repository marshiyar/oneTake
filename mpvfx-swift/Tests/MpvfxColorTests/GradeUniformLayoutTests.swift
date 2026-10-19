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
@testable import MpvfxColor
import CMpvfxColorShared

/// The uniform layout the Metal kernels read (MpvfxColorShared.h) matches the Swift side that packs it.
final class GradeUniformLayoutTests: XCTestCase {
    func testEffectIndicesMatchTheSharedHeader() {
        XCTAssertEqual(Int(EK_COUNT.rawValue), EK.allCases.count)
        XCTAssertEqual(Int(EK_blur.rawValue), EK.blur.rawValue, "blur")
        XCTAssertEqual(Int(EK_pixelate.rawValue), EK.pixelate.rawValue, "pixelate")
        XCTAssertEqual(Int(EK_chromaBleed.rawValue), EK.chromaBleed.rawValue, "chromaBleed")
        XCTAssertEqual(Int(EK_tapeDamage.rawValue), EK.tapeDamage.rawValue, "tapeDamage")
        XCTAssertEqual(Int(EK_tapeTracking.rawValue), EK.tapeTracking.rawValue, "tapeTracking")
        XCTAssertEqual(Int(EK_tapeNoise.rawValue), EK.tapeNoise.rawValue, "tapeNoise")
        XCTAssertEqual(Int(EK_tapeSpeed.rawValue), EK.tapeSpeed.rawValue, "tapeSpeed")
        XCTAssertEqual(Int(EK_filmArtifacts.rawValue), EK.filmArtifacts.rawValue, "filmArtifacts")
        XCTAssertEqual(Int(EK_halftone.rawValue), EK.halftone.rawValue, "halftone")
        XCTAssertEqual(Int(EK_halftoneSize.rawValue), EK.halftoneSize.rawValue, "halftoneSize")
        XCTAssertEqual(Int(EK_twoInkPrint.rawValue), EK.twoInkPrint.rawValue, "twoInkPrint")
        XCTAssertEqual(Int(EK_twoInkPrintSize.rawValue), EK.twoInkPrintSize.rawValue, "twoInkPrintSize")
        XCTAssertEqual(Int(EK_ascii.rawValue), EK.ascii.rawValue, "ascii")
        XCTAssertEqual(Int(EK_asciiSize.rawValue), EK.asciiSize.rawValue, "asciiSize")
        XCTAssertEqual(Int(EK_asciiInvert.rawValue), EK.asciiInvert.rawValue, "asciiInvert")
        XCTAssertEqual(Int(EK_asciiStyle.rawValue), EK.asciiStyle.rawValue, "asciiStyle")
        XCTAssertEqual(Int(EK_asciiColor.rawValue), EK.asciiColor.rawValue, "asciiColor")
        XCTAssertEqual(Int(EK_asciiRotation.rawValue), EK.asciiRotation.rawValue, "asciiRotation")
        XCTAssertEqual(Int(EK_dither.rawValue), EK.dither.rawValue, "dither")
        XCTAssertEqual(Int(EK_ditherSize.rawValue), EK.ditherSize.rawValue, "ditherSize")
        XCTAssertEqual(Int(EK_bloom.rawValue), EK.bloom.rawValue, "bloom")
        XCTAssertEqual(Int(EK_bloomRadius.rawValue), EK.bloomRadius.rawValue, "bloomRadius")
        XCTAssertEqual(Int(EK_monoScreen.rawValue), EK.monoScreen.rawValue, "monoScreen")
        XCTAssertEqual(Int(EK_monoScreenSize.rawValue), EK.monoScreenSize.rawValue, "monoScreenSize")
        XCTAssertEqual(Int(EK_monoScreenAngle.rawValue), EK.monoScreenAngle.rawValue, "monoScreenAngle")
        XCTAssertEqual(Int(EK_monoScreenSpread.rawValue), EK.monoScreenSpread.rawValue, "monoScreenSpread")
        XCTAssertEqual(Int(EK_monoScreenShape.rawValue), EK.monoScreenShape.rawValue, "monoScreenShape")
        XCTAssertEqual(Int(EK_monoScreenInvert.rawValue), EK.monoScreenInvert.rawValue, "monoScreenInvert")
        XCTAssertEqual(Int(EK_scanlines.rawValue), EK.scanlines.rawValue, "scanlines")
        XCTAssertEqual(Int(EK_scanlineCount.rawValue), EK.scanlineCount.rawValue, "scanlineCount")
        XCTAssertEqual(Int(EK_scanlineSoftness.rawValue), EK.scanlineSoftness.rawValue, "scanlineSoftness")
        XCTAssertEqual(Int(EK_chromaticAberration.rawValue), EK.chromaticAberration.rawValue, "chromaticAberration")
        XCTAssertEqual(Int(EK_chromaticAngle.rawValue), EK.chromaticAngle.rawValue, "chromaticAngle")
        XCTAssertEqual(Int(EK_crtCurvature.rawValue), EK.crtCurvature.rawValue, "crtCurvature")
        XCTAssertEqual(Int(EK_digitalGlitch.rawValue), EK.digitalGlitch.rawValue, "digitalGlitch")
        XCTAssertEqual(Int(EK_digitalGlitchColorSplit.rawValue), EK.digitalGlitchColorSplit.rawValue, "digitalGlitchColorSplit")
        XCTAssertEqual(Int(EK_digitalGlitchLineTear.rawValue), EK.digitalGlitchLineTear.rawValue, "digitalGlitchLineTear")
        XCTAssertEqual(Int(EK_digitalGlitchPixelate.rawValue), EK.digitalGlitchPixelate.rawValue, "digitalGlitchPixelate")
        XCTAssertEqual(Int(EK_digitalGlitchBlockAmount.rawValue), EK.digitalGlitchBlockAmount.rawValue, "digitalGlitchBlockAmount")
        XCTAssertEqual(Int(EK_digitalGlitchBlockDisplacement.rawValue), EK.digitalGlitchBlockDisplacement.rawValue, "digitalGlitchBlockDisplacement")
        XCTAssertEqual(Int(EK_digitalGlitchBlockOpacity.rawValue), EK.digitalGlitchBlockOpacity.rawValue, "digitalGlitchBlockOpacity")
        XCTAssertEqual(Int(EK_digitalGlitchSpeed.rawValue), EK.digitalGlitchSpeed.rawValue, "digitalGlitchSpeed")
        XCTAssertEqual(Int(EK_engraving.rawValue), EK.engraving.rawValue, "engraving")
        XCTAssertEqual(Int(EK_engravingSpacing.rawValue), EK.engravingSpacing.rawValue, "engravingSpacing")
        XCTAssertEqual(Int(EK_engravingMinThickness.rawValue), EK.engravingMinThickness.rawValue, "engravingMinThickness")
        XCTAssertEqual(Int(EK_engravingMaxThickness.rawValue), EK.engravingMaxThickness.rawValue, "engravingMaxThickness")
        XCTAssertEqual(Int(EK_engravingAngle.rawValue), EK.engravingAngle.rawValue, "engravingAngle")
        XCTAssertEqual(Int(EK_engravingContrast.rawValue), EK.engravingContrast.rawValue, "engravingContrast")
        XCTAssertEqual(Int(EK_engravingSharpness.rawValue), EK.engravingSharpness.rawValue, "engravingSharpness")
        XCTAssertEqual(Int(EK_engravingWave.rawValue), EK.engravingWave.rawValue, "engravingWave")
        XCTAssertEqual(Int(EK_engravingWaveFrequency.rawValue), EK.engravingWaveFrequency.rawValue, "engravingWaveFrequency")
        XCTAssertEqual(Int(EK_crosshatch.rawValue), EK.crosshatch.rawValue, "crosshatch")
        XCTAssertEqual(Int(EK_crosshatchSpacing.rawValue), EK.crosshatchSpacing.rawValue, "crosshatchSpacing")
        XCTAssertEqual(Int(EK_crosshatchThickness.rawValue), EK.crosshatchThickness.rawValue, "crosshatchThickness")
        XCTAssertEqual(Int(EK_crosshatchAngle.rawValue), EK.crosshatchAngle.rawValue, "crosshatchAngle")
        XCTAssertEqual(Int(EK_crosshatchContrast.rawValue), EK.crosshatchContrast.rawValue, "crosshatchContrast")
        XCTAssertEqual(Int(EK_crosshatchEdges.rawValue), EK.crosshatchEdges.rawValue, "crosshatchEdges")
        XCTAssertEqual(Int(EK_crosshatchLineWeight.rawValue), EK.crosshatchLineWeight.rawValue, "crosshatchLineWeight")
        XCTAssertEqual(Int(EK_crosshatchWave.rawValue), EK.crosshatchWave.rawValue, "crosshatchWave")
        XCTAssertEqual(Int(EK_crosshatchWaveFrequency.rawValue), EK.crosshatchWaveFrequency.rawValue, "crosshatchWaveFrequency")
        XCTAssertEqual(Int(EK_kuwahara.rawValue), EK.kuwahara.rawValue, "kuwahara")
        XCTAssertEqual(Int(EK_kuwaharaRadius.rawValue), EK.kuwaharaRadius.rawValue, "kuwaharaRadius")
        XCTAssertEqual(Int(EK_kuwaharaSharpness.rawValue), EK.kuwaharaSharpness.rawValue, "kuwaharaSharpness")
        XCTAssertEqual(Int(EK_kuwaharaSaturation.rawValue), EK.kuwaharaSaturation.rawValue, "kuwaharaSaturation")
    }

    func testPackedFrameUsesTheHeaderLayout() {
        let r = ColorGradeRenderer(params: GradeReferenceCases.params(#"{"adjust":{"exposure":0.5},"effects":{"kuwahara":0.7,"bloom":1.5},"details":{"grain":0.3}}"#), seedKey: "clip:x")
        let f = r.gpuFrame(width: 320, height: 181, time: 1.5)
        XCTAssertEqual(f.uniforms.count, Int(GU_COUNT.rawValue) + Int(EK_COUNT.rawValue))
        XCTAssertEqual(f.uniforms[Int(GU_resX.rawValue)], 320); XCTAssertEqual(f.uniforms[Int(GU_resY.rawValue)], 181)
        XCTAssertEqual(f.uniforms[Int(GU_exposure.rawValue)], 0.5)
        XCTAssertEqual(f.uniforms[Int(GU_effectTime.rawValue)], 1.5)
        XCTAssertEqual(f.uniforms[Int(GU_COUNT.rawValue) + Int(EK_kuwahara.rawValue)], 0.7, accuracy: 1e-6)
        XCTAssertEqual(f.uniforms[Int(GU_kuwaharaOn.rawValue)], 1); XCTAssertEqual(f.uniforms[Int(GU_bloomOn.rawValue)], 1)
        XCTAssertEqual(f.uniforms[Int(GU_blurOn.rawValue)], 0)
        XCTAssertEqual(f.bloomWidth, 160); XCTAssertEqual(f.bloomHeight, 91)
        XCTAssertGreaterThan(f.kuwaharaRadius, 0)
    }
}
