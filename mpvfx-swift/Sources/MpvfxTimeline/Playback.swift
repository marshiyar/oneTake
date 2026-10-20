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

/// Platform-neutral key event (GTK/Win32/AppKit hosts translate into this).
public struct EditorKey: Equatable, Sendable {
    public enum Code: Equatable, Sendable { case space, left, right, up, down, home, end, delete, backspace, escape, enter, tab, char(Character) }
    public var code: Code; public var shift = false, ctrl = false, alt = false, meta = false, isRepeat = false
    public init(_ code: Code, shift: Bool = false, ctrl: Bool = false, alt: Bool = false, meta: Bool = false, isRepeat: Bool = false) {
        self.code = code; self.shift = shift; self.ctrl = ctrl; self.alt = alt; self.meta = meta; self.isRepeat = isRepeat
    }
    /// ⌘ on macOS, Ctrl elsewhere.
    public var command: Bool { meta || ctrl }
    var letter: Character? { if case .char(let c) = code { return Character(c.lowercased()) }; return nil }
}

/// Playback state and its keys (Space, J/K/L shuttle, M, ⇧L, ←/→, I/O, A/E).
public final class PlaybackState {
    public static let shuttleSpeeds: [Double] = [1, 2, 4]
    public var fps: Double
    public var duration: Double
    public private(set) var currentTime = 0.0
    public private(set) var isPlaying = false
    public private(set) var direction = 1.0          // -1 = playing backward (J)
    public private(set) var playbackRate = 1.0
    /// The transport's loop toggle (loopEnabled): per session, off on open, never saved (it is
    /// kept in memory only).
    public var loopEnabled = false {
        didSet { if loopEnabled != oldValue { onChange?() } }
    }
    public var audioMuted = false
    /// Work-area in point (playerStore setInPoint): setting one turns loop on so playback respects it, and an out
    /// point at or before it is dropped.
    public var inPoint: Double? {
        didSet {
            if let t = inPoint, !t.isFinite { inPoint = nil; return }
            guard let t = inPoint else { return }
            if let o = outPoint, t >= o { outPoint = nil }
            loopEnabled = true
        }
    }
    /// Work-area out point (setOutPoint): turns loop on; an in point at or after it is dropped.
    public var outPoint: Double? {
        didSet {
            if let t = outPoint, !t.isFinite { outPoint = nil; return }
            guard let t = outPoint else { return }
            if let i = inPoint, t <= i { inPoint = nil }
            loopEnabled = true
        }
    }
    var shuttleDirection: Double?
    var shuttleIndex = 0
    var pressed: Set<Character> = []
    public var onChange: (() -> Void)?

    public init(duration: Double, fps: Double = 30) { self.duration = duration; self.fps = fps }

    public func seek(_ t: Double) { currentTime = max(0, min(duration, t.isFinite ? t : 0)); onChange?() }
    /// useTimelinePlayer play(): from the very end, start again at the in point (else 0).
    public func play() {
        if currentTime >= duration - 1e-9 && direction > 0 { currentTime = max(0, min(duration, inPoint ?? 0)) }
        isPlaying = true; onChange?()
    }
    public func pause() { isPlaying = false; direction = 1; shuttleDirection = nil; shuttleIndex = 0; onChange?() }
    /// SpeedMenu onRateChange: sets the forward playback rate (store setPlaybackRate).
    public func setPlaybackRate(_ r: Double) { guard r.isFinite, r > 0 else { return }; playbackRate = r; direction = 1; shuttleDirection = nil; shuttleIndex = 0; onChange?() }
    public func togglePlay() { if isPlaying { pause() } else { direction = 1; playbackRate = 1; play() } }

    /// stepFrameTime: whole frames, never below 0. Pauses like the original stepFrames.
    public func stepFrames(_ n: Int) {
        if isPlaying { pause() }
        let frame = currentTime > 0 ? (currentTime * fps).rounded() : 0
        seek(max(0, frame + Double(n)) / fps)
    }

    func shuttle(_ dir: Double) {
        if shuttleDirection == dir { shuttleIndex = min(shuttleIndex + 1, Self.shuttleSpeeds.count - 1) } else { shuttleIndex = 0 }
        shuttleDirection = dir
        if dir < 0 && currentTime <= 0 && duration > 0 { currentTime = duration }   // playBackward from the start
        playbackRate = Self.shuttleSpeeds[shuttleIndex]; direction = dir
        isPlaying = true; onChange?()
    }

    /// The playback range (useTimelinePlayer/useTimelinePlayerLoop): in point (else 0) to out point clamped to the
    /// duration (else the duration); an empty or inverted pair means the whole timeline. Forward playback wraps
    /// to `loopStart` at `loopEnd` when loop is on and stops there when it is off; reverse wraps to `loopEnd`
    /// at `loopStart`, or stops at `loopStart`. The selection never bounds playback.
    public var loopStart: Double {
        let s = inPoint ?? 0, e = outPoint.map { min($0, duration) } ?? duration
        return s < e ? s : 0
    }
    public var loopEnd: Double {
        let s = inPoint ?? 0, e = outPoint.map { min($0, duration) } ?? duration
        return s < e ? e : duration
    }

    /// Advance by wall-clock `dt` seconds. Returns true if the time changed.
    /// Master clock (the audio device). When it returns a time during forward 1× playback, video follows it
    /// instead of the wall clock; nil (no device, shuttle, reverse) falls back to `dt`.
    public var externalClock: (() -> Double?)?
    /// Whether the external clock should be running now (forward, 1×).
    public var wantsExternalClock: Bool { isPlaying && direction > 0 && playbackRate == 1 }

    @discardableResult public func tick(_ dt: Double) -> Bool {
        var dt = dt
        if wantsExternalClock, let clk = externalClock?() {
            // The audio device wraps the loop itself (AudioPlayback renders loop end → loop start seamlessly), so a
            // clock that went back while looping is the wrap: follow it rather than waiting for it to catch up.
            if loopEnabled && clk < currentTime - 1e-6 && clk >= loopStart - 1e-6 {
                currentTime = max(0, min(duration, clk)); onChange?(); return true
            }
            dt = clk - currentTime; if dt < 0 { return false }
        }
        guard isPlaying, dt > 0 else { return false }
        var t = currentTime + dt * playbackRate * direction
        let start = loopStart, end = loopEnd
        // Within a nanosecond of the boundary counts as reaching it: summed tick steps (2.9 + 0.05 + 0.05) land a
        // hair short of the end frame and must still wrap there, not one tick later.
        if direction > 0 && t >= end - 1e-9 {
            if loopEnabled && duration > 0 { t = start }                 // seek(loopStart), keep playing
            else { t = end; isPlaying = false; shuttleDirection = nil; shuttleIndex = 0 }
        } else if direction < 0 && t <= start + 1e-9 {
            if loopEnabled && duration > 0 { t = end }
            else { t = start; isPlaying = false; direction = 1; shuttleDirection = nil; shuttleIndex = 0 }
        }
        currentTime = max(0, min(duration, t)); onChange?(); return true
    }

    /// Returns true when the key was handled (shouldIgnorePlaybackShortcutEvent: any of ⌘/Ctrl/Alt -> ignored).
    @discardableResult public func keyDown(_ k: EditorKey) -> Bool {
        if k.meta || k.ctrl || k.alt { return false }
        if let l = k.letter { pressed.insert(l) }
        switch k.code {
        case .space: togglePlay(); return true
        case .left: stepFrames(k.shift ? -10 : -1); return true
        case .right: stepFrames(k.shift ? 10 : 1); return true
        default: break
        }
        if k.isRepeat { return false }
        switch k.letter {
        case "m": audioMuted.toggle(); onChange?(); return true
        case "l" where k.shift: loopEnabled.toggle(); return true
        case "k": pause(); return true
        case "j": if pressed.contains("k") { stepFrames(-1) } else { shuttle(-1) }; return true
        case "l": if pressed.contains("k") { stepFrames(1) } else { shuttle(1) }; return true
        case "i": inPoint = k.shift ? nil : currentTime; onChange?(); return true
        case "o": outPoint = k.shift ? nil : currentTime; onChange?(); return true
        case "a": seek(inPoint ?? 0); return true
        case "e": seek(outPoint ?? duration); return true
        default: return false
        }
    }
    public func keyUp(_ k: EditorKey) { if let l = k.letter { pressed.remove(l) } }
}
