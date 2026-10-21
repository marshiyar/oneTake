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
public final class PulseAudioOutput: AudioOutput, AudioDeviceSelecting {
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
    var deviceName: String?

    /// The sink to play through (`pa_sink_info.name`); nil is the server's default sink.
    public var device: String? {
        get { lock.lock(); defer { lock.unlock() }; return deviceName }
        set { lock.lock(); deviceName = newValue; lock.unlock() }
    }

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
        // A chosen sink that is gone (unplugged) plays on the default sink, as the system would; Settings shows it as
        // not connected. Each start asks for the chosen sink again, so it is used as soon as it is back.
        let h = pa_simple_new(nil, appName, PA_STREAM_PLAYBACK, deviceName, "playback", &spec, nil, nil, &err)
            ?? (deviceName == nil ? nil : pa_simple_new(nil, appName, PA_STREAM_PLAYBACK, nil, "playback", &spec, nil, nil, &err))
        guard let h else { throw AudioOutputError.unavailable(String(cString: pa_strerror(err))) }
        handle = h
    }

    /// The server's sinks (name and description), asked through a short-lived context; [] when the server does not
    /// answer within `timeout` seconds.
    public static func devices(timeout: Double = 2) -> [AudioOutputDevice] {
        final class Listing { var devices: [AudioOutputDevice] = []; var done = false }
        guard let loop = pa_mainloop_new() else { return [] }
        defer { pa_mainloop_free(loop) }
        guard let ctx = pa_context_new(pa_mainloop_get_api(loop), "MpVFX") else { return [] }
        defer { pa_context_disconnect(ctx); pa_context_unref(ctx) }
        guard pa_context_connect(ctx, nil, PA_CONTEXT_NOAUTOSPAWN, nil) >= 0 else { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        // Non-blocking iterations: a server that never answers cannot hold the caller past the deadline.
        func spin() { _ = pa_mainloop_iterate(loop, 0, nil); usleep(1000) }
        while pa_context_get_state(ctx) != PA_CONTEXT_READY {
            let state = pa_context_get_state(ctx)
            if state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED || Date() > deadline { return [] }
            spin()
        }
        let listing = Listing()
        guard let op = pa_context_get_sink_info_list(ctx, { _, info, eol, user in
            guard let user else { return }
            let listing = Unmanaged<Listing>.fromOpaque(user).takeUnretainedValue()
            guard eol == 0, let info, let name = info.pointee.name else { listing.done = true; return }
            let id = String(cString: name)
            let description = info.pointee.description.map { String(cString: $0) } ?? id
            listing.devices.append(AudioOutputDevice(id: id, name: description.isEmpty ? id : description))
        }, Unmanaged.passUnretained(listing).toOpaque()) else { return [] }
        defer { pa_operation_unref(op) }
        while !listing.done && Date() <= deadline { spin() }
        return withExtendedLifetime(listing) { listing.done ? listing.devices : [] }
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
