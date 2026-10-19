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
// macOS sink: the default output AudioUnit pulls interleaved float32 from a small ring buffer that
// AudioPlayback's feeder thread fills with blocking writes (the same contract as PulseAudioOutput).
#if os(macOS)
import AudioToolbox
import Foundation

public final class CoreAudioOutput: AudioOutput {
    public let format: AudioFormat
    let capacity: Int                      // ring size in frames
    let ring: UnsafeMutablePointer<Float>
    let lock = NSLock()
    var readFrame = 0, queuedFrames = 0    // ring state, in frames
    var consumed = 0                       // frames handed to the device since the last flush
    var running = false
    var unit: AudioUnit?

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
        if unit == nil { unit = try makeUnit() }
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

    func makeUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioOutputError.unavailable("no default audio output")
        }
        var instance: AudioUnit?
        var status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let u = instance else { throw AudioOutputError.unavailable("AudioComponentInstanceNew failed (\(status))") }
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
