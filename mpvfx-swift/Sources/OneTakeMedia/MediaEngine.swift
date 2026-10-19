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
// The app's Swift face of the media engine: thin adapters over the C interface in mpvfx_media.h (module CMediaEngine).
// The engine itself is a proprietary dynamic library fetched by version and SHA-256 (binaries.lock); this module is
// app code and owns no engine logic.
import CMediaEngine

public enum MediaEngine {
    /// Version string the loaded engine library reports.
    public static var version: String { String(cString: mpvfx_version()) }
}

/// A failure reported by the media engine (a negative status code plus the thread's last error message).
public struct MediaError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: Equatable, Sendable { case argument, invalidData, unsupported, io, cancelled, internalError, other(Int32) }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }

    static func kind(of status: Int32) -> Kind {
        switch status {
        case MPVFX_ERR_ARGUMENT: return .argument
        case MPVFX_ERR_INVALID_DATA: return .invalidData
        case MPVFX_ERR_UNSUPPORTED: return .unsupported
        case MPVFX_ERR_IO: return .io
        case MPVFX_ERR_CANCELLED: return .cancelled
        case MPVFX_ERR_INTERNAL: return .internalError
        default: return .other(status)
        }
    }

    /// The error for `status`, carrying the engine's message for the calling thread when it has one.
    static func fromEngine(_ status: Int32) -> MediaError {
        var text = ""
        if let raw = mpvfx_last_error() { text = String(cString: raw) }
        if text.isEmpty { text = "media engine error \(status)" }
        return MediaError(kind: kind(of: status), message: text)
    }

    /// Throws unless `status` is MPVFX_OK.
    static func check(_ status: Int32) throws {
        guard status == MPVFX_OK else { throw fromEngine(status) }
    }
}

/// Copies an engine-owned buffer into Swift memory and releases it.
func takeBuffer<T>(_ buffer: inout MpvfxBuffer, _ convert: (UnsafeBufferPointer<UInt8>) -> T) -> T {
    defer { mpvfx_buffer_free(&buffer) }
    return convert(UnsafeBufferPointer(start: buffer.data, count: buffer.data == nil ? 0 : buffer.len))
}

/// Clamps a Swift size or count to the engine's unsigned 32-bit parameters.
@inline(__always) func u32(_ value: Int) -> UInt32 { UInt32(clamping: value) }
