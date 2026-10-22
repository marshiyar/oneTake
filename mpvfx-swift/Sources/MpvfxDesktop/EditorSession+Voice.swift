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
import MpvfxCanvas
import MpvfxDesktopCore
import MpvfxPanels
import MpvfxPlayer
import MpvfxTimeline

extension EditorSession {
    func voiceKey(_ k: EditorKey) -> Bool {
        if k.code == .space, k.alt, !k.command, !k.shift {
            if !k.isRepeat { toggleVoice() }
            return true
        }
        guard voice.state != .idle else { return false }
        if k.code == .escape { cancelVoice(); return true }
        if k.code == .space, !k.command, !k.alt {
            if !k.isRepeat { finishVoice() }
            return true
        }
        return false
    }

    func toggleVoice() {
        if voice.state != .idle { finishVoice(); return }
        guard !voiceImporting else { return }
        guard backend != nil, project != nil, let folder = projectDir else {
            onError("Cannot record voice", "Open a saved project before recording voice."); return
        }
        guard let input = makeVoiceInput() else { onError("Cannot record voice", "No microphone backend is available."); return }
        (input as? AudioInputDeviceSelecting)?.device = desktopPreferences?.audioInputDevice
        let destination = folder.appendingPathComponent("media/.voice-takes/\(UUID().uuidString.lowercased()).wav")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            playback.pause()
            voice.onStart = { [weak self] in
                guard let self else { return }
                self.playback.seek(self.voiceStart)
                self.playback.setPlaybackRate(1)
                self.playback.play()
                self.ensurePlayTimer?()
            }
            voiceStart = playback.currentTime
            try voice.arm(input: input, destination: destination.path, playhead: voiceStart,
                          countIn: desktopPreferences?.voiceCountIn ?? 3, now: ProcessInfo.processInfo.systemUptime, fps: editor.fps)
            voiceGeneration += 1
            pollVoice(voiceGeneration)
        } catch { cancelVoice(); onError("Cannot record voice", (error as? DesktopError)?.message ?? "The voice could not be recorded. Check the microphone, then try again.") }
        redraw()
    }

    /// Count-in and meter continue when playback is paused or reaches the end.
    func pollVoice(_ generation: Int) {
        guard generation == voiceGeneration, voice.state != .idle else { return }
        do { try voice.tick(now: ProcessInfo.processInfo.systemUptime) }
        catch { cancelVoice(); onError("Cannot record voice", (error as? DesktopError)?.message ?? "The voice could not be recorded. Check the microphone, then try again."); return }
        redraw()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postToUI { [weak self] in self?.pollVoice(generation) }
        }
    }

    func cancelVoice() {
        voiceGeneration += 1
        voice.cancel()
        playback.pause()
        redraw()
    }

    func finishVoice() {
        let placement = voice.placementSeconds
        voiceGeneration += 1
        playback.pause()
        do {
            guard let recording = try voice.stop() else { redraw(); return }
            guard recording.frames > 0 else {
                try FileManager.default.removeItem(atPath: recording.path); redraw(); return
            }
            importVoice(recording, placement: placement)
        } catch { onError("Could not keep the take", (error as? DesktopError)?.message ?? "The take could not be kept. Try recording again.") }
        redraw()
    }

    /// Use the regular importer, then add the asset, clip and muted takes in one history entry.
    func importVoice(_ recording: VoiceRecording, placement: Double) {
        guard let backend, let project else { return }
        voiceImporting = true
        Task { [weak self] in
            do {
                let imported = try await backend.importMedia(projectId: project.id, paths: [recording.path], directory: nil)
                self?.postToUI {
                    guard let self else { return }
                    self.voiceImporting = false
                    guard self.project?.id == project.id, let media = imported.media.first(where: { $0.kind == "audio" }),
                          self.editor.addVoiceTake(source: media.path, seconds: recording.seconds, at: placement) else {
                        self.onError("Take not placed", "The WAV is kept at \(recording.path). Import it to recover the recording.")
                        self.redraw(); return
                    }
                    self.panels?.refreshMedia(); self.syncStage(); self.redraw()
                    // Remove only our staging copy, never the importer's published file.
                    let published = URL(fileURLWithPath: project.directory).appendingPathComponent(media.path).standardizedFileURL.path
                    if published != URL(fileURLWithPath: recording.path).standardizedFileURL.path {
                        do { try FileManager.default.removeItem(atPath: recording.path) }
                        catch { self.onError("Take recorded", "The extra recording copy could not be removed: \(recording.path)") }
                    }
                    if let failure = recording.failure { self.onError("Recording stopped early", "\(failure). The captured audio was kept.") }
                }
            } catch {
                self?.postToUI {
                    self?.voiceImporting = false
                    self?.onError("Take not imported", (error as? DesktopError).map { $0.message + " The WAV is kept at \(recording.path)." } ?? "The take could not be imported. The WAV is kept at \(recording.path).")
                    self?.redraw()
                }
            }
        }
    }

    func voiceRect(_ size: CanvasSize) -> CanvasRect {
        CanvasRect(x: size.width >= 700 ? size.width / 2 - 140 : 12,
                   y: size.height - PlayerView.controlsHeight + (size.width >= 700 ? 6 : -34), width: 116, height: 28)
    }

    func drawVoice(_ c: CanvasContext, size: CanvasSize) {
        let r = voiceRect(size)
        let active = voice.state != .idle
        let label: String
        switch voice.state {
        case .idle: label = voiceImporting ? "Keeping take…" : "Record voice"
        case .counting: label = "Voice in \(voice.countdown)…"
        case .recording: label = "Stop voice"
        }
        PanelDraw.smallButton(c, r, label: label, fill: active ? PanelTheme.danger : PanelTheme.panelSurface,
                              color: active ? PanelTheme.onAccent : PanelTheme.text1)
        guard active else { return }
        let m = voice.meter
        let meter = CanvasRect(x: r.x, y: r.y - 9, width: r.width, height: 5)
        c.fillRect(meter, PanelTheme.panelInput)
        c.fillRect(CanvasRect(x: meter.x, y: meter.y, width: meter.width * Double(m.peak), height: meter.height), PanelTheme.accent)
        if m.clipped { c.fillRect(CanvasRect(x: meter.maxX - 5, y: meter.y, width: 5, height: meter.height), PanelTheme.danger) }
    }
}
