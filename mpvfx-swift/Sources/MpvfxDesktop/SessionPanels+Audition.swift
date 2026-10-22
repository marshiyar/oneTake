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
// Audition from the media bin, host side: owns the `AssetAuditionPlayer` on the output the timeline plays on, pauses
// the timeline while a file plays (and does not resume it), follows the transport's volume and mute, and tells the
// panel where the file is each frame.
import Foundation
import MpvfxAudio
import MpvfxPanels

extension SessionPanels {
    func wireAudition() {
        left.onAuditionToggle = { [weak self] id in self?.toggleAudition(id) }
        left.onAuditionSeek = { [weak self] _, seconds in self?.auditionPlayer?.seek(to: seconds); self?.pollAudition() }
        left.onAuditionSeekBy = { [weak self] delta in self?.auditionPlayer?.seek(by: delta); self?.pollAudition() }
        left.onAuditionStop = { [weak self] in self?.stopAudition() }
    }

    /// Starts the audition of the bin asset `id`, or stops it when that asset already plays. One at a time: starting
    /// another ends the first. The timeline is paused first and stays paused after the audition ends.
    func toggleAudition(_ id: String) {
        if left.audition?.assetId == id { stopAudition(); return }
        guard let item = left.items.first(where: { $0.id == id }) else { return }
        guard let dir = session.projectDir else {
            left.auditionErrors[id] = AuditionError(name: item.name, reason: "no project is open").description
            redraw(); return
        }
        guard let output = session.audio?.output else {
            left.auditionErrors[id] = AuditionError(name: item.name, reason: "this system has no sound device").description
            redraw(); return
        }
        let player = auditionPlayer ?? AssetAuditionPlayer(output: output)
        auditionPlayer = player
        auditionProjectId = projectId
        pauseTimelineForAudition()
        player.volume = session.transport.volume.volume
        player.muted = session.playback.audioMuted
        left.audition = nil
        do {
            try player.start(assetId: id, path: dir.appendingPathComponent(item.path ?? id).path, name: item.name, durationHint: item.duration ?? 0)
            left.audition = AuditionTileState(assetId: id, position: 0, duration: item.duration ?? 0)
            left.onAnimate?()
        } catch let error as AuditionError {
            left.auditionErrors[id] = error.description
        } catch {
            left.auditionErrors[id] = AuditionError(name: item.name, reason: (error as? DesktopError)?.message ?? "the file could not be read").description
        }
        redraw()
    }

    func stopAudition() {
        auditionPlayer?.stop()
        left.audition = nil
        redraw()
    }

    /// The timeline stops and its sound device is handed over; nothing starts it again but the user.
    private func pauseTimelineForAudition() {
        if session.playback.isPlaying { session.playback.pause() }
        session.syncAudio()
        session.timeline.syncFromPlayback()
    }

    /// Before the timeline plays: a running audition ends so the two never share the device.
    func endAuditionForTimeline() {
        guard left.audition != nil else { return }
        auditionPlayer?.stop()
        left.audition = nil
    }

    /// Once per animation frame: the player's position, volume and mute into the panel; a finished or failed audition
    /// ends here; switching projects ends it. True while a file still plays (the panel keeps animating).
    @discardableResult
    func pollAudition() -> Bool {
        guard let player = auditionPlayer, left.audition != nil else { return false }
        if auditionProjectId != projectId { stopAudition(); return false }
        player.volume = session.transport.volume.volume
        player.muted = session.playback.audioMuted
        guard let status = player.poll() else { left.audition = nil; return false }
        if let error = status.error {
            left.auditionErrors[status.assetId] = error.description
            left.audition = nil
            return false
        }
        if status.finished { left.audition = nil; return false }
        left.audition = AuditionTileState(assetId: status.assetId, position: status.position, duration: status.duration)
        return true
    }
}
