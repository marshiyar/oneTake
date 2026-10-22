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
// Audition: plays one audio or video asset's sound on its own, outside the timeline. The sound is the engine's
// decode of the file (`AudioSampleReader`, the reader `StemDecoder` uses), read in blocks as the device asks, so a long
// file starts at once and holds one block in memory. A second `AudioPlayback` feeds the same output the timeline
// uses; the host pauses the timeline first and gives nothing back until the user asks.
import Foundation
import OneTakeMedia

/// Why an asset can't be auditioned, in words for the tile ("Can't play \"take3.wav\": the file is missing").
public struct AuditionError: Error, Equatable, CustomStringConvertible, Sendable {
    public let name: String
    public let reason: String
    public init(name: String, reason: String) { self.name = name; self.reason = reason }
    public var description: String { "Can't play \"\(name)\": \(reason)" }
}

/// An `AudioRenderSource` over one file: opens the engine's reader on the feeder thread at the first `seek`, then
/// reads the next block per `render`. Past the end it renders silence. Gain 1 passes the decoded samples through
/// untouched, so the output equals the stem.
final class AuditionStemSource: AudioRenderSource {
    let format: AudioFormat
    let path: String
    private let lock = NSLock()
    private var reader: AudioSampleReader?
    private var gain = 1.0, isMuted = false
    private var length: Double?
    private var failure: String?
    private var ended = false

    init(path: String, format: AudioFormat) { self.path = path; self.format = format }

    var masterGain: Double {
        get { lock.lock(); defer { lock.unlock() }; return gain }
        set { lock.lock(); gain = newValue; lock.unlock() }
    }
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isMuted }
        set { lock.lock(); isMuted = newValue; lock.unlock() }
    }
    /// The file's length in seconds once the reader is open.
    var duration: Double? { lock.lock(); defer { lock.unlock() }; return length }
    /// The engine's reason when the file could not be opened or decoded.
    var failureReason: String? { lock.lock(); defer { lock.unlock() }; return failure }
    var reachedEnd: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    func seek(_ t: Double) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, openReader() else { return }
        do { try reader?.seek(to: max(0, t)); ended = false } catch { failure = Self.reason(error) }
    }

    func render(frames: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let wanted = frames * format.channels
        var out = [Float]()
        if failure == nil, !ended, let reader {
            do {
                out = try reader.read(frames: frames)
                if out.count < wanted { ended = true }
            } catch { failure = Self.reason(error) }
        }
        if out.count < wanted { out += [Float](repeating: 0, count: wanted - out.count) }
        if isMuted { return [Float](repeating: 0, count: wanted) }
        if gain != 1 { for i in out.indices { out[i] = Float(Double(out[i]) * gain) } }
        return out
    }

    /// Opens the reader once; false (with `failure` set) when the engine refuses the file. Call with `lock` held.
    private func openReader() -> Bool {
        if reader != nil { return true }
        do {
            let probe = try MediaProbe.probe(path: path)
            guard let audio = probe.audio else { failure = "the file has no sound"; return false }
            guard audio.decodable else { failure = audio.reason ?? "its sound format isn't supported"; return false }
            let opened = try AudioSampleReader(path: path, sampleRate: format.sampleRate, channels: format.channels)
            reader = opened
            let seconds = opened.duration
            length = seconds.isFinite && seconds > 0 ? seconds : probe.duration
            return true
        } catch { failure = Self.reason(error); return false }
    }

    private static func reason(_ error: Error) -> String {
        (error as? MediaError)?.message ?? "the file can't be decoded"
    }
}

public final class AssetAuditionPlayer {
    /// What the tile shows each frame.
    public struct Status: Equatable, Sendable {
        public var assetId: String
        /// Seconds into the file, clamped to the length once it is known.
        public var position: Double
        /// The file's length in seconds; the caller's hint until the reader is open, 0 when unknown.
        public var duration: Double
        /// The sound played to its end (the player has stopped and given the device back).
        public var finished: Bool
        /// Set when the file could not be decoded (the player has stopped).
        public var error: AuditionError?
    }

    /// Seconds a ← / → press moves.
    public static let seekStep = 5.0

    private let output: AudioOutput
    private var playback: AudioPlayback?
    private var source: AuditionStemSource?
    private var assetId: String?
    private var displayName = ""
    private var durationHint = 0.0
    private var finishedAtEnd = false
    private var failed: AuditionError?

    /// `output` is the device the timeline plays on; the host stops the timeline before `start`.
    public init(output: AudioOutput) { self.output = output }

    /// The transport's volume (0...1) and mute: audition follows them, and has no effects.
    public var volume = 1.0 { didSet { source?.masterGain = volume } }
    public var muted = false { didSet { source?.muted = muted } }

    public var currentAssetId: String? { assetId }
    public var isPlaying: Bool { playback?.isPlaying == true }

    /// Starts `path` at `from` seconds, ending any audition already running. Checks the file on the calling thread
    /// (a missing or unreadable file throws `AuditionError` and nothing starts); opening the decoder happens on the
    /// audio thread, so a long file or a slow disk never holds the caller.
    public func start(assetId: String, path: String, name: String, durationHint: Double = 0, from: Double = 0) throws {
        stop()
        try Self.check(path: path, name: name)
        let stem = AuditionStemSource(path: path, format: output.format)
        stem.masterGain = volume; stem.muted = muted
        let feeder = AudioPlayback(output: output, source: stem, blockFrames: 1024)
        self.assetId = assetId; displayName = name; self.durationHint = max(0, durationHint)
        source = stem; playback = feeder; finishedAtEnd = false; failed = nil
        do { try feeder.play(from: max(0, from)) } catch {
            self.assetId = nil; source = nil; playback = nil
            throw AuditionError(name: name, reason: "the sound device isn't available")
        }
    }

    /// Ends the audition and leaves the device idle. Safe when nothing plays.
    public func stop() {
        playback?.stop()
        playback = nil; source = nil; assetId = nil; finishedAtEnd = false; failed = nil
    }

    /// Plays on from `seconds` (clamped to the file).
    public func seek(to seconds: Double) {
        guard let playback, let source else { return }
        let end = source.duration ?? (durationHint > 0 ? durationHint : nil)
        var target = max(0, seconds)
        if let end { target = min(target, max(0, end - 0.05)) }
        finishedAtEnd = false
        do { try playback.play(from: target) } catch { failed = AuditionError(name: displayName, reason: "the sound device isn't available") }
    }

    public func seek(by delta: Double) {
        guard let status = poll() else { return }
        seek(to: status.position + delta)
    }

    /// The current state, or nil when nothing is auditioned. A finished or failed audition stops itself here (the
    /// device is released) and reports that once through `finished` / `error`.
    @discardableResult
    public func poll() -> Status? {
        guard let id = assetId, let playback, let source else { return nil }
        if let failed { stop(); return Status(assetId: id, position: 0, duration: durationHint, finished: false, error: failed) }
        if let reason = source.failureReason {
            stop()
            return Status(assetId: id, position: 0, duration: durationHint, finished: false, error: AuditionError(name: displayName, reason: reason))
        }
        let length = source.duration ?? durationHint
        let position = length > 0 ? min(playback.currentTime, length) : playback.currentTime
        if length > 0, playback.currentTime >= length - 0.001, source.reachedEnd {
            stop()
            return Status(assetId: id, position: length, duration: length, finished: true, error: nil)
        }
        return Status(assetId: id, position: position, duration: length, finished: false, error: nil)
    }

    private static func check(path: String, name: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { throw AuditionError(name: name, reason: "the file is missing") }
        guard !isDirectory.boolValue else { throw AuditionError(name: name, reason: "it isn't a file") }
        guard FileManager.default.isReadableFile(atPath: path) else { throw AuditionError(name: name, reason: "the file can't be read") }
    }
}
