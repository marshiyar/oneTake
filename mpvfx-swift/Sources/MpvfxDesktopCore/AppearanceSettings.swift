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
// Appearance setting. System follows the OS (macOS effective
// appearance, GTK prefer-dark / GNOME color-scheme on Linux), Light and Dark force a palette. Stored in
// `<userData>/preferences.json` under "mpvfx-appearance"; missing or unknown means System. MPVFX_APPEARANCE
// (system|light|dark) overrides it for one run without touching the file. Applying sets `Theme.mode`, whose
// observers repaint the window, so a switch takes effect live.
import Foundation
import MpvfxTheme

public final class AppearanceSettings {
    public private(set) var appearance: ThemeAppearance
    /// Set when MPVFX_APPEARANCE (or a smoke run) chose the appearance; such a run never writes the file.
    public let isOverridden: Bool
    private let preferences: DesktopPreferences?
    /// Whether the OS currently prefers dark (asked again on every apply).
    public var systemPrefersDark: () -> Bool

    public init(preferences: DesktopPreferences?, override: String? = nil, systemPrefersDark: @escaping () -> Bool) {
        self.preferences = preferences
        self.systemPrefersDark = systemPrefersDark
        if let o = override, let a = ThemeAppearance(rawValue: o.lowercased()) {
            appearance = a; isOverridden = true
        } else {
            appearance = ThemeAppearance(preference: preferences?.value(ThemeAppearance.preferenceKey)?.string)
            isOverridden = false
        }
    }

    /// The mode the current setting resolves to.
    public var mode: ThemeMode { appearance.resolve(systemPrefersDark: systemPrefersDark()) }

    /// Publishes the resolved mode (observers repaint when it changes).
    public func apply() { Theme.setMode(mode) }

    /// The user picked an appearance: persist it and switch now.
    public func set(_ a: ThemeAppearance) {
        appearance = a
        if !isOverridden { preferences?.set(ThemeAppearance.preferenceKey, .string(a.rawValue)) }
        apply()
    }

    /// The OS appearance changed: only System follows it.
    public func systemAppearanceChanged() { if appearance == .system { apply() } }
}
