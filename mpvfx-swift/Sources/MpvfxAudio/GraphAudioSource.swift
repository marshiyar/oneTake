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
import MpvfxAudioGraph

/// Live-playback front end for `AudioGraphRenderer`. Thread-safe: the feeder thread seeks and renders while the
/// session's graph worker swaps in an edited project; the UI thread only sets the transport gain and mute, which
/// never wait on the graph.
///
/// Exactness: the graph is a strictly in-order pull from frame 0 (FX state, quanta alignment and envelopes
/// are all counted from frame 0), so a seek is a *pre-roll*: render, and discard, up to the target. A forward
/// seek continues from the current position (identical stream, cheaper); a backward seek, or a rebuilt
/// project, starts a fresh renderer at frame 0. Output at gain 1 / unmuted is bit-identical to `renderAll()`.
public final class GraphAudioSource: AudioRenderSource {
    public static let quantum = 128
    /// Frames per pre-roll pull (any partition gives the same samples; big chunks are just faster).
    public static let preRollChunk = 1 << 16

    public struct PreRoll: Equatable, Sendable {
        public var fromFrame: Int, targetFrame: Int, seconds: Double
        public var framesRendered: Int { targetFrame - fromFrame }
    }

    public let format: AudioFormat
    let lock = NSLock()
    public private(set) var project: AudioGraphProject
    var renderer: AudioGraphRenderer
    var gain = 1.0, isMuted = false
    var lastPreRoll_: PreRoll?

    public init(project: AudioGraphProject) {
        precondition(project.sampleRate.rounded() == project.sampleRate, "integral sample rate")
        format = AudioFormat(sampleRate: Int(project.sampleRate), channels: 2)
        self.project = project
        renderer = AudioGraphRenderer(project)
    }

    /// Transport gain/mute have their own lock: the UI sets them every tick, and must never wait behind a seek
    /// pre-roll or a swap that holds `lock`.
    let gainLock = NSLock()
    public var masterGain: Double {
        get { gainLock.lock(); defer { gainLock.unlock() }; return gain }
        set { gainLock.lock(); gain = newValue; gainLock.unlock() }
    }
    public var muted: Bool {
        get { gainLock.lock(); defer { gainLock.unlock() }; return isMuted }
        set { gainLock.lock(); isMuted = newValue; gainLock.unlock() }
    }
    /// Next frame the graph will render.
    public var position: Int { lock.lock(); defer { lock.unlock() }; return renderer.position }
    public var lastPreRoll: PreRoll? { lock.lock(); defer { lock.unlock() }; return lastPreRoll_ }

    public func seek(_ t: Double) { seek(frame: Int(((t.isFinite ? max(0, t) : 0) * project.sampleRate).rounded())) }

    public func seek(frame target: Int) {
        lock.lock(); defer { lock.unlock() }
        seekGeneration += 1
        let t = max(0, min(target, renderer.totalFrames))
        if target < renderer.position, let a = armed, a.version == projectVersion, a.renderer.position == t {
            // The loop start, pre-rolled in the background: the wrap is a pointer swap, not a pre-roll from frame 0.
            renderer = a.renderer; armed = nil
            lastPreRoll_ = PreRoll(fromFrame: t, targetFrame: t, seconds: 0)
            return
        }
        preRoll(to: target, fresh: target < renderer.position)
    }

    // MARK: Loop start, ready in advance

    /// A renderer pre-rolled to a frame a seek is expected to land on (the loop start), built from `project` at
    /// `version`. Bit-identical to what `seek` would build there, so using it changes no sample.
    var armed: (renderer: AudioGraphRenderer, version: Int)?
    /// Bumped whenever the running graph changes (rebuild or in-place parameters): an armed renderer from an older
    /// project is never used.
    var projectVersion = 0
    var arming: (frame: Int, version: Int)?
    let armQueue = DispatchQueue(label: "mpvfx.audio.loop-start", qos: .userInitiated)

    public func prepareSeek(_ t: Double) {
        let frame = Int(((t.isFinite ? max(0, t) : 0) * project.sampleRate).rounded())
        lock.lock()
        let target = min(frame, renderer.totalFrames), version = projectVersion, p = project
        if let a = armed, a.version == version, a.renderer.position == target { lock.unlock(); return }
        if let a = arming, a.frame == target, a.version == version { lock.unlock(); return }
        arming = (target, version)
        lock.unlock()
        armQueue.async { [weak self] in
            let r = AudioGraphRenderer(p)
            var left = target
            while left > 0 {
                let n = min(left, Self.preRollChunk); _ = r.render(n); left -= n
                guard let self else { return }
                self.lock.lock(); let stale = self.projectVersion != version; self.lock.unlock()
                if stale { self.lock.lock(); if self.arming?.version == version { self.arming = nil }; self.lock.unlock(); return }
            }
            guard let self else { return }
            self.lock.lock()
            if self.projectVersion == version { self.armed = (r, version) }
            if self.arming?.frame == target && self.arming?.version == version { self.arming = nil }
            self.lock.unlock()
        }
    }

    /// What the last `replace` did.
    public enum ReplaceOutcome: Equatable, Sendable {
        /// Only live-editable values changed: the running graph took them (AudioGraphRenderer.applyParameterEdits).
        case parametersInPlace
        /// A new graph was built, pre-rolled from frame 0 off the lock, and swapped in at the playing position.
        case rebuilt
    }
    public private(set) var lastReplace: ReplaceOutcome?
    /// Serialises replaces (the session's graph worker is the only caller in the app; tests may race).
    let replaceLock = NSLock()
    /// Bumped by every seek, so a replace that was pre-rolling toward a position that no longer exists restarts.
    var seekGeneration = 0
    /// Counts `replace` calls and `supersedeReplace`; a replace still pre-rolling when the count moves gives up
    /// (a newer edit wins). Its own lock, so the UI can bump it without waiting on the graph.
    let ticketLock = NSLock()
    var replaceRequests = 0
    func currentTicket() -> Int { ticketLock.lock(); defer { ticketLock.unlock() }; return replaceRequests }

    /// Tells a replace that is still pre-rolling to give up: a newer edit is on its way. Never blocks.
    public func supersedeReplace() { ticketLock.lock(); replaceRequests += 1; ticketLock.unlock() }
    /// Frames a replace may still render while holding the lock to catch up before the swap (~43 ms at 48 kHz).
    public static let swapCatchUpFrames = 1 << 11

    /// Swap in a rebuilt project (document edit) at the current position. Never call this on the UI thread with
    /// a structural change: the new graph is pre-rolled from frame 0, which costs time proportional to the
    /// playhead. That work runs off the lock, so `render` (the feeder) keeps playing the old graph until the new
    /// one has caught up; only the last few quanta and the swap itself are done under the lock.
    /// Parameter-only edits are applied to the running graph instead (no pre-roll).
    public func replace(_ newProject: AudioGraphProject) {
        ticketLock.lock(); replaceRequests += 1; let ticket = replaceRequests; ticketLock.unlock()
        replaceLock.lock(); defer { replaceLock.unlock() }
        if currentTicket() != ticket { return }   // superseded while waiting
        lock.lock()
        if renderer.applyParameterEdits(newProject) {
            project = newProject
            projectVersion += 1
            lastReplace = .parametersInPlace
            lock.unlock()
            return
        }
        lock.unlock()
        let start = DispatchTime.now().uptimeNanoseconds
        var fresh = AudioGraphRenderer(newProject)
        while true {
            if currentTicket() != ticket { return }
            lock.lock()
            let target = min(renderer.position, fresh.totalFrames), gen = seekGeneration
            if target < fresh.position { lock.unlock(); fresh = AudioGraphRenderer(newProject); continue }   // seeked backward meanwhile
            if target - fresh.position <= Self.swapCatchUpFrames {
                var left = target - fresh.position
                while left > 0 { let n = min(left, Self.preRollChunk); _ = fresh.render(n); left -= n }
                project = newProject
                renderer = fresh
                projectVersion += 1
                lastReplace = .rebuilt
                lastPreRoll_ = PreRoll(fromFrame: 0, targetFrame: target, seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                lock.unlock()
                return
            }
            lock.unlock()
            // Pre-roll toward where playback is now, without the lock; the loop re-checks how far it moved.
            var left = target - fresh.position
            while left > 0 {
                let n = min(left, Self.preRollChunk); _ = fresh.render(n); left -= n
                lock.lock(); let moved = seekGeneration != gen; lock.unlock()
                if currentTicket() != ticket { return }
                if moved { break }
            }
        }
    }

    func preRoll(to target0: Int, fresh: Bool) {
        let start = DispatchTime.now().uptimeNanoseconds
        if fresh { renderer = AudioGraphRenderer(project) }
        let from = renderer.position
        let target = max(from, min(target0, renderer.totalFrames))
        var left = target - from
        while left > 0 { let n = min(left, Self.preRollChunk); _ = renderer.render(n); left -= n }
        lastPreRoll_ = PreRoll(fromFrame: from, targetFrame: target, seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

    public func render(frames: Int) -> [Float] {
        lock.lock()
        var out = renderer.render(frames)
        lock.unlock()
        gainLock.lock(); let g: Float = isMuted ? 0 : Float(gain); gainLock.unlock()
        if out.count < frames * 2 { out += [Float](repeating: 0, count: frames * 2 - out.count) } // past the end: silence
        if g != 1 { for i in out.indices { out[i] *= g } }
        return out
    }
}
