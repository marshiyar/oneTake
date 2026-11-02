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

/// UI-thread state machine; capture and WAV writes run on VoiceRecorder's worker thread.
/// The caller supplies a monotonic clock so count-in never depends on display frame rate.
public final class VoiceTransport {
    /// `preRoll` is the lead-in the transport plays before the take, heard but not recorded.
    public enum State: Equatable { case idle, counting, preRoll, recording }

    /// A punch-in: the take is exactly the frames from `start` to `end` (seconds), and playback begins `preRoll` seconds
    /// earlier. Both ends are rounded to the sequence's frames.
    public struct Punch: Equatable {
        public var start: Double, end: Double, preRoll: Double
        public init(start: Double, end: Double, preRoll: Double) { self.start = start; self.end = end; self.preRoll = preRoll }
    }
    public private(set) var state: State = .idle
    public private(set) var placementSeconds = 0.0
    /// First captured sample, including measured latency (within one capture sample of the padded WAV).
    public private(set) var audiblePlacementSeconds = 0.0
    public private(set) var countdown = 0
    public var onStart: (() -> Void)?
    private var lastMeter: (peak: Float, clipped: Bool) = (0, false)
    private var deadline = 0.0
    private var captureDeadline = 0.0
    private var punched = false
    private var lead = 0.0
    /// Where playback starts once the count-in ends: the playhead, or the punch's start less its pre-roll (never before 0).
    public private(set) var playbackStartSeconds = 0.0
    private var recorder: VoiceRecorder?
    private var input: AudioInput?
    public var meter: (peak: Float, clipped: Bool) { recorder?.meter ?? lastMeter }
    public init() {}
    deinit { recorder?.cancel() }

    /// With `punch` the take is the range only: playback runs from the pre-roll, capture starts when the range does and
    /// ends by itself when the range is full (`isComplete`), so the clip covers exactly the range.
    public func arm(input: AudioInput, destination: String, playhead: Double, countIn: Int, now: Double, fps: Double = 30,
                    punch: Punch? = nil) throws {
        guard fps.isFinite, fps >= 1, playhead.isFinite, playhead >= 0 else { throw AudioInputError.invalidState("invalid recording position or frame rate") }
        lastMeter = (0, false)
        guard state == .idle else { throw AudioInputError.invalidState("a take is already active") }
        var lead = 0.0
        self.input = input
        recorder = VoiceRecorder(input: input, destination: destination)
        if let punch {
            guard punch.start.isFinite, punch.end.isFinite, punch.preRoll.isFinite, punch.start >= 0, punch.preRoll >= 0 else {
                throw AudioInputError.invalidState("invalid punch-in range")
            }
            let first = (punch.start * fps).rounded(), last = (punch.end * fps).rounded()
            guard last > first else { throw AudioInputError.invalidState("the punch-in range holds no frames") }
            recorder?.maxFrames = Int(((last - first) / fps * Double(input.format.sampleRate)).rounded())
            lead = min(punch.preRoll, first / fps)
            placementSeconds = first / fps
            audiblePlacementSeconds = placementSeconds
            playbackStartSeconds = placementSeconds - lead
            recorder?.leadingSilenceFrames = { [weak self, weak input] in
                guard let self, let input else { return 0 }
                let measured = input.latencySeconds
                let latency = measured.isFinite ? max(0, measured) : 0
                self.audiblePlacementSeconds = self.placementSeconds + latency
                return Int((latency * Double(input.format.sampleRate)).rounded())
            }
        } else {
            placementSeconds = playhead
            audiblePlacementSeconds = playhead
            playbackStartSeconds = playhead
            armFreeTake(input: input, playhead: playhead, fps: fps)
        }
        punched = punch != nil
        deadline = now + Double(max(0, min(5, countIn)))
        self.lead = lead
        captureDeadline = deadline + lead
        state = .counting
        try tick(now: now)
    }

    private func armFreeTake(input: AudioInput, playhead: Double, fps: Double) {
        recorder?.leadingSilenceFrames = { [weak self, weak input] in
            guard let self, let input else { return 0 }
            let measured = input.latencySeconds
            let latency = measured.isFinite ? max(0, measured) : 0
            self.audiblePlacementSeconds = playhead + latency
            self.placementSeconds = floor(self.audiblePlacementSeconds * fps) / fps
            return Int(((self.audiblePlacementSeconds - self.placementSeconds) * Double(input.format.sampleRate)).rounded())
        }
    }

    /// Advances count-in and pre-roll against the caller's clock. The pre-roll plays (`onStart` has fired) but nothing is
    /// captured until it is over.
    public func tick(now: Double) throws {
        if state == .counting {
            countdown = max(0, Int(ceil(deadline - now)))
            guard now >= deadline else { return }
            if punched && lead > 0 {
                // The range starts `lead` after the transport does, counted from when it really started (this tick).
                state = .preRoll; countdown = 0
                captureDeadline = now + lead
                onStart?()
            } else {
                do { try recorder?.start() } catch { cancel(); throw error }
                state = .recording
                onStart?()
                return
            }
        }
        guard state == .preRoll, now >= captureDeadline else { return }
        do { try recorder?.start() } catch { cancel(); throw error }
        state = .recording
    }

    /// A punch-in's range is full: the transport should stop and keep the take.
    public var isComplete: Bool { state == .recording && recorder?.reachedLimit == true }

    /// Space during count-in cancels without creating a file; Space during capture keeps it.
    public func stop() throws -> VoiceRecording? {
        guard state == .recording else { cancel(); return nil }
        defer { recorder = nil; input = nil; state = .idle; punched = false }
        let result = try recorder?.stop()
        lastMeter = recorder?.meter ?? (0, false)
        return result
    }
    public func cancel() {
        recorder?.cancel(); recorder = nil; input = nil; state = .idle; countdown = 0; punched = false
    }
}
