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

/// An atomic project text-style edit.
public enum NativeTextStyleCommand: Equatable, Sendable {
    case apply(styleId: String, clipIds: [String])

    case detach(clipIds: [String])

    case save(clipId: String, styleId: String, name: String)

    case update(styleId: String, fromClipId: String)

    /// Saves the clip as a new project style and links the clip to it, as one edit.
    case create(clipId: String, styleId: String, name: String)

    /// Links the clips to a style that comes from the user's library. A project that already holds the style id
    /// keeps its own copy; otherwise the library's copy is added to the project first.
    case adopt(style: NativeTextStyle, clipIds: [String])
}
