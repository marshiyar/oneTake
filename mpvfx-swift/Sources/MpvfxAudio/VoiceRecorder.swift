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
// Records an `AudioInput` to a 16-bit WAV file. The audio goes to a hidden `.recording` file beside the destination with
// a durable checkpoint every `checkpointSeconds`, so a crash leaves a valid WAV up to the last checkpoint; `stop` completes
// the file and renames it to the destination in one step, so the destination never holds half a recording.
import Foundation
import MpvfxShared

/// What a finished recording is.
public struct VoiceRecording: Equatable, Sendable {
    public var path: String
    public var frames: Int
    public var sampleRate: Int, channels: Int
    public var seconds: Double { Double(frames) / Double(max(1, sampleRate)) }
    /// Frames the device produced that were lost because the recorder fell behind.
    public var droppedFrames: Int
    /// Set when the device failed part-way: the recording holds everything captured before that.
    public var failure: AudioInputError?
}

public final class VoiceRecorder {
    public static let blockFrames = 2_400   // 50 ms at 48 kHz

    /// Optional leading silence, evaluated after opening the input so measured latency is available.
    public var leadingSilenceFrames: () -> Int = { 0 }
    private let input: AudioInput
    public let destination: String
    private let temporaryPath: String
    private let checkpointFrames: Int
    private let lock = NSLock()
    private var writer: WavStreamWriter?
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private var running = false
    private var recordedFrames = 0
    private var peak: Float = 0
    private var clipped = false
    public var meter: (peak: Float, clipped: Bool) {
        lock.lock(); defer { lock.unlock() }; return (peak, clipped)
    }
    private var captureFailure: AudioInputError?
    private var writeFailure: AudioInputError?

    /// `destination` is the WAV the finished recording appears at (its folder must exist and the name must be free).
    public init(input: AudioInput, destination: String, checkpointSeconds: Double = 1) {
        self.input = input
        self.destination = destination
        let folder = (destination as NSString).deletingLastPathComponent
        temporaryPath = (folder.isEmpty ? "." : folder) + "/." + (destination as NSString).lastPathComponent + ".recording"
        checkpointFrames = max(1, Int(checkpointSeconds * Double(input.format.sampleRate)))
    }

    /// Frames captured so far.
    public var framesRecorded: Int { lock.lock(); defer { lock.unlock() }; return recordedFrames }
    public var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return running }
    /// The error that ended capture early, if any (the recording so far is kept).
    public var failure: AudioInputError? { lock.lock(); defer { lock.unlock() }; return writeFailure ?? captureFailure }

    /// Opens the device and the file and starts recording on its own thread. Throws before anything is created when the
    /// device can't be opened (no device, permission refused, device gone).
    public func start() throws {
        lock.lock()
        guard !running, writer == nil else { lock.unlock(); throw AudioInputError.invalidState("this recorder already ran") }
        lock.unlock()
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw AudioInputError.writeFailed(path: destination, reason: "a file with that name already exists")
        }
        try input.start()
        let file: WavStreamWriter
        do { file = try WavStreamWriter(path: temporaryPath, sampleRate: input.format.sampleRate, channels: input.format.channels) }
        catch { input.stop(); throw error }
        do {
            let silence = max(0, leadingSilenceFrames())
            if silence > 0 { try file.append([Int16](repeating: 0, count: silence * input.format.channels)) }
            lock.lock(); recordedFrames = silence; writer = file; running = true; lock.unlock()
        } catch { input.stop(); file.abandon(); throw error }
        let loop = Thread { [weak self] in self?.capture(file) }
        loop.name = "mpvfx.voice-recorder"; thread = loop; loop.start()
    }

    private func capture(_ file: WavStreamWriter) {
        defer { finished.signal() }
        var sinceCheckpoint = 0
        while isRecording {
            do {
                let block: [Float] = try withAutoreleasePool { try input.read(frames: Self.blockFrames) }
                if block.isEmpty { return }
                try file.append(block.map(Self.sample))
                let frames = block.count / input.format.channels
                let level = block.filter { $0.isFinite }.map { abs($0) }.max() ?? 0
                lock.lock(); recordedFrames += frames; peak = min(1, level); clipped = clipped || level >= 1; lock.unlock()
                sinceCheckpoint += frames
                if sinceCheckpoint >= checkpointFrames { try file.checkpoint(); sinceCheckpoint = 0 }
            } catch let error as AudioInputError {
                record(error); return
            } catch {
                record(.deviceError("\(error)")); return
            }
        }
    }

    private func record(_ error: AudioInputError) {
        lock.lock(); defer { lock.unlock() }
        if case .writeFailed = error { writeFailure = error } else { captureFailure = error }
        running = false
    }

    static func sample(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(max(-32_767, min(32_767, (value * 32_767).rounded())))
    }

    /// Ends the recording and publishes it at `destination`. When the device failed part-way the file holds what was
    /// captured and `failure` says why; when the file itself could not be written this throws and leaves the
    /// `.recording` file (valid up to its last checkpoint) where it is.
    @discardableResult
    public func stop() throws -> VoiceRecording {
        lock.lock(); let file = writer; running = false; lock.unlock()
        guard let file else { throw AudioInputError.invalidState("recording has not started") }
        input.stop()
        finished.wait()
        lock.lock(); let writeError = writeFailure; let captureError = captureFailure; let frames = recordedFrames; writer = nil; lock.unlock()
        if let writeError { file.abandon(); throw writeError }
        try file.finish()
        try Self.publish(temporaryPath, as: destination)
        return VoiceRecording(path: destination, frames: frames, sampleRate: input.format.sampleRate, channels: input.format.channels,
                              droppedFrames: input.droppedFrames, failure: captureError)
    }

    /// Ends the recording and removes everything it wrote.
    public func cancel() {
        lock.lock(); let file = writer; running = false; lock.unlock()
        guard let file else { return }
        input.stop()
        finished.wait()
        file.abandon()
        lock.lock(); writer = nil; lock.unlock()
        do { try FileManager.default.removeItem(atPath: temporaryPath) } catch { return }
    }

    /// Renames the finished file into place, refusing to replace anything, and syncs the folder.
    static func publish(_ temporary: String, as destination: String) throws {
        do { try FileManager.default.moveItem(atPath: temporary, toPath: destination) }
        catch { throw AudioInputError.writeFailed(path: destination, reason: error.localizedDescription) }
        #if !os(Windows)
        let folder = (destination as NSString).deletingLastPathComponent
        let fd = open(folder.isEmpty ? "." : folder, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); _ = close(fd) }
        #endif
    }
}
