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
/// A layout-space advance box and a half-open UTF-16 range into the original TextBlock.text.
/// Ranges end at extended grapheme boundaries. Arrays follow logical reading order, including
/// RTL lines; x coordinates need not increase. Boxes describe advances rather than ink bounds.
public struct TextUnit: Equatable, Sendable {
    public let range: Range<Int>
    public let rect: CanvasRect

    public init(range: Range<Int>, rect: CanvasRect) {
        self.range = range
        self.rect = rect
    }
}
