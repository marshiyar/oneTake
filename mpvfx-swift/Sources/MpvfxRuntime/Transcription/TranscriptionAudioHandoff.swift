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
// The audio a recognizer hears: the clip's own sound over its trimmed range, decoded by the media engine
// (AudioSampleReader) to 16 kHz mono, streamed into 16-bit PCM WAV pieces of at most 50 s inside a private folder
// of the project (`.studio-render-tmp/transcribe-<uuid>/`). Each cut falls at the quietest point of the 5 s before
// the limit: inside a pause when `detectSilences` finds one there, else in the quietest 10 ms. At most one piece
// (50 s, 3.2 MB of Float) is held in memory, whatever the clip's length.
import Foundation
import OneTakeMedia
import MpvfxShared

enum TranscriptionAudioHandoff {
    static let sampleRate = 16_000
    static let maxPieceSeconds = 50
    static let cutSearchSeconds = 5
    /// The longest range one request may name (7 days): keeps every sample count and millisecond inside `Int`.
    static let maxRangeSeconds = 604_800.0
    static let folderPrefix = "transcribe-"
    static let tempFolderName = ".studio-render-tmp"

    static var maxPieceSamples: Int { maxPieceSeconds * sampleRate }

    /// Refuses a range that is negative, empty, not finite or too long, and a language tag that is empty or holds
    /// anything but letters, digits, `-` and `_`.
    static func validate(_ request: TranscriptionRequest) throws {
        guard request.sourceStart.isFinite, request.sourceStart >= 0, request.sourceStart <= maxRangeSeconds else {
            throw TranscriptionError.invalidRequest("the clip's start in its media (\(request.sourceStart) s) is out of range")
        }
        guard request.sourceDuration.isFinite, request.sourceDuration > 0, request.sourceDuration <= maxRangeSeconds else {
            throw TranscriptionError.invalidRequest("the clip's length (\(request.sourceDuration) s) is out of range")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !request.locale.isEmpty, request.locale.count <= 64,
              request.locale.unicodeScalars.allSatisfy(allowed.contains) else {
            throw TranscriptionError.invalidRequest("the language “\(request.locale)” is not a language tag")
        }
    }

    /// Creates `<project>/.studio-render-tmp/transcribe-<uuid>/` (owner-only on POSIX) and refuses a folder that a
    /// symbolic link moved outside the project.
    static func makeFolder(projectRoot: String) throws -> String {
        let root: String
        do { root = try ProjectFS.realpath(projectRoot) }
        catch { throw TranscriptionError.invalidRequest("the project folder cannot be found") }
        let folder = PosixPath.join(root, tempFolderName, folderPrefix + UUID().uuidString.lowercased())
        do {
            try ProjectFS.mkdirRecursive(PosixPath.dirname(folder))
            try makePrivateDirectory(folder)
        } catch {
            throw TranscriptionError.temporaryAudioUnwritable("\(error)")
        }
        let real: String
        do { real = try ProjectFS.realpath(folder) } catch { throw TranscriptionError.invalidRequest("the temporary folder vanished") }
        let offset = PosixPath.relative(root, real)
        if offset.isEmpty || PosixPath.isAbsolute(offset) || offset == ".." || offset.hasPrefix("../") {
            do { try FileManager.default.removeItem(atPath: folder) } catch {
                throw TranscriptionError.temporaryFilesNotRemoved(folder)
            }
            throw TranscriptionError.invalidRequest("the project's \(tempFolderName) folder points outside the project")
        }
        return real
    }

    private static func makePrivateDirectory(_ path: String) throws {
        #if os(Windows)
        try ProjectFS.mkdir(path)
        #else
        guard mkdir(path, 0o700) == 0 else { throw TranscriptionError.temporaryAudioUnwritable("mkdir \(path): errno \(errno)") }
        #endif
    }

    /// `writePieces` on a background queue, so a caller on the UI thread never waits for the decode.
    static func writePiecesOffThread(_ request: TranscriptionRequest, folder: String,
                                     cancel: MediaCancellation) async throws -> [TranscriptionPiece] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try writePieces(request, folder: folder, cancel: cancel) })
            }
        }
    }

    /// Decodes the request's range and writes it as pieces into `folder`, cancellable between engine reads.
    static func writePieces(_ request: TranscriptionRequest, folder: String, cancel: MediaCancellation) throws -> [TranscriptionPiece] {
        let reader = try openSound(request, cancel: cancel)
        let wanted = Int((request.sourceDuration * Double(sampleRate)).rounded())
        let startMs = Int((request.sourceStart * 1000).rounded(.down))
        var writer = PieceWriter(folder: folder, startMs: startMs)
        var pending: [Float] = []
        pending.reserveCapacity(maxPieceSamples)
        var read = 0, finished = false
        while !finished {
            while pending.count < maxPieceSamples && read < wanted {
                if cancel.isCancelled { throw TranscriptionError.cancelled }
                let frames = min(sampleRate, wanted - read, maxPieceSamples - pending.count)
                let chunk = try withAutoreleasePool { try engine(request) { try reader.read(frames: frames) } }
                if chunk.isEmpty { read = wanted; break }
                pending += chunk
                read += chunk.count
            }
            finished = read >= wanted
            let cut = finished ? pending.count : quietestCut(pending, sampleRate: sampleRate, searchSamples: cutSearchSeconds * sampleRate)
            if cut > 0 { try writer.write(pending[0..<cut]) }
            pending.removeFirst(cut)
        }
        return writer.pieces
    }

    /// The reader positioned at the request's start, after confining the source to the project and checking its sound.
    private static func openSound(_ request: TranscriptionRequest, cancel: MediaCancellation) throws -> AudioSampleReader {
        let probed: (path: String, probe: MediaProbe)
        do { probed = try probeProjectMedia(request.projectRoot, request.source, cancellation: cancel) }
        catch is MediaAbortError { throw TranscriptionError.cancelled }
        catch { throw TranscriptionError.mediaUnreadable(request.assetName) }
        guard let audio = probed.probe.audio else { throw TranscriptionError.noSpeechFound(request.clipName) }
        guard audio.decodable else { throw TranscriptionError.mediaUnreadable(request.assetName) }
        if let duration = probed.probe.duration, duration.isFinite, duration > 0, request.sourceStart >= duration {
            throw TranscriptionError.invalidRequest("the clip starts after the end of “\(request.assetName)”")
        }
        let reader = try engine(request) { try AudioSampleReader(path: probed.path, sampleRate: sampleRate, channels: 1) }
        try engine(request) { try reader.seek(to: request.sourceStart) }
        return reader
    }

    /// Runs one engine call, turning its error into `mediaUnreadable`.
    private static func engine<T>(_ request: TranscriptionRequest, _ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw TranscriptionError.mediaUnreadable(request.assetName) }
    }

    /// Where to end a full piece: the middle of the longest pause in the last `searchSamples`, else the middle of the
    /// quietest 10 ms window there. Always in 1 ... samples.count.
    static func quietestCut(_ samples: [Float], sampleRate: Int, searchSamples: Int) -> Int {
        let searchStart = max(0, samples.count - searchSamples)
        let window = Array(samples[searchStart...])
        let pauses = detectSilences([window], sampleRate: Double(sampleRate))
        if let longest = pauses.max(by: { $0.end - $0.start < $1.end - $1.start }) {
            let middle = Int(((longest.start + longest.end) / 2 * Double(sampleRate)).rounded())
            return min(samples.count, max(1, searchStart + middle))
        }
        let block = max(1, sampleRate / 100)
        var best = (energy: Double.infinity, at: samples.count)
        var at = 0
        while at < window.count {
            let end = min(window.count, at + block)
            var energy = 0.0
            for s in window[at..<end] where s.isFinite { energy += Double(s) * Double(s) }
            energy /= Double(end - at)
            if energy < best.energy { best = (energy, searchStart + (at + end) / 2) }
            at = end
        }
        return min(samples.count, max(1, best.at))
    }
}

/// Writes consecutive pieces and remembers them; times in source milliseconds from the sample positions, floored,
/// so one piece ends exactly where the next starts.
struct PieceWriter {
    let folder: String
    let startMs: Int
    private(set) var pieces: [TranscriptionPiece] = []
    private var nextSample = 0

    init(folder: String, startMs: Int) { self.folder = folder; self.startMs = startMs }

    mutating func write(_ samples: ArraySlice<Float>) throws {
        let rate = TranscriptionAudioHandoff.sampleRate
        let index = pieces.count
        let path = PosixPath.join(folder, String(format: "piece-%04d.wav", index))
        do { try writeWAV(samples, sampleRate: rate, to: path) }
        catch { throw TranscriptionError.temporaryAudioUnwritable("\(error)") }
        let first = nextSample, end = nextSample + samples.count
        pieces.append(TranscriptionPiece(index: index, path: path, firstSample: first, sampleCount: samples.count, sampleRate: rate,
                                         startMs: startMs + first * 1000 / rate, endMs: startMs + end * 1000 / rate))
        nextSample = end
    }
}

/// 16-bit PCM mono WAV (RIFF/WAVE, a 16-byte `fmt ` chunk, then `data`), created exclusively with mode 0600.
func writeWAV(_ samples: ArraySlice<Float>, sampleRate: Int, to path: String) throws {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(44 + samples.count * 2)
    func le32(_ v: Int) { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> shift)) } }
    func le16(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)); bytes.append(UInt8(truncatingIfNeeded: v >> 8)) }
    let dataBytes = samples.count * 2
    bytes += Array("RIFF".utf8); le32(36 + dataBytes); bytes += Array("WAVEfmt ".utf8)
    le32(16); le16(1); le16(1); le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
    bytes += Array("data".utf8); le32(dataBytes)
    for s in samples {
        let clamped = s.isFinite ? max(-1, min(1, s)) : 0
        le16(Int((Double(clamped) * 32_767).rounded()))
    }
    let file = try NativeFile.create(path, .exclusive, mode: 0o600)
    defer { file.close() }
    try bytes.withUnsafeBytes { try file.writeAll($0, path: path) }
}
