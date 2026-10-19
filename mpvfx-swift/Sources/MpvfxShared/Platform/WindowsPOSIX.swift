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
// The few POSIX calls shared code makes that the Windows C runtime does not declare, on their Win32 equivalents.
#if os(Windows)
import Foundation

/// Suspends the calling thread for at least `microseconds` (POSIX usleep). Foundation's sleep waits on a
/// high-resolution timer, so sub-millisecond waits stay short.
@discardableResult
public func usleep(_ microseconds: UInt32) -> Int32 {
    Thread.sleep(forTimeInterval: Double(microseconds) / 1_000_000)
    return 0
}
#endif
