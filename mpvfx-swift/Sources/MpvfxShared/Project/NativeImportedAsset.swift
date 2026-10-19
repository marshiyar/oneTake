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
import Foundation

/// The document asset for a freshly imported media file. The natural size probed during the import (sample aspect,
/// rotation and EXIF orientation applied) is cached on it, so the clip's default box
/// (fitTimelineAssetGeometry) is known before the asset can be placed: the first frame the stage or preview ever
/// draws of it is already the fitted box, never a full-frame flash that snaps once a later probe answers.
/// Stills last 5 s (the starter sequence's length); `durationSeconds` sets video and audio lengths.
public func nativeImportedMediaAsset(id: String, kind: NativeProjectAssetKind, name: String, source: String,
                                     durationSeconds: Double, fps: Double,
                                     width: Double?, height: Double?) -> NativeProjectAsset {
    let frames = kind == .image ? (5 * fps).rounded() : Swift.max(1, (durationSeconds * fps).rounded(.down))
    var asset = NativeProjectAsset(id: id, kind: kind, name: name, source: source, durationFrames: frames)
    if kind == .video || kind == .image, let width, let height {
        asset.naturalSize = NativeMediaNaturalSize(width: width, height: height)
    }
    return asset
}
