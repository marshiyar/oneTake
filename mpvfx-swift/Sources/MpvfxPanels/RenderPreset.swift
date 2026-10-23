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

/// A named snapshot of every Renders setting. Unknown formats remain visible but cannot be applied.
public struct RenderPreset: Codable, Equatable {
    public var name: String
    public var settings: RenderSettingsModel
    public init(name: String, settings: RenderSettingsModel) { self.name = name; self.settings = settings }
    /// Structural corruption is refused before the settings can reach numeric UI fields.
    public var hasValidSettings: Bool {
        !settings.format.isEmpty && ["draft", "standard", "high"].contains(settings.quality)
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
