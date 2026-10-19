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
import Foundation
import MpvfxShared

/// Drives an `AudioOutput` from an `AudioRenderSource` (bus/FX graph or clip mixer) on a feeder thread. The audio device is the master clock:
/// `currentTime` = time at play start + framesPlayed / sampleRate. Video follows this value.
///
/// Loop (`loop`): the feeder itself wraps. The block that crosses the loop end is rendered up to the end frame and
/// continued from the loop start in the same block, so the device hears no gap and no repeat, and nothing waits on
/// the UI thread. Each wrap leaves a mark (output frame → timeline time) and `currentTime` maps the frames the
/// device has played through the marks, so the clock jumps back exactly when the wrapped sound is heard.
public final class AudioPlayback {
    public let output: AudioOutput
    public let source: AudioRenderSource
    /// The legacy clip mixer, when that is the source.
    public var mixer: AudioMixer? { source as? AudioMixer }
    public let blockFrames: Int
    let lock = NSLock()
    var originTime = 0.0
    /// Output frames (since play) at which the timeline time jumped (loop wraps), with the time it jumped to.
    var marks: [(frame: Int, time: Double)] = []
    var loop_: (start: Double, end: Double)?
    /// The loop range the feeder wraps in (seconds), or nil for straight playback. Set from any thread; the feeder
    /// reads it each block, so a change applies within one block.
    public var loop: (start: Double, end: Double)? {
        get { lock.lock(); defer { lock.unlock() }; return loop_ }
        set {
            let v = newValue.flatMap { $0.end > $0.start ? $0 : nil }
            lock.lock(); loop_ = v; lock.unlock()
            if let v { source.prepareSeek(v.start) }
        }
    }
    /// Loop wraps the feeder made since play (diagnostics and tests).
    public var wraps: Int { lock.lock(); defer { lock.unlock() }; return wraps_ }
    var wraps_ = 0
    var thread: Thread?
    var running = false
    var generation = 0
    /// Held by a feeder thread for its whole life, so a new one starts (and seeks) only after the old one has
    /// finished its last block: the two never render the source at the same time.
    let feederLock = NSLock()

    public init(output: AudioOutput, source: AudioRenderSource, blockFrames: Int = GraphAudioSource.quantum) {
        self.output = output; self.source = source; self.blockFrames = blockFrames
    }
    public convenience init(output: AudioOutput, mixer: AudioMixer, blockFrames: Int = 1024) {
        self.init(output: output, source: mixer, blockFrames: blockFrames)
    }

    public var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Clock: where the listener is, in timeline seconds.
    public var currentTime: Double {
        let played = output.framesPlayed
        lock.lock(); defer { lock.unlock() }
        var base = (frame: 0, time: originTime)
        for m in marks where m.frame <= played { base = m }
        return base.time + Double(played - base.frame) / Double(output.format.sampleRate)
    }

    /// Returns at once: the source is positioned at `t` on the feeder thread (a graph seek pre-rolls from frame 0,
    /// which can take seconds deep into an FX-heavy project and must not block the UI). Until the first block is
    /// written the device plays nothing, so `currentTime` holds at `t` and the picture waits with it.
    public func play(from t: Double) throws {
        stop()
        output.flush()
        lock.lock(); originTime = t; marks = []; wraps_ = 0; running = true; generation += 1; let gen = generation; lock.unlock()
        do { try output.start() } catch { lock.lock(); running = false; lock.unlock(); throw error }
        let source = self.source, feederLock = self.feederLock
        let th = Thread { [weak self] in
            feederLock.lock(); defer { feederLock.unlock() }
            guard self?.isCurrent(gen) == true else { return }
            source.seek(t)
            self?.feed(gen, from: t)
        }
        th.name = "mpvfx.audio"; thread = th; th.start()
    }

    /// Render one block synchronously (tests / pull-model backends).
    public func pump() throws { try output.write(source.render(frames: blockFrames)) }

    func isCurrent(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return running && gen == generation }

    func feed(_ gen: Int, from t: Double) {
        let sr = Double(output.format.sampleRate)
        var pos = Int((max(0, t) * sr).rounded())   // timeline frame of the next frame rendered
        var written = 0                               // output frames written since play
        while true {
            // One pool per block: this thread feeds the device for as long as playback runs and never returns to a
            // run loop, so anything the render path autoreleases (stem reads, Foundation buffers) would pile up.
            let more: Bool = withAutoreleasePool {
                lock.lock(); let go = running && gen == generation; let loop = loop_; lock.unlock()
                guard go else { return false }
                var block: [Float]
                if let loop {
                    let startF = Int((loop.start * sr).rounded()), endF = Int((loop.end * sr).rounded())
                    source.prepareSeek(loop.start)   // cheap when already armed; re-arms after an edit
                    block = []
                    block.reserveCapacity(blockFrames * output.format.channels)
                    var left = blockFrames
                    while left > 0 {
                        if pos >= endF {   // at the end (or a range set behind the playhead): continue from the start
                            source.seek(loop.start)
                            pos = startF
                            lock.lock()
                            marks.append((frame: written + blockFrames - left, time: Double(startF) / sr)); wraps_ += 1
                            if marks.count > 64 { marks.removeFirst(marks.count - 64) }
                            lock.unlock()
                            source.prepareSeek(loop.start)   // ready for the next wrap
                        }
                        let n = min(left, max(1, endF - pos))
                        block += source.render(frames: n)
                        pos += n; left -= n
                    }
                } else {
                    block = source.render(frames: blockFrames)
                    pos += blockFrames
                }
                do { try output.write(block) } catch { lock.lock(); running = false; lock.unlock(); return false }
                written += blockFrames
                return true
            }
            if !more { return }
        }
    }

    /// Pause keeps the clock where the listener stopped.
    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false; generation += 1
        lock.unlock()
        if wasRunning { let t = currentTime; output.stop(); output.flush(); lock.lock(); originTime = t; marks = []; lock.unlock() }
        thread = nil
    }
}
