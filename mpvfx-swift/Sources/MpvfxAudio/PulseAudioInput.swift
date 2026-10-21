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
// Linux capture: a PulseAudio "simple" record stream (blocking reads on the recorder's thread), the counterpart of
// PulseAudioOutput. Compiled when libpulse headers exist.
#if canImport(CPulse)
import CPulse
import Foundation

public final class PulseAudioInput: AudioInput, AudioInputDeviceSelecting {
    public let format: AudioFormat
    private var handle: OpaquePointer?
    private let lock = NSLock()
    /// Held for every call that uses the stream: `pa_simple` is not safe to free while another thread is inside
    /// `pa_simple_read` (the same rule as PulseAudioOutput.ioLock). A read returns within one fragment (20 ms).
    private let ioLock = NSLock()
    private let appName: String
    private var deviceName: String?
    public private(set) var droppedFrames = 0

    /// The source to record from (`pa_source_info.name`); nil is the server's default source.
    public var device: String? {
        get { lock.lock(); defer { lock.unlock() }; return deviceName }
        set { lock.lock(); deviceName = newValue; lock.unlock() }
    }

    public init(format: AudioFormat = AudioFormat(sampleRate: 48_000, channels: 1), appName: String = "MpVFX") {
        self.format = format; self.appName = appName
    }
    deinit { stop() }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard handle == nil else { throw AudioInputError.invalidState("the input is already started") }
        var spec = pa_sample_spec(format: PA_SAMPLE_FLOAT32LE, rate: UInt32(format.sampleRate), channels: UInt8(format.channels))
        // 20 ms fragments keep a read short, so stop() never waits long on a blocked read.
        let fragment = UInt32(format.sampleRate / 50 * format.channels * MemoryLayout<Float>.size)
        var attr = pa_buffer_attr(maxlength: UInt32.max, tlength: UInt32.max, prebuf: UInt32.max, minreq: UInt32.max, fragsize: fragment)
        var err: Int32 = 0
        guard let h = pa_simple_new(nil, appName, PA_STREAM_RECORD, deviceName, "voice-over", &spec, nil, &attr, &err) else {
            throw Self.error(err, device: deviceName)
        }
        handle = h
    }

    /// The typed error for a failed `pa_simple_new`.
    static func error(_ code: Int32, device: String?) -> AudioInputError {
        let text = String(cString: pa_strerror(code))
        switch code {
        case Int32(PA_ERR_ACCESS.rawValue): return .permissionDenied("The sound server refused MpVFX access to the microphone (\(text)). Allow it in the sound settings, then try again.")
        case Int32(PA_ERR_NOENTITY.rawValue): return device.map { .deviceNotFound($0) } ?? .noDevice
        default: return .unavailable(text)
        }
    }

    public func read(frames: Int) throws -> [Float] {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock(); let h = handle; lock.unlock()
        guard let h else { return [] }
        let count = frames * format.channels
        var block = [Float](repeating: 0, count: count)
        var err: Int32 = 0
        let status = block.withUnsafeMutableBytes { pa_simple_read(h, $0.baseAddress, $0.count, &err) }
        if status < 0 {
            lock.lock(); let stopped = handle == nil; lock.unlock()
            if stopped { return [] }
            throw AudioInputError.deviceError(String(cString: pa_strerror(err)))
        }
        return block
    }

    public func stop() {
        lock.lock(); let h = handle; handle = nil; lock.unlock()
        guard let h else { return }
        ioLock.lock(); defer { ioLock.unlock() }
        pa_simple_free(h)
    }

    /// The server's sources that record (monitors of outputs are left out): name and description, the default marked;
    /// [] when the server does not answer within `timeout` seconds.
    public static func devices(timeout: Double = 2) -> [AudioInputDevice] {
        final class Listing { var devices: [AudioInputDevice] = []; var defaultName: String?; var sourcesDone = false; var serverDone = false }
        guard let loop = pa_mainloop_new() else { return [] }
        defer { pa_mainloop_free(loop) }
        guard let ctx = pa_context_new(pa_mainloop_get_api(loop), "MpVFX") else { return [] }
        defer { pa_context_disconnect(ctx); pa_context_unref(ctx) }
        guard pa_context_connect(ctx, nil, PA_CONTEXT_NOAUTOSPAWN, nil) >= 0 else { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        func spin() { _ = pa_mainloop_iterate(loop, 0, nil); usleep(1000) }
        while pa_context_get_state(ctx) != PA_CONTEXT_READY {
            let state = pa_context_get_state(ctx)
            if state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED || Date() > deadline { return [] }
            spin()
        }
        let listing = Listing()
        let user = Unmanaged.passUnretained(listing).toOpaque()
        guard let sources = pa_context_get_source_info_list(ctx, { _, info, eol, user in
            guard let user else { return }
            let listing = Unmanaged<Listing>.fromOpaque(user).takeUnretainedValue()
            guard eol == 0, let info, let name = info.pointee.name else { listing.sourcesDone = true; return }
            guard info.pointee.monitor_of_sink == UInt32.max else { return }
            let id = String(cString: name)
            let description = info.pointee.description.map { String(cString: $0) } ?? id
            listing.devices.append(AudioInputDevice(id: id, name: description.isEmpty ? id : description))
        }, user) else { return [] }
        defer { pa_operation_unref(sources) }
        guard let server = pa_context_get_server_info(ctx, { _, info, user in
            guard let user else { return }
            let listing = Unmanaged<Listing>.fromOpaque(user).takeUnretainedValue()
            listing.defaultName = info?.pointee.default_source_name.map { String(cString: $0) }
            listing.serverDone = true
        }, user) else { return [] }
        defer { pa_operation_unref(server) }
        while !(listing.sourcesDone && listing.serverDone) && Date() <= deadline { spin() }
        return withExtendedLifetime(listing) {
            guard listing.sourcesDone else { return [] }
            return listing.devices.map { AudioInputDevice(id: $0.id, name: $0.name, isDefault: $0.id == listing.defaultName) }
        }
    }
}
#endif
