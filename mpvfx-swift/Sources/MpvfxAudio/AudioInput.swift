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
// Microphone capture: the input side of the device sinks. An `AudioInput` hands out interleaved float32 frames from a
// capture device (PulseAudio record stream, Core Audio input unit, WASAPI capture client); `VoiceRecorder` writes them
// to a WAV file. Every way a device can fail is a case of `AudioInputError` with words for the person recording.
import Foundation

/// A capture device the system offers. `id` is what an input opens it by.
public struct AudioInputDevice: Equatable, Sendable {
    public var id: String, name: String
    /// The system's current default input.
    public var isDefault: Bool
    public init(id: String, name: String, isDefault: Bool = false) { self.id = id; self.name = name; self.isDefault = isDefault }
}

public enum AudioInputError: Error, Equatable, CustomStringConvertible, Sendable {
    /// No capture device exists (no microphone connected, or no sound server).
    case noDevice
    /// The device the person chose is gone (unplugged); the message names it.
    case deviceNotFound(String)
    /// The system refuses microphone access; the text says where to allow it.
    case permissionDenied(String)
    /// The sound system is not there or refused to open the stream.
    case unavailable(String)
    /// The stream failed while recording.
    case deviceError(String)
    /// The recording file could not be written.
    case writeFailed(path: String, reason: String)
    /// A call out of order (start twice, read before start).
    case invalidState(String)

    public var description: String {
        switch self {
        case .noDevice: return "No microphone was found. Connect one and try again."
        case .deviceNotFound(let name): return "The microphone \"\(name)\" is not connected."
        case .permissionDenied(let how): return how
        case .unavailable(let why): return "The microphone can't be opened: \(why)."
        case .deviceError(let why): return "The microphone stopped working: \(why)."
        case .writeFailed(let path, let reason): return "The recording can't be written to \(path): \(reason)."
        case .invalidState(let why): return "Recording can't do that now: \(why)."
        }
    }

    /// The macOS wording, shared so every path to a refusal says the same thing.
    public static let macOSPermission = AudioInputError.permissionDenied(
        "MpVFX can't use the microphone. Allow it in System Settings > Privacy & Security > Microphone, then try again.")
    public static let windowsPermission = AudioInputError.permissionDenied(
        "Windows is not letting MpVFX use the microphone. Allow it in Settings > Privacy & security > Microphone, then try again.")
}

/// A capture stream. `read` blocks the caller's thread (the recorder's), `stop` may come from any thread.
public protocol AudioInput: AnyObject {
    /// What `read` returns: interleaved float32 at this rate and channel count.
    var format: AudioFormat { get }
    /// Opens the device and starts capturing.
    func start() throws
    /// Up to `frames` interleaved frames, waiting until at least one is available. An empty result means the stream
    /// was stopped. Throws when the device fails.
    func read(frames: Int) throws -> [Float]
    /// Frames the device produced that nobody read in time (the ring overflowed); 0 for a healthy recording.
    var droppedFrames: Int { get }
    func stop()
}

/// An input that can record from a chosen device instead of the system default.
public protocol AudioInputDeviceSelecting: AnyObject {
    /// The device id (nil: the system default). Takes effect at the next `start`.
    var device: String? { get set }
}

public enum AudioInputDevices {
    /// The capture devices of the compiled backend, in the system's order; [] when the sound system does not answer.
    public static func list() -> [AudioInputDevice] {
        #if os(macOS)
        return CoreAudioInput.devices()
        #elseif os(Windows)
        return WASAPIInput.devices()
        #elseif canImport(CPulse)
        return PulseAudioInput.devices()
        #else
        return []
        #endif
    }

    /// The system's capture backend for this OS at the recording format; nil when none is compiled (no libpulse headers).
    public static func makeSystemInput(format: AudioFormat = AudioFormat(sampleRate: 48_000, channels: 1)) -> AudioInput? {
        #if os(macOS)
        return CoreAudioInput(format: format)
        #elseif os(Windows)
        return WASAPIInput(format: format)
        #elseif canImport(CPulse)
        return PulseAudioInput(format: format)
        #else
        return nil
        #endif
    }
}

/// A capture source for tests and headless runs: serves the frames it was given, in blocks, then ends (an empty read),
/// or fails after them when `failure` is set. Nothing waits on a clock.
public final class ScriptedAudioInput: AudioInput {
    public let format: AudioFormat
    private let lock = NSLock()
    private var samples: [Float]
    private var offset = 0
    private var started = false
    public var failure: AudioInputError?
    /// Called each time `read` hands out frames, with the running total (tests pace the recorder with it).
    public var onRead: ((Int) -> Void)?
    /// Throws this from `start` instead of starting (a missing device or a refused permission).
    public var startError: AudioInputError?
    public private(set) var droppedFrames = 0

    public init(format: AudioFormat = AudioFormat(sampleRate: 48_000, channels: 1), samples: [Float]) {
        self.format = format; self.samples = samples
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        if let startError { throw startError }
        started = true
    }

    public func read(frames: Int) throws -> [Float] {
        lock.lock()
        guard started else { lock.unlock(); throw AudioInputError.invalidState("the input is not started") }
        let want = min(frames * format.channels, samples.count - offset)
        if want <= 0 {
            let error = failure
            lock.unlock()
            if let error { throw error }
            return []
        }
        let block = Array(samples[offset..<(offset + want)])
        offset += want
        let total = offset / format.channels
        lock.unlock()
        onRead?(total)
        return block
    }

    public func stop() { lock.lock(); started = false; lock.unlock() }
}
