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

/// What the preview shows of a colour-keyed clip (issue #300): the keyed picture, the key's matte (white kept, black
/// keyed out) or the source before the key. Preview only: it is never saved and export never reads it.
public enum ColorKeyViewMode: String, CaseIterable, Sendable {
    case result, matte, source

    public var label: String {
        switch self { case .result: "Result"; case .matte: "Matte"; case .source: "Source" }
    }
}
