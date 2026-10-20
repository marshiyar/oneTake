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
// Windows sink: a WASAPI shared-mode stream on the default render endpoint (Sources/CMpvfxWin32/wasapi.cpp):
// IAudioClient in shared mode with the engine converting float32 to the mix format, blocking writes through
// IAudioRenderClient on AudioPlayback's feeder thread, framesPlayed from IAudioClock (the same contract as
// PulseAudioOutput and CoreAudioOutput).
#if os(Windows)
import CMpvfxWin32
import Foundation

public final class WASAPIOutput: AudioOutput, AudioDeviceSelecting {
    public let format: AudioFormat
    /// Device buffer length: how far writes run ahead of the speaker (about 100 ms).
    let bufferMs: UInt32
    let lock = NSLock()
    /// Held for a whole write, so a device change never frees the stream under a write that is still returning.
    let ioLock = NSLock()
    var stream: OpaquePointer?
    var deviceId: String?
    /// The endpoint `stream` was opened on (nil: the default one).
    var streamDevice: String?

    /// The render endpoint to play through (`IMMDevice::GetId`); nil is the default endpoint. A change reopens the
    /// stream at the next start (AudioPlayback stops the output before it starts it again).
    public var device: String? {
        get { lock.lock(); defer { lock.unlock() }; return deviceId }
        set { lock.lock(); deviceId = newValue; lock.unlock() }
    }

    /// The active render endpoints (id, friendly name); [] when none answers.
    public static func devices() -> [AudioOutputDevice] {
        final class Listing { var devices: [AudioOutputDevice] = [] }
        let listing = Listing()
        let hr = withExtendedLifetime(listing) {
            mpvfx_wasapi_devices({ context, id, name in
                guard let context, let id, let name else { return }
                Unmanaged<Listing>.fromOpaque(context).takeUnretainedValue().devices.append(
                    AudioOutputDevice(id: String(decodingCString: id, as: UTF16.self), name: String(decodingCString: name, as: UTF16.self)))
            }, Unmanaged.passUnretained(listing).toOpaque())
        }
        return hr >= 0 ? listing.devices : []
    }

    public init(format: AudioFormat = .standard, bufferMs: UInt32 = 100) { self.format = format; self.bufferMs = bufferMs }
    deinit { close() }

    static func hex(_ hr: Int32) -> String { "0x" + String(UInt32(bitPattern: hr), radix: 16, uppercase: true) }

    public var framesPlayed: Int {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream else { return 0 }
        var frames: UInt64 = 0
        return mpvfx_wasapi_position(s, &frames) >= 0 ? Int(frames) : 0
    }

    /// Opens the chosen endpoint (or the default one) on the first start, and again after the choice changed;
    /// `.unavailable` when there is no endpoint at all.
    public func start() throws {
        lock.lock(); let reopen = stream != nil && streamDevice != deviceId; lock.unlock()
        if reopen {
            ioLock.lock(); lock.lock()   // the order write takes them in
            if let s = stream, streamDevice != deviceId { mpvfx_wasapi_close(s); stream = nil }
            lock.unlock(); ioLock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        if stream == nil {
            var s: OpaquePointer?
            let rate = UInt32(format.sampleRate), channels = UInt32(format.channels)
            var hr: Int32 = -1
            // A chosen endpoint that is gone (unplugged) plays on the default one; streamDevice stays nil, so the next
            // start asks for the chosen endpoint again and uses it once it is back.
            if let id = deviceId {
                hr = id.withCString(encodedAs: UTF16.self) { mpvfx_wasapi_open_device($0, rate, channels, bufferMs, &s) }
            }
            let opened = hr >= 0 ? deviceId : nil
            if hr < 0 { hr = mpvfx_wasapi_open(rate, channels, bufferMs, &s) }
            guard hr >= 0, let s else { throw AudioOutputError.unavailable("WASAPI default render endpoint: HRESULT \(Self.hex(hr))") }
            stream = s; streamDevice = opened
        }
        let hr = mpvfx_wasapi_start(stream)
        if hr < 0 { throw AudioOutputError.deviceError("IAudioClient::Start: HRESULT \(Self.hex(hr))") }
    }

    public func write(_ samples: [Float]) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock(); let s = stream; lock.unlock()
        guard let s else { throw AudioOutputError.unavailable("not started") }
        let frames = samples.count / format.channels
        let hr = samples.withUnsafeBufferPointer { mpvfx_wasapi_write(s, $0.baseAddress, UInt32(frames)) }
        // AUDCLNT_E_NOT_INITIALIZED: the stream is stopped (before start, or stop() ran during a blocked write).
        if hr == Int32(bitPattern: 0x8889_0001) { throw AudioOutputError.unavailable("not started") }
        if hr < 0 { throw AudioOutputError.deviceError("IAudioRenderClient write: HRESULT \(Self.hex(hr))") }
    }

    /// Drops what is queued and resets the clock (IAudioClient::Reset); a running stream keeps running.
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        if let s = stream { _ = mpvfx_wasapi_flush(s) }
    }

    /// Stops the stream; a blocked write returns with an error so the feeder stops. `start` resumes it.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let s = stream { _ = mpvfx_wasapi_stop(s) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if let s = stream { mpvfx_wasapi_close(s); stream = nil }
    }
}
#endif
