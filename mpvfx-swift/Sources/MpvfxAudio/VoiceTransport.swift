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
    public enum State: Equatable { case idle, counting, recording }
    public private(set) var state: State = .idle
    public private(set) var placementSeconds = 0.0
    /// First captured sample, including measured latency (within one capture sample of the padded WAV).
    public private(set) var audiblePlacementSeconds = 0.0
    public private(set) var countdown = 0
    public var onStart: (() -> Void)?
    private var lastMeter: (peak: Float, clipped: Bool) = (0, false)
    private var deadline = 0.0
    private var recorder: VoiceRecorder?
    private var input: AudioInput?
    public var meter: (peak: Float, clipped: Bool) { recorder?.meter ?? lastMeter }
    public init() {}
    deinit { recorder?.cancel() }

    public func arm(input: AudioInput, destination: String, playhead: Double, countIn: Int, now: Double, fps: Double = 30) throws {
        guard fps.isFinite, fps >= 1, playhead.isFinite, playhead >= 0 else { throw AudioInputError.invalidState("invalid recording position or frame rate") }
        lastMeter = (0, false)
        guard state == .idle else { throw AudioInputError.invalidState("a take is already active") }
        self.input = input
        recorder = VoiceRecorder(input: input, destination: destination)
        placementSeconds = playhead
        audiblePlacementSeconds = playhead
        recorder?.leadingSilenceFrames = { [weak self, weak input] in
            guard let self, let input else { return 0 }
            let measured = input.latencySeconds
            let latency = measured.isFinite ? max(0, measured) : 0
            self.audiblePlacementSeconds = playhead + latency
            self.placementSeconds = floor(self.audiblePlacementSeconds * fps) / fps
            return Int(((self.audiblePlacementSeconds - self.placementSeconds) * Double(input.format.sampleRate)).rounded())
        }
        deadline = now + Double(max(0, min(5, countIn)))
        state = .counting
        try tick(now: now)
    }

    public func tick(now: Double) throws {
        guard state == .counting else { return }
        countdown = max(0, Int(ceil(deadline - now)))
        guard now >= deadline else { return }
        do { try recorder?.start() } catch { cancel(); throw error }
        state = .recording
        onStart?()
    }

    /// Space during count-in cancels without creating a file; Space during capture keeps it.
    public func stop() throws -> VoiceRecording? {
        guard state == .recording else { cancel(); return nil }
        defer { recorder = nil; input = nil; state = .idle }
        let result = try recorder?.stop()
        lastMeter = recorder?.meter ?? (0, false)
        return result
    }
    public func cancel() {
        recorder?.cancel(); recorder = nil; input = nil; state = .idle; countdown = 0
    }
}
