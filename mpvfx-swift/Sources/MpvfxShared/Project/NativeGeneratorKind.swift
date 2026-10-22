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

public enum NativeGeneratorKind: String, CaseIterable, Sendable {
    case solid, linear, radial
    public var label: String {
        switch self { case .solid: "Solid colour"; case .linear: "Linear gradient"; case .radial: "Radial gradient" }
    }
    public var fill: NativeFill {
        if self == .solid { return NativeFill(kind: "color", color: "#4050B8") }
        return NativeFill(kind: "gradient", stops: [.init(offset: 0, color: "#4050B8"), .init(offset: 1, color: "#F2B880")],
                          angle: 90, gradientType: self == .radial ? "radial" : "linear", centerX: 0.5, centerY: 0.5)
    }
    /// The inspector's fallback when a solid fill carries no colour: the model's own solid default.
    public static var defaultSolidColor: String { Self.solid.fill.color ?? "#000000" }
}
