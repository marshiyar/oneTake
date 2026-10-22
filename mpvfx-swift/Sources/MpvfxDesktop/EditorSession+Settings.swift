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
import MpvfxAudio
import MpvfxDesktopCore
import MpvfxPanels
import MpvfxShared
import MpvfxTimeline

// Settings (Cmd/Ctrl+,): appearance, interface size, audio output device, preview cache size, default export folder
// and default hold length, each kept in `<userData>/preferences.json` and applied as soon as it changes.
extension EditorSession {
    /// Reads the stored settings, applies the ones the session owns (interface size, audio device, preview cache) and
    /// puts the card on the window router.
    func installSettings(_ router: EditorShellRouter, userData: String) {
        let prefs = preferences(userData: userData)
        let panel = settingsPanel
        router.modal = panel
        panel.values = currentSettings(prefs)
        panel.deviceChoiceUnavailable = !(audio?.output is AudioDeviceSelecting)
        panel.onOpen = { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.values = self.currentSettings(prefs)
            self.refreshAudioDevices()
        }
        panel.onChange = { [weak self] values in self?.applySettings(values, prefs) }
        panel.onChooseExportFolder = { [weak self] in self?.chooseExportFolder() }
        router.interfaceScale = Self.interfaceScale(prefs.interfaceScalePercent)
        applyAudioDevice(prefs.audioOutputDevice)
        applyPreviewCache(prefs.previewCacheMB)
        timeline.holdSeconds = prefs.holdSeconds ?? TimelineEditor.defaultHoldSeconds
    }

    /// The router's scale for an interface size in percent.
    static func interfaceScale(_ percent: Int) -> Double { EditorShellRouter.validScale(Double(percent) / 100) }

    func currentSettings(_ prefs: DesktopPreferences) -> SettingsPanel.Values {
        var values = SettingsPanel.Values(appearance: appearance?.appearance ?? .system, audioDevice: prefs.audioOutputDevice,
                                          previewCacheMB: prefs.previewCacheMB, exportFolder: prefs.defaultExportFolder,
                                          interfaceScalePercent: prefs.interfaceScalePercent)
        values.inputDevice = prefs.audioInputDevice
        values.voiceCountIn = prefs.voiceCountIn
        values.holdSeconds = prefs.holdSeconds ?? TimelineEditor.defaultHoldSeconds
        return values
    }

    func showSettings() { settingsPanel.open(); redraw() }
    func toggleSettings() { settingsPanel.toggle(); redraw() }

    /// A change on the card: persist it and apply it now.
    func applySettings(_ v: SettingsPanel.Values, _ prefs: DesktopPreferences) {
        prefs.audioInputDevice = v.inputDevice
        prefs.voiceCountIn = v.voiceCountIn
        if v.appearance != appearance?.appearance { setAppearance(v.appearance) }
        if v.interfaceScalePercent != prefs.interfaceScalePercent {
            prefs.interfaceScalePercent = v.interfaceScalePercent
            shell?.interfaceScale = Self.interfaceScale(prefs.interfaceScalePercent)
        }
        if v.audioDevice != prefs.audioOutputDevice { prefs.audioOutputDevice = v.audioDevice; applyAudioDevice(v.audioDevice) }
        if v.previewCacheMB != prefs.previewCacheMB { prefs.previewCacheMB = v.previewCacheMB; applyPreviewCache(v.previewCacheMB) }
        if v.exportFolder != prefs.defaultExportFolder { prefs.defaultExportFolder = v.exportFolder; panels?.refreshRenders() }
        if v.holdSeconds != (prefs.holdSeconds ?? TimelineEditor.defaultHoldSeconds) { prefs.holdSeconds = v.holdSeconds; timeline.holdSeconds = v.holdSeconds }
        settingsPanel.saveError = prefs.lastWriteError.map { "Could not save settings (\($0)); they last until you quit." }
        redraw()
    }

    /// Lists the output devices off the UI thread (asking the sound server can take a moment).
    func refreshAudioDevices() {
        let post = postToUI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let inputs = AudioInputDevices.list().map { SettingsPanel.Device(id: $0.id, name: $0.name) }
            let devices = AudioOutputDevices.list().map { SettingsPanel.Device(id: $0.id, name: $0.name) }
            post {
                guard let self else { return }
                self.settingsPanel.inputDevices = inputs
                self.settingsPanel.devices = devices
                self.redraw()
            }
        }
    }

    /// Plays through `device` (nil: the system default); playing audio restarts on it at the same position.
    func applyAudioDevice(_ device: String?) {
        guard let audio, let output = audio.output as? AudioDeviceSelecting, output.device != device else { return }
        output.device = device
        if audio.isPlaying { audio.stop(); syncAudio() }
    }

    /// The preview's decoded frame cache: the chosen size, or automatic. MPVFX_PREVIEW_CACHE_MB still wins.
    func applyPreviewCache(_ mb: Int?) {
        guard ProcessInfo.processInfo.environment["MPVFX_PREVIEW_CACHE_MB"] == nil else { return }
        compositor.cache.budgetBytes = mb.map { $0 << 20 } ?? MemoryBudget.previewFrames()
    }

    /// Settings > Export folder > Choose…: the native folder dialog.
    func chooseExportFolder() {
        guard let dialogs = panels?.dialogs else { return }
        Task { [weak self] in
            guard let dir = await dialogs.showOpen(.init(title: "Default Export Folder", directory: true, multiple: false)).first else { return }
            self?.postToUI { self?.settingsPanel.exportFolderChosen(dir) }
        }
    }
}
