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

let projectsFixture: NativeJSONValue = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/projectsParity.json")
    return try! NativeJSONValue.parse(String(contentsOf: url, encoding: .utf8))
}()
func pfRows(_ k: String) -> [NativeJSONValue] { projectsFixture[k]?.arrayValue ?? [] }
func pfStr(_ v: NativeJSONValue?) -> String? { v?.stringValue }
/// Swift String cannot hold a lone UTF-16 surrogate; such fixture rows decode to U+FFFD and are skipped.
func pfHasLoneSurrogate(_ s: String) -> Bool { s.unicodeScalars.contains("\u{FFFD}") }
