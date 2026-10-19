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
import MpvfxDesktopCore
import MpvfxTheme

extension EditorSession {
    /// Reads the appearance setting (`<userData>/preferences.json`, MPVFX_APPEARANCE overrides; smoke snapshots
    /// default to Dark so they stay comparable with the recorded dark reference), applies it before the first paint and
    /// repaints on every switch. The Shortcuts card's Appearance row and the macOS View menu call `set`; the shell
    /// calls `systemAppearanceChanged` when the OS flips. `onModeChange` lets the shell retint its native window.
    @discardableResult
    func installAppearance(userData: String, systemPrefersDark: @escaping () -> Bool,
                           onModeChange: @escaping (ThemeMode) -> Void = { _ in }) -> AppearanceSettings {
        let env = ProcessInfo.processInfo.environment
        let override = env["MPVFX_APPEARANCE"] ?? (SmokeHooks(env: env).snapshotPath != nil ? ThemeAppearance.dark.rawValue : nil)
        let settings = AppearanceSettings(preferences: preferences(userData: userData), override: override,
                                          systemPrefersDark: systemPrefersDark)
        appearance = settings
        transport.shortcuts.appearance = settings.appearance
        transport.shortcuts.onAppearance = { [weak settings] a in settings?.set(a) }
        Theme.addObserver { [weak self] mode in
            guard let self else { return }
            self.transport.shortcuts.appearance = self.appearance?.appearance
            onModeChange(mode)
            self.redraw()
        }
        settings.apply()
        onModeChange(Theme.mode)
        return settings
    }

    /// Menu/UI entry point: switch and persist.
    func setAppearance(_ a: ThemeAppearance) {
        appearance?.set(a)
        transport.shortcuts.appearance = a
        redraw()
    }
}
