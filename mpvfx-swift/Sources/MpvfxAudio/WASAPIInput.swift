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
// Windows capture: a WASAPI shared-mode stream on a capture endpoint (Sources/CMpvfxWin32/wasapi.cpp), the counterpart of
// WASAPIOutput. The engine converts the device's mix format to the recording format; `read` waits on the recorder's thread.
#if os(Windows)
import CMpvfxWin32
import Foundation

public final class WASAPIInput: AudioInput, AudioInputDeviceSelecting {
    public let format: AudioFormat
    /// Device buffer length: how much audio the device holds if the recorder is slow (about 200 ms).
    let bufferMs: UInt32
    private let lock = NSLock()
    /// Held for a whole read, so `stop` never frees the stream under a read that is still returning.
    private let ioLock = NSLock()
    private var stream: OpaquePointer?
    private var deviceId: String?

    /// The capture endpoint (`IMMDevice::GetId`); nil is the default endpoint. Takes effect at the next `start`.
    public var device: String? {
        get { lock.lock(); defer { lock.unlock() }; return deviceId }
        set { lock.lock(); deviceId = newValue; lock.unlock() }
    }

    public init(format: AudioFormat = AudioFormat(sampleRate: 48_000, channels: 1), bufferMs: UInt32 = 200) {
        self.format = format; self.bufferMs = bufferMs
    }
    deinit { stop() }

    public var droppedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream else { return 0 }
        var count: UInt64 = 0
        return mpvfx_wasapi_capture_discontinuities(s, &count) >= 0 ? Int(count) : 0
    }

    /// The active capture endpoints (id, friendly name, default marked); [] when none answers.
    public static func devices() -> [AudioInputDevice] {
        final class Listing { var devices: [AudioInputDevice] = [] }
        let listing = Listing()
        let hr = withExtendedLifetime(listing) {
            mpvfx_wasapi_capture_devices({ context, id, name, isDefault in
                guard let context, let id, let name else { return }
                Unmanaged<Listing>.fromOpaque(context).takeUnretainedValue().devices.append(
                    AudioInputDevice(id: String(decodingCString: id, as: UTF16.self), name: String(decodingCString: name, as: UTF16.self),
                                     isDefault: isDefault != 0))
            }, Unmanaged.passUnretained(listing).toOpaque())
        }
        return hr >= 0 ? listing.devices : []
    }

    static func hex(_ hr: Int32) -> String { "0x" + String(UInt32(bitPattern: hr), radix: 16, uppercase: true) }

    /// The typed error for a failed open or start. E_ACCESSDENIED is the privacy switch; E_NOTFOUND (also what
    /// "no endpoint" returns) is a missing device.
    static func error(_ hr: Int32, device: String?) -> AudioInputError {
        switch UInt32(bitPattern: hr) {
        case 0x8007_0005: return .windowsPermission
        case 0x8007_0490: return device.map { .deviceNotFound($0) } ?? .noDevice
        case 0x8889_000A: return .unavailable("another program is using the microphone exclusively")
        default: return .unavailable("WASAPI capture: HRESULT \(hex(hr))")
        }
    }

    public func start() throws {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { throw AudioInputError.invalidState("the input is already started") }
        var s: OpaquePointer?
        let rate = UInt32(format.sampleRate), channels = UInt32(format.channels)
        let hr: Int32
        if let id = deviceId {
            hr = id.withCString(encodedAs: UTF16.self) { mpvfx_wasapi_capture_open($0, rate, channels, bufferMs, &s) }
        } else {
            hr = mpvfx_wasapi_capture_open(nil, rate, channels, bufferMs, &s)
        }
        guard hr >= 0, let s else { throw Self.error(hr, device: deviceId) }
        let started = mpvfx_wasapi_capture_start(s)
        guard started >= 0 else { mpvfx_wasapi_capture_close(s); throw Self.error(started, device: deviceId) }
        stream = s
    }

    public func read(frames: Int) throws -> [Float] {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock(); let s = stream; lock.unlock()
        guard let s else { return [] }
        var block = [Float](repeating: 0, count: frames * format.channels)
        while true {
            var got: UInt32 = 0
            let hr = block.withUnsafeMutableBufferPointer { mpvfx_wasapi_capture_read(s, $0.baseAddress, UInt32(frames), 50, &got) }
            // AUDCLNT_E_NOT_INITIALIZED: the stream was stopped; the recorder reads it as the end.
            if hr == Int32(bitPattern: 0x8889_0001) { return [] }
            if hr < 0 { throw AudioInputError.deviceError("IAudioCaptureClient: HRESULT \(Self.hex(hr))") }
            if got > 0 { return Array(block.prefix(Int(got) * format.channels)) }
            lock.lock(); let stopped = stream == nil; lock.unlock()
            if stopped { return [] }
        }
    }

    public func stop() {
        lock.lock(); let s = stream; stream = nil; lock.unlock()
        guard let s else { return }
        _ = mpvfx_wasapi_capture_stop(s)   // a read in flight returns at its next wait
        ioLock.lock(); defer { ioLock.unlock() }
        mpvfx_wasapi_capture_close(s)
    }
}
#endif
