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
import MpvfxColor
import MpvfxPanels

/// The inspector's LUT status line from a grade's `lut.src` (issue #182): the grid size of the file the preview
/// reads, through the same resolution and cache (`CubeLUTCache`), or why it cannot be read. The preview skips a LUT
/// that fails to load, so the clip renders without it.
public enum LutStatusReader {
    /// The status of the LUT at `src`, resolved against `projectDir` as the preview resolves it.
    public static func status(
        _ src: String,
        projectDir: String?,
        cache: CubeLUTCache = .shared
    ) -> LutStatus {
        guard let path = CubeLUTCache.resolve(src, projectDir: projectDir) else {
            return .failed("the file is missing")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failed("the file is missing")
        }
        switch cache.load(path) {
        case .success(let lut):
            return .loaded(size: lut.size)

        case .failure(let error):
            return .failed(error.description)
        }
    }
}
