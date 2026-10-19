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
// Small string helpers shared by the runtime.
import Foundation

func jsRegexTest(_ pattern: String, _ value: String, ignoreCase: Bool = false) -> Bool {
    guard let re = try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : []) else { return false }
    return re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}
func jsRegexMatch(_ pattern: String, _ value: String, ignoreCase: Bool = false) -> [String?]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : []),
          let m = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
    return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: value).map { String(value[$0]) } }
}
