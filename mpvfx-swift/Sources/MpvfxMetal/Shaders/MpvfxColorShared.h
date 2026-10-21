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
// Shared by the Metal grading kernels (MpvfxColor.metal) and the Swift side (imported through CMpvfxColorShared):
// the layout of the flat uniform array the grade kernel reads. Plain C, so MSL (C++14) and clang both read it.
//
// u[GU_x]               grade uniforms (resolution, primary, finish, wheels, table/LUT flags, palette, pass flags)
// u[GU_COUNT + EK_x]    stylize effect settings, in MpvfxColor's EK order (MpvfxColorTests checks the two match)
#ifndef MPVFX_COLOR_SHARED_H
#define MPVFX_COLOR_SHARED_H

enum MpvfxGU {
    GU_resX = 0, GU_resY, GU_exposure, GU_contrast, GU_highlights, GU_shadows,
    GU_whites, GU_blacks, GU_temperature, GU_tint, GU_vibrance, GU_saturation,
    GU_vignette, GU_vignetteMidpoint, GU_vignetteRoundness, GU_vignetteFeather, GU_grain, GU_grainSize,
    GU_grainRoughness, GU_grainSeed, GU_effectTime, GU_shadowHue, GU_shadowAmount, GU_shadowLevel,
    GU_midHue, GU_midAmount, GU_midLevel, GU_highHue, GU_highAmount, GU_highLevel,
    GU_rgbCurves, GU_hueCurves, GU_secondaryCount, GU_lutEnabled, GU_lutIntensity, GU_lutSize,
    GU_lutTetra, GU_lutMinR, GU_lutMinG, GU_lutMinB, GU_lutMaxR, GU_lutMaxG,
    GU_lutMaxB, GU_intensity, GU_paletteSize, GU_p0r, GU_p0g, GU_p0b,
    GU_p1r, GU_p1g, GU_p1b, GU_p2r, GU_p2g, GU_p2b,
    GU_p3r, GU_p3g, GU_p3b, GU_p4r, GU_p4g, GU_p4b,
    GU_p5r, GU_p5g, GU_p5b, GU_blurOn, GU_bloomOn, GU_kuwaharaOn,
    GU_whiteBalanceGains, GU_pivot, GU_balanceOn,
    GU_liftHue, GU_liftAmount, GU_liftLevel, GU_gammaHue, GU_gammaAmount, GU_gammaLevel,
    GU_gainHue, GU_gainAmount, GU_gainLevel, GU_offsetHue, GU_offsetAmount, GU_offsetLevel,
    GU_COUNT
};

enum MpvfxEK {
    EK_blur = 0, EK_pixelate, EK_chromaBleed, EK_tapeDamage, EK_tapeTracking, EK_tapeNoise,
    EK_tapeSpeed, EK_filmArtifacts, EK_halftone, EK_halftoneSize, EK_twoInkPrint, EK_twoInkPrintSize,
    EK_ascii, EK_asciiSize, EK_asciiInvert, EK_asciiStyle, EK_asciiColor, EK_asciiRotation,
    EK_dither, EK_ditherSize, EK_bloom, EK_bloomRadius, EK_monoScreen, EK_monoScreenSize,
    EK_monoScreenAngle, EK_monoScreenSpread, EK_monoScreenShape, EK_monoScreenInvert, EK_scanlines, EK_scanlineCount,
    EK_scanlineSoftness, EK_chromaticAberration, EK_chromaticAngle, EK_crtCurvature, EK_digitalGlitch, EK_digitalGlitchColorSplit,
    EK_digitalGlitchLineTear, EK_digitalGlitchPixelate, EK_digitalGlitchBlockAmount, EK_digitalGlitchBlockDisplacement, EK_digitalGlitchBlockOpacity, EK_digitalGlitchSpeed,
    EK_engraving, EK_engravingSpacing, EK_engravingMinThickness, EK_engravingMaxThickness, EK_engravingAngle, EK_engravingContrast,
    EK_engravingSharpness, EK_engravingWave, EK_engravingWaveFrequency, EK_crosshatch, EK_crosshatchSpacing, EK_crosshatchThickness,
    EK_crosshatchAngle, EK_crosshatchContrast, EK_crosshatchEdges, EK_crosshatchLineWeight, EK_crosshatchWave, EK_crosshatchWaveFrequency,
    EK_kuwahara, EK_kuwaharaRadius, EK_kuwaharaSharpness, EK_kuwaharaSaturation,
    EK_COUNT
};

// Parameters of the multipass kernels (buffer 0), by index.
enum MpvfxBlurParam { BLUR_DIR_X = 0, BLUR_DIR_Y, BLUR_RADIUS, BLUR_BLOOM_PASS, BLUR_THRESHOLD, BLUR_SOURCE_FLIPPED, BLUR_PARAM_COUNT };
enum MpvfxMomentsParam { MOMENTS_RADIUS = 0, MOMENTS_BLUR_AMOUNT, MOMENTS_PARAM_COUNT };
enum MpvfxResolveParam { RESOLVE_RADIUS = 0, RESOLVE_EXPONENT, RESOLVE_SATURATION, RESOLVE_PARAM_COUNT };

// Texture slots of the grade kernel.
enum MpvfxGradeTexture {
    GRADE_TEX_SOURCE = 0, GRADE_TEX_BLUR, GRADE_TEX_KUWAHARA, GRADE_TEX_BLOOM, GRADE_TEX_CURVES, GRADE_TEX_HUE,
    GRADE_TEX_SECONDARIES, GRADE_TEX_LUT, GRADE_TEX_OUTPUT, GRADE_TEX_COUNT
};

#endif
