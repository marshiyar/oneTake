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
// A WAV file written while it grows, valid at every checkpoint. The 44-byte header is written first with empty sizes;
// `checkpoint` makes the audio so far durable (fsync), and only then rewrites the two size fields and syncs again. A
// crash or kill at any moment leaves the sizes of the last completed checkpoint: a file a reader opens as a WAV of
// exactly that length (bytes written after it are trailing data the sizes do not cover).
import Foundation

public final class WavStreamWriter {
    public let path: String
    public let sampleRate: Int, channels: Int
    private let handle: FileHandle
    private var closed = false
    /// Frames appended so far, and frames covered by the header sizes on disk.
    public private(set) var framesWritten = 0
    public private(set) var framesCheckpointed = 0

    static let headerBytes = 44

    /// Creates `path` (it must not exist) and writes the header for an empty recording.
    public init(path: String, sampleRate: Int, channels: Int) throws {
        guard sampleRate > 0, (1...8).contains(channels) else { throw AudioInputError.writeFailed(path: path, reason: "unsupported format") }
        self.path = path; self.sampleRate = sampleRate; self.channels = channels
        guard !FileManager.default.fileExists(atPath: path) else { throw AudioInputError.writeFailed(path: path, reason: "a file with that name already exists") }
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw AudioInputError.writeFailed(path: path, reason: "the file can't be created")
        }
        do {
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: 0))
            try handle.synchronize()
        } catch { throw AudioInputError.writeFailed(path: path, reason: "\(error.localizedDescription)") }
    }

    deinit { if !closed { closeQuietly() } }

    /// Appends interleaved 16-bit samples (a whole number of frames).
    public func append(_ samples: [Int16]) throws {
        guard !closed, samples.count % channels == 0 else { throw AudioInputError.invalidState("the recording file is closed") }
        guard !samples.isEmpty else { return }
        var bytes = Data(capacity: samples.count * 2)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { bytes.append(contentsOf: $0) } }
        do { try handle.write(contentsOf: bytes) } catch { throw AudioInputError.writeFailed(path: path, reason: error.localizedDescription) }
        framesWritten += samples.count / channels
    }

    /// Makes everything appended so far part of the valid file: data first, then the sizes.
    public func checkpoint() throws {
        guard !closed else { throw AudioInputError.invalidState("the recording file is closed") }
        guard framesWritten != framesCheckpointed else { return }
        do {
            try handle.synchronize()
            let dataBytes = framesWritten * channels * 2
            // The data-chunk size goes first: a torn update still names audio that is on disk.
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: Self.le32(UInt32(truncatingIfNeeded: dataBytes)))
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Self.le32(UInt32(truncatingIfNeeded: 36 + dataBytes)))
            try handle.synchronize()
            try handle.seekToEnd()
        } catch { throw AudioInputError.writeFailed(path: path, reason: error.localizedDescription) }
        framesCheckpointed = framesWritten
    }

    /// Checkpoints and closes. The file is complete.
    public func finish() throws {
        guard !closed else { return }
        try checkpoint()
        closed = true
        do { try handle.close() } catch { throw AudioInputError.writeFailed(path: path, reason: error.localizedDescription) }
    }

    /// Closes without a final checkpoint (a failed or cancelled recording; the caller removes the file).
    public func abandon() {
        guard !closed else { return }
        closed = true
        closeQuietly()
    }

    /// The file is being given up or the writer is going away: nothing more can be done about a failed close.
    private func closeQuietly() {
        do { try handle.close() } catch { return }
    }

    static func le32(_ v: UInt32) -> Data { var d = Data(); withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }; return d }
    static func le16(_ v: UInt16) -> Data { var d = Data(); withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }; return d }

    static func header(sampleRate: Int, channels: Int, dataBytes: Int) -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(le32(UInt32(truncatingIfNeeded: 36 + dataBytes))); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(le32(16)); d.append(le16(1)); d.append(le16(UInt16(channels)))
        d.append(le32(UInt32(sampleRate))); d.append(le32(UInt32(sampleRate * channels * 2))); d.append(le16(UInt16(channels * 2))); d.append(le16(16))
        d.append(contentsOf: Array("data".utf8)); d.append(le32(UInt32(truncatingIfNeeded: dataBytes)))
        return d
    }
}
