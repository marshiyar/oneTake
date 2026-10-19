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

public final class WASAPIOutput: AudioOutput {
    public let format: AudioFormat
    /// Device buffer length: how far writes run ahead of the speaker (about 100 ms).
    let bufferMs: UInt32
    let lock = NSLock()
    var stream: OpaquePointer?

    public init(format: AudioFormat = .standard, bufferMs: UInt32 = 100) { self.format = format; self.bufferMs = bufferMs }
    deinit { close() }

    static func hex(_ hr: Int32) -> String { "0x" + String(UInt32(bitPattern: hr), radix: 16, uppercase: true) }

    public var framesPlayed: Int {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream else { return 0 }
        var frames: UInt64 = 0
        return mpvfx_wasapi_position(s, &frames) >= 0 ? Int(frames) : 0
    }

    /// Opens the default endpoint on the first start; `.unavailable` when there is none (no audio device).
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        if stream == nil {
            var s: OpaquePointer?
            let hr = mpvfx_wasapi_open(UInt32(format.sampleRate), UInt32(format.channels), bufferMs, &s)
            guard hr >= 0, let s else { throw AudioOutputError.unavailable("WASAPI default render endpoint: HRESULT \(Self.hex(hr))") }
            stream = s
        }
        let hr = mpvfx_wasapi_start(stream)
        if hr < 0 { throw AudioOutputError.deviceError("IAudioClient::Start: HRESULT \(Self.hex(hr))") }
    }

    public func write(_ samples: [Float]) throws {
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
