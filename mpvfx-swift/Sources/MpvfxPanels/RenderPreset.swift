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
import MpvfxShared

/// A composition size a preset renders the project at, in whole pixels. The project itself keeps its own size.
public struct RenderPresetComposition: Codable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    var isValid: Bool {
        [width, height].allSatisfy { $0.isFinite && $0 == $0.rounded() && $0 >= 1 && $0 <= NATIVE_CANVAS_MAX_SIDE }
    }
}

/// A named snapshot of every Renders setting. Unknown formats remain visible but cannot be applied.
public struct RenderPreset: Codable, Equatable {
    public var name: String
    public var settings: RenderSettingsModel
    /// The composition size "Export versions" renders this preset at; nil renders at the project's own size.
    /// Applying the preset to the Renders tab never changes the project.
    public var composition: RenderPresetComposition?
    public init(name: String, settings: RenderSettingsModel, composition: RenderPresetComposition? = nil) {
        self.name = name; self.settings = settings; self.composition = composition
    }
    /// Structural corruption is refused before the settings can reach numeric UI fields.
    public var hasValidSettings: Bool {
        (composition?.isValid ?? true) && !settings.format.isEmpty && ["draft", "standard", "high"].contains(settings.quality)
            && [24.0, 30, 60].contains(settings.fps)
            && ["auto", "720p", "1080p", "1440p", "2160p", "4320p", "custom"].contains(settings.resolution)
            && settings.customWidth.isFinite && settings.customHeight.isFinite
            && settings.customWidth > 0 && settings.customHeight > 0
            && settings.customWidth <= 7680 && settings.customHeight <= 7680
    }
    public var unavailableReason: String? {
        ["mp4", "mov"].contains(settings.format) ? nil : "Format \(settings.format) is not supported yet"
    }
}
