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

/// How a clip's picture combines with the layers under it (`clip.style.blend`). The order is the index the shading
/// body's `BLEND_*` constants use (`MpvfxColorShared.h`, checked by `BlendModeTests`).
public enum NativeBlendMode: String, CaseIterable, Codable, Sendable {
    case normal, multiply, screen, overlay, add
    case softLight = "soft-light"
    case darken, lighten

    /// The label the inspector's dropdown shows.
    public var label: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .add: "Add"
        case .softLight: "Soft light"
        case .darken: "Darken"
        case .lighten: "Lighten"
        }
    }

    /// Position in `allCases`: the mode number the GPU shading body takes.
    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
