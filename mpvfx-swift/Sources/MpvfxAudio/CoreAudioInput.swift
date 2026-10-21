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
// macOS capture: the HAL output unit with input enabled on bus 1 (the AUHAL pattern of Technical Note TN2091), the
// counterpart of CoreAudioOutput. The unit captures at the device's own rate and channel count into a ring buffer; the
// recorder's `read` converts to the recording format (`InputConverter`), because the input unit never resamples.
// Microphone access is checked first: without it the system delivers silence, so a refusal is reported instead.
#if os(macOS)
import AudioToolbox
import AVFoundation
import Foundation

public final class CoreAudioInput: AudioInput, AudioInputDeviceSelecting {
    public let format: AudioFormat
    private let lock = NSLock()
    private var unit: AudioUnit?
    private var deviceUID: String?
    private var running = false
    // Ring of device-rate frames: the I/O thread writes, `read` consumes.
    private var ring: UnsafeMutablePointer<Float>?
    private var ringFrames = 0, readFrame = 0, queued = 0
    private var deviceRate = 48_000, deviceChannels = 1
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchFrames = 0
    private var converter: InputConverter?
    private var renderStatus: OSStatus = noErr
    private var dropped = 0

    /// The input device's UID (`kAudioDevicePropertyDeviceUID`); nil follows the system default input.
    public var device: String? {
        get { lock.lock(); defer { lock.unlock() }; return deviceUID }
        set { lock.lock(); deviceUID = newValue; lock.unlock() }
    }

    public var droppedFrames: Int { lock.lock(); defer { lock.unlock() }; return dropped }

    public init(format: AudioFormat = AudioFormat(sampleRate: 48_000, channels: 1)) { self.format = format }
    deinit { stop() }

    // MARK: Permission

    /// Allowed, or refused with the System Settings wording. A first request waits for the person's answer.
    static func ensurePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            final class Answer: @unchecked Sendable { var granted = false }
            let answer = Answer(), done = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in answer.granted = granted; done.signal() }
            done.wait()
            if !answer.granted { throw AudioInputError.macOSPermission }
        default:
            throw AudioInputError.macOSPermission
        }
    }

    // MARK: Start and stop

    public func start() throws {
        try Self.ensurePermission()
        lock.lock()
        if running { lock.unlock(); throw AudioInputError.invalidState("the input is already started") }
        let wanted = deviceUID
        lock.unlock()
        let id: AudioDeviceID
        if let wanted {
            guard let found = Self.inputDeviceID(uid: wanted) else { throw AudioInputError.deviceNotFound(wanted) }
            id = found
        } else {
            guard let found = Self.defaultInputDeviceID() else { throw AudioInputError.noDevice }
            id = found
        }
        let au = try makeUnit(device: id)
        lock.lock(); unit = au; running = true; renderStatus = noErr; dropped = 0; lock.unlock()
        let status = AudioOutputUnitStart(au)
        if status != noErr {
            stop()
            throw AudioInputError.unavailable("AudioOutputUnitStart failed (\(status))")
        }
    }

    private func makeUnit(device id: AudioDeviceID) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw AudioInputError.unavailable("no HAL audio unit") }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let au = instance else { throw AudioInputError.unavailable("AudioComponentInstanceNew failed") }
        func fail(_ what: String, _ status: OSStatus) -> AudioInputError {
            AudioComponentInstanceDispose(au)
            return .unavailable("\(what) failed (\(status))")
        }
        var on: UInt32 = 1, off: UInt32 = 0
        let flag = UInt32(MemoryLayout<UInt32>.size)
        var status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flag)
        if status == noErr { status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flag) }
        guard status == noErr else { throw fail("enabling input", status) }
        var deviceID = id
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw fail("selecting the input device", status) }
        // The device's side of bus 1 tells the rate and channel count it delivers; the client side is set to the same
        // rate (the unit does not resample on input) as float32.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size)
        guard status == noErr, hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else { throw fail("reading the input format", status) }
        let channels = Int(hardware.mChannelsPerFrame), rate = Int(hardware.mSampleRate.rounded())
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * channels)
        var client = AudioStreamBasicDescription(mSampleRate: hardware.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                                                 mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw fail("setting the capture format", status) }
        allocateRing(rate: rate, channels: channels)
        var callback = AURenderCallbackStruct(inputProc: coreAudioInputProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if status == noErr { status = AudioUnitInitialize(au) }
        guard status == noErr else { throw fail("starting the input unit", status) }
        return au
    }

    private func allocateRing(rate: Int, channels: Int) {
        lock.lock(); defer { lock.unlock() }
        ring?.deallocate(); scratch?.deallocate()
        deviceRate = rate; deviceChannels = channels
        ringFrames = rate * 2   // two seconds: far more than the recorder ever falls behind
        ring = .allocate(capacity: ringFrames * channels); ring?.initialize(repeating: 0, count: ringFrames * channels)
        scratchFrames = 16_384
        scratch = .allocate(capacity: scratchFrames * channels); scratch?.initialize(repeating: 0, count: scratchFrames * channels)
        readFrame = 0; queued = 0
        converter = InputConverter(sourceRate: rate, sourceChannels: channels, targetRate: format.sampleRate, targetChannels: format.channels)
    }

    public func stop() {
        lock.lock()
        let au = unit; unit = nil; running = false
        lock.unlock()
        if let au {
            AudioOutputUnitStop(au)   // synchronous: no input callback runs after it returns
            AudioUnitUninitialize(au); AudioComponentInstanceDispose(au)
        }
        lock.lock(); ring?.deallocate(); ring = nil; scratch?.deallocate(); scratch = nil; queued = 0; lock.unlock()
    }

    // MARK: I/O thread

    /// Called by the input unit when `frames` new frames are ready: pull them from the device and queue them. Never
    /// waits on the recorder for long; frames that do not fit are counted as dropped.
    fileprivate func deliver(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        // The consumer holds the lock only for a copy; a few quick retries, never a wait.
        var attempts = 0
        while !lock.try() {
            attempts += 1
            if attempts > 1_000 { return noErr }
        }
        guard let au = unit, let scratch, let ring, running, Int(frames) <= scratchFrames else { lock.unlock(); return noErr }
        let channels = deviceChannels
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: frames * UInt32(MemoryLayout<Float>.size * channels), mData: scratch))
        let status = AudioUnitRender(au, flags, time, 1, frames, &list)
        if status != noErr { renderStatus = status; lock.unlock(); return status }
        let n = Int(frames), room = ringFrames - queued
        let take = min(n, room)
        dropped += n - take
        var writeFrame = (readFrame + queued) % ringFrames
        var copied = 0
        while copied < take {
            let run = min(take - copied, ringFrames - writeFrame)
            (ring + writeFrame * channels).update(from: scratch + copied * channels, count: run * channels)
            writeFrame = (writeFrame + run) % ringFrames
            copied += run
        }
        queued += take
        lock.unlock()
        return noErr
    }

    public func read(frames: Int) throws -> [Float] {
        while true {
            lock.lock()
            guard running, ring != nil else { lock.unlock(); return [] }
            if renderStatus != noErr {
                let status = renderStatus
                lock.unlock()
                throw AudioInputError.deviceError("AudioUnitRender failed (\(status))")
            }
            // Source frames that make about `frames` output frames at the target rate.
            let wanted = max(1, Int((Double(frames) * Double(deviceRate) / Double(format.sampleRate)).rounded(.up)))
            if queued >= min(wanted, ringFrames), let ring {
                let take = min(queued, wanted), channels = deviceChannels
                var block = [Float](repeating: 0, count: take * channels)
                var copied = 0
                while copied < take {
                    let run = min(take - copied, ringFrames - readFrame)
                    let from = readFrame
                    block.withUnsafeMutableBufferPointer { buffer in
                        guard let base = buffer.baseAddress else { return }
                        (base + copied * channels).update(from: ring + from * channels, count: run * channels)
                    }
                    readFrame = (readFrame + run) % ringFrames
                    copied += run
                }
                queued -= take
                var converted = converter
                lock.unlock()
                let out = converted?.process(block) ?? block
                lock.lock(); converter = converted; lock.unlock()
                if !out.isEmpty { return out }
                continue
            }
            lock.unlock()
            usleep(2_000)
        }
    }

    // MARK: Devices

    /// Input devices (those with input channels): UID and name, the system default marked.
    public static func devices() -> [AudioInputDevice] {
        let defaultID = defaultInputDeviceID()
        return CoreAudioOutput.allDeviceIDs().compactMap { id in
            guard inputChannels(id) > 0, let uid = CoreAudioOutput.stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioInputDevice(id: uid, name: CoreAudioOutput.stringProperty(id, kAudioObjectPropertyName) ?? uid, isDefault: id == defaultID)
        }
    }

    static func inputDeviceID(uid: String) -> AudioDeviceID? {
        CoreAudioOutput.allDeviceIDs().first { inputChannels($0) > 0 && CoreAudioOutput.stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 && inputChannels(id) > 0 ? id : nil
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// The input unit's callback (a C function: no captures); the unit pulls the frames from the device inside `deliver`.
private func coreAudioInputProc(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                                _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<CoreAudioInput>.fromOpaque(refCon).takeUnretainedValue().deliver(flags, time, frames)
}
#endif
