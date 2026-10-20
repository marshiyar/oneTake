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
// macOS sink: the default output AudioUnit (or, with a device chosen in Settings, a HAL output unit on that device)
// pulls interleaved float32 from a small ring buffer that AudioPlayback's feeder thread fills with blocking writes
// (the same contract as PulseAudioOutput).
#if os(macOS)
import AudioToolbox
import Foundation

public final class CoreAudioOutput: AudioOutput, AudioDeviceSelecting {
    public let format: AudioFormat
    let capacity: Int                      // ring size in frames
    let ring: UnsafeMutablePointer<Float>
    let lock = NSLock()
    var readFrame = 0, queuedFrames = 0    // ring state, in frames
    var consumed = 0                       // frames handed to the device since the last flush
    var running = false
    var unit: AudioUnit?
    var deviceUID: String?
    /// The device `unit` plays through (nil: the system default output).
    var unitDevice: String?

    /// The output device's UID (`kAudioDevicePropertyDeviceUID`, stable across reboots); nil follows the system default.
    /// A change rebuilds the unit at the next start (AudioPlayback stops the output before it starts it again).
    public var device: String? {
        get { lock.lock(); defer { lock.unlock() }; return deviceUID }
        set { lock.lock(); deviceUID = newValue; lock.unlock() }
    }

    /// `bufferFrames` bounds how far writes run ahead of the device (4096 frames = 85 ms at 48 kHz).
    public init(format: AudioFormat = .standard, bufferFrames: Int = 4096) {
        self.format = format
        capacity = max(256, bufferFrames)
        ring = .allocate(capacity: capacity * format.channels)
        ring.initialize(repeating: 0, count: capacity * format.channels)
    }

    deinit {
        stop()
        if let unit { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        ring.deallocate()
    }

    public var framesPlayed: Int { lock.lock(); defer { lock.unlock() }; return consumed }

    public func start() throws {
        let wanted = device
        if let u = unit, unitDevice != wanted {
            lock.lock(); let wasRunning = running; running = false; lock.unlock()
            if wasRunning { AudioOutputUnitStop(u) }   // synchronous: no render callback runs after it returns
            AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
            unit = nil
        }
        if unit == nil {
            // A chosen device that is gone (unplugged) plays on the default output; unitDevice stays nil, so the next
            // start asks for the chosen device again and uses it once it is back.
            if let wanted {
                do { unit = try makeUnit(device: wanted); unitDevice = wanted } catch { unit = nil }
            }
            if unit == nil { unit = try makeUnit(device: nil); unitDevice = nil }
        }
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        let status = AudioOutputUnitStart(unit!)
        if status != noErr {
            lock.lock(); running = false; lock.unlock()
            throw AudioOutputError.deviceError("AudioOutputUnitStart failed (\(status))")
        }
    }

    func makeUnit(device uid: String?) throws -> AudioUnit {
        var deviceID = AudioDeviceID(0)
        if let uid {
            guard let id = Self.deviceID(uid: uid) else { throw AudioOutputError.unavailable("audio output \(uid) is not connected") }
            deviceID = id
        }
        let subType = uid == nil ? kAudioUnitSubType_DefaultOutput : kAudioUnitSubType_HALOutput
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: subType,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioOutputError.unavailable("no default audio output")
        }
        var instance: AudioUnit?
        var status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let u = instance else { throw AudioOutputError.unavailable("AudioComponentInstanceNew failed (\(status))") }
        if let uid {
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                AudioComponentInstanceDispose(u)
                throw AudioOutputError.unavailable("audio output \(uid) could not be selected (\(status))")
            }
        }
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * format.channels)
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(format.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                                               mChannelsPerFrame: UInt32(format.channels), mBitsPerChannel: 32, mReserved: 0)
        status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                      &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status == noErr {
            var callback = AURenderCallbackStruct(inputProc: coreAudioRender, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            status = AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                          &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }
        if status == noErr { status = AudioUnitInitialize(u) }
        guard status == noErr else {
            AudioComponentInstanceDispose(u)
            throw AudioOutputError.unavailable("default output setup failed (\(status))")
        }
        return u
    }

    // MARK: Devices (Settings > Audio output)

    /// The devices with output channels, in the system's order: UID and name.
    public static func devices() -> [AudioOutputDevice] {
        allDeviceIDs().compactMap { id in
            guard outputChannels(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioOutputDevice(id: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    static func deviceID(uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { outputChannels($0) > 0 && stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return OSStatus(kAudioHardwareUnspecifiedError) }
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Render thread: copy what is queued, pad an underrun with silence (silence is not counted as played).
    /// The Core Audio I/O thread never blocks: when the feeder holds the ring lock this cycle is silence
    /// (the lock is only ever held for a ring copy, so this is rare), never a wait that could stall the device
    /// or invert priority with the UI thread (`framesPlayed`, `flush`, `stop` take the same lock).
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let ch = format.channels
        guard lock.try() else { out.update(repeating: 0, count: frames * ch); return }
        let n = min(frames, queuedFrames)
        var copied = 0
        while copied < n {
            let run = min(n - copied, capacity - readFrame)
            (out + copied * ch).update(from: ring + readFrame * ch, count: run * ch)
            readFrame = (readFrame + run) % capacity
            copied += run
        }
        queuedFrames -= n
        consumed += n
        lock.unlock()
        if n < frames { (out + n * ch).update(repeating: 0, count: (frames - n) * ch) }
    }

    public func write(_ samples: [Float]) throws {
        let ch = format.channels
        let total = samples.count / ch
        var done = 0
        try samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            while done < total {
                lock.lock()
                guard running else { lock.unlock(); throw AudioOutputError.unavailable("not started") }
                let space = capacity - queuedFrames
                if space == 0 { lock.unlock(); usleep(1000); continue }
                var n = min(space, total - done)
                var writeFrame = (readFrame + queuedFrames) % capacity
                queuedFrames += n
                while n > 0 {
                    let run = min(n, capacity - writeFrame)
                    (ring + writeFrame * ch).update(from: base + done * ch, count: run * ch)
                    writeFrame = (writeFrame + run) % capacity
                    done += run; n -= run
                }
                lock.unlock()
            }
        }
    }

    public func flush() {
        lock.lock(); readFrame = 0; queuedFrames = 0; consumed = 0; lock.unlock()
    }

    public func stop() {
        lock.lock(); let wasRunning = running; running = false; lock.unlock()
        if wasRunning, let unit { AudioOutputUnitStop(unit) }
    }
}

private let coreAudioRender: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let output = Unmanaged<CoreAudioOutput>.fromOpaque(refCon).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    guard let first = buffers.first, let data = first.mData else { return noErr }
    output.render(into: data.assumingMemoryBound(to: Float.self), frames: Int(frames))
    return noErr
}
#endif
