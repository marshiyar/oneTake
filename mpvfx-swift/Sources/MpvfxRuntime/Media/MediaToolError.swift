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
// The user-facing failure of a media job (import, probe, thumbnails, waveform, silence, export); its message is
// shown as is.
import Foundation
import OneTakeMedia

public struct MediaToolError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Engine failures surface with the engine's own message (formats.md refusal texts come from there).
func mediaToolError(_ error: MediaError) -> MediaToolError { MediaToolError(error.message) }
