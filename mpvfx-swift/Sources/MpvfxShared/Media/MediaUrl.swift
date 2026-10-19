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
// Media URLs: encoding a project path for a URL and decoding it back.
// Both functions exist in two forms: over UTF-16 code units (`utf16:`, throwing JSURIError where
// encodeURIComponent throws on a lone surrogate) and over String (cannot throw: a Swift String holds no
// lone surrogates).
import Foundation

/// Encode a filesystem path exactly once, at the URL boundary.
/// path.split("/").map(part => encodeURIComponent(part).replace(/'/g, "%27")).join("/")
public func encodeMediaPath(utf16 path: [UInt16]) throws -> String {
    try path.split(separator: 0x2F, omittingEmptySubsequences: false)
        .map { try jsEncodeURIComponent(utf16: Array($0)).replacingOccurrences(of: "'", with: "%27") }
        .joined(separator: "/")
}
public func encodeMediaPath(_ path: String) -> String { try! encodeMediaPath(utf16: Array(path.utf16)) }
