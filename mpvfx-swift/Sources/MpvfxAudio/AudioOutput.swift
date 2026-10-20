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
#if os(Windows)
import MpvfxShared   // usleep
#endif

/// Interleaved float32 PCM layout shared by decoder, mixer and sinks.
public struct AudioFormat: Equatable, Sendable {
    public var sampleRate: Int, channels: Int
    public init(sampleRate: Int = 48_000, channels: Int = 2) { self.sampleRate = sampleRate; self.channels = channels }
    public static let standard = AudioFormat()
}

/// Native audio sink. Backends: PulseAudio (Linux), Core Audio (macOS), WASAPI (Windows),
/// plus `NullAudioOutput` for tests/headless. `framesPlayed` is the hardware clock playback follows.
public protocol AudioOutput: AnyObject {
    var format: AudioFormat { get }
    /// Frames that have actually left the speaker (written minus device latency). Monotonic until `flush`.
    var framesPlayed: Int { get }
    func start() throws
    /// Blocks until the samples are queued (interleaved, `format.channels` per frame).
    func write(_ samples: [Float]) throws
    /// Drop queued audio and reset `framesPlayed` to 0 (seek / pause).
    func flush()
    func stop()
}

/// An output device the system offers (Settings > Audio output). `id` is what the output opens it by.
public struct AudioOutputDevice: Equatable, Sendable {
    public var id: String, name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// An output that can play through a chosen device instead of the system default.
public protocol AudioDeviceSelecting: AnyObject {
    /// The device id (nil: the system default). Takes effect the next time the output starts.
    var device: String? { get set }
}

public enum AudioOutputDevices {
    /// The output devices of the compiled sink, in the system's order; [] where choosing one is not supported (macOS
    /// and Windows play through the system default) or the sound server does not answer.
    public static func list() -> [AudioOutputDevice] {
        #if canImport(CPulse)
        return PulseAudioOutput.devices()
        #else
        return []
        #endif
    }
}

public enum AudioOutputError: Error, Equatable { case unavailable(String), deviceError(String) }

/// Test/headless sink. Nothing is played; the clock advances only through `advance(seconds:)`, so playback
/// timing is deterministic. Written samples are kept for inspection.
public final class NullAudioOutput: AudioOutput {
    public let format: AudioFormat
    let lock = NSLock()
    var queued = 0, played = 0
    public private(set) var written: [Float] = []
    public var keepSamples = true
    public private(set) var started = false
    /// Max frames queued before `write` blocks (like a device buffer). nil = never block.
    public var capacityFrames: Int?

    public init(format: AudioFormat = .standard) { self.format = format }
    public var framesPlayed: Int { lock.lock(); defer { lock.unlock() }; return played }
    public var framesQueued: Int { lock.lock(); defer { lock.unlock() }; return queued }
    public func start() throws { started = true }
    public func write(_ samples: [Float]) throws {
        let frames = samples.count / format.channels
        while let cap = capacityFrames, framesQueued - framesPlayed + frames > cap, started { usleep(500) }
        lock.lock(); queued += frames; if keepSamples { written += samples }; lock.unlock()
    }
    /// Simulate the device consuming `seconds` of queued audio.
    public func advance(seconds: Double) {
        lock.lock(); played = min(queued, played + Int((seconds * Double(format.sampleRate)).rounded())); lock.unlock()
    }
    public func flush() { lock.lock(); queued = 0; played = 0; written.removeAll(); lock.unlock() }
    public func stop() { started = false }
}

/// Headless sink that plays nothing but consumes at the wall clock, like a device: `framesPlayed` advances in
/// real time while frames are queued, and `write` blocks once `bufferFrames` are waiting. For stress tests and
/// headless runs of the app (MPVFX_AUDIO_OUTPUT=null) where no sound server exists.
public final class ClockedNullAudioOutput: AudioOutput {
    public let format: AudioFormat
    let bufferFrames: Int
    let lock = NSLock()
    var queued = 0, played = 0, running = false
    var lastTick: UInt64 = 0
    public private(set) var framesWritten = 0

    public init(format: AudioFormat = .standard, bufferFrames: Int = 4096) { self.format = format; self.bufferFrames = bufferFrames }

    /// Consume what the elapsed wall time allows (call with `lock` held).
    func advance() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard running else { lastTick = now; return }
        let due = Int(Double(now - lastTick) * Double(format.sampleRate) / 1e9)
        guard due > 0 else { return }
        lastTick = now
        played = min(queued, played + due)
    }
    public var framesPlayed: Int { lock.lock(); defer { lock.unlock() }; advance(); return played }
    public func start() throws { lock.lock(); if !running { running = true; lastTick = DispatchTime.now().uptimeNanoseconds }; lock.unlock() }
    public func write(_ samples: [Float]) throws {
        let frames = samples.count / format.channels
        while true {
            lock.lock(); advance()
            guard running else { lock.unlock(); throw AudioOutputError.unavailable("not started") }
            if queued - played + frames <= bufferFrames { queued += frames; framesWritten += frames; lock.unlock(); return }
            lock.unlock(); usleep(1000)
        }
    }
    public func flush() { lock.lock(); queued = 0; played = 0; lock.unlock() }
    public func stop() { lock.lock(); running = false; lock.unlock() }
}
