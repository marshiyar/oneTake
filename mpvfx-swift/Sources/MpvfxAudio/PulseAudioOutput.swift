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
#if canImport(CPulse)
import CPulse
import Foundation

/// PulseAudio "simple" API sink (blocking writes on the feeder thread). Compiled when libpulse headers exist.
public final class PulseAudioOutput: AudioOutput {
    public let format: AudioFormat
    var handle: OpaquePointer?
    let lock = NSLock()
    /// Held for every call that uses the handle's stream (write, flush, free). pa_simple is not safe to free or
    /// flush while another thread is inside pa_simple_write on it: before this, pause/replay (stop on the UI thread)
    /// freed the handle under the feeder's in-flight write. A write blocks only while the server buffer is full,
    /// for about one block, so stop/flush wait at most that long.
    let ioLock = NSLock()
    var written = 0
    let appName: String

    public init(format: AudioFormat = .standard, appName: String = "MpVFX") { self.format = format; self.appName = appName }
    deinit { stop() }

    public var framesPlayed: Int {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return written }
        var err: Int32 = 0
        let latencyUs = pa_simple_get_latency(h, &err)
        let lat = err == 0 ? Int(Double(latencyUs) * Double(format.sampleRate) / 1_000_000) : 0
        return max(0, written - lat)
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard handle == nil else { return }
        var spec = pa_sample_spec(format: PA_SAMPLE_FLOAT32LE, rate: UInt32(format.sampleRate), channels: UInt8(format.channels))
        var err: Int32 = 0
        guard let h = pa_simple_new(nil, appName, PA_STREAM_PLAYBACK, nil, "playback", &spec, nil, nil, &err) else {
            throw AudioOutputError.unavailable(String(cString: pa_strerror(err)))
        }
        handle = h
    }

    public func write(_ samples: [Float]) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock(); let h = handle; lock.unlock()
        guard let h else { throw AudioOutputError.unavailable("not started") }
        var err: Int32 = 0
        let r = samples.withUnsafeBytes { pa_simple_write(h, $0.baseAddress, $0.count, &err) }
        if r < 0 { throw AudioOutputError.deviceError(String(cString: pa_strerror(err))) }
        lock.lock(); written += samples.count / format.channels; lock.unlock()
    }

    public func flush() {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        if let h = handle { var err: Int32 = 0; _ = pa_simple_flush(h, &err) }
        written = 0
    }

    public func stop() {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        if let h = handle { pa_simple_free(h); handle = nil }
    }
}
#endif
