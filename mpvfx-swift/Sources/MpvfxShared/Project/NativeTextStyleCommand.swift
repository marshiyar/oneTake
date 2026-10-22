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
}
