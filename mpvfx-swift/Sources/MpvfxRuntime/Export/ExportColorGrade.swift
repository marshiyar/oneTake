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
// Color grade and stylize effects in export: drawn by the frame renderer with the same grading pass the preview uses
// (MpvfxColor through PreviewGrader), at each frame's timeline time. Here: which effects export accepts.
import Foundation
import MpvfxShared
import MpvfxColor

/// The clip's enabled `color-grading` effect, as a renderer; nil when the clip has none or it changes nothing.
func exportGradeRenderer(_ clip: NativeProjectClip, projectDir: String) -> ColorGradeRenderer? {
    ColorGradeRenderer.forClip(ColorGradeParams.clipGrade(clip), clipId: clip.id, projectDir: projectDir)
}

/// Effects the native renderer draws: the color grade (with its stylize effects). Others are still refused.
func exportSupportsEffect(_ effect: NativeClipEffect) -> Bool { effect.effectId == ColorGradeParams.effectId }
