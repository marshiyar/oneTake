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

/// Crash-safe file persistence used by the project transaction store (syncDirectory,
/// atomicReplace). Implementations live in MpvfxDesktopCore (POSIX and Windows); MpvfxRuntime only
/// consumes the protocol.
///
/// `write`: create `tempName` (a bare file name) exclusively in the directory of `path`; with `preserveMode`
/// use the existing target's mode (0600 when the target does not exist); write and fsync `data`; call
/// `beforeRename` (an error from it aborts the write); rename over `path`; fsync the directory. The temporary
/// is removed on every failure path.
/// `syncDirectory`: fsync a directory. Callers tolerate EISDIR, EINVAL, EPERM, EACCES and ENOTSUP
/// (ProjectFSError codes), so implementations may simply throw them.
public protocol DurableWrite: Sendable {
  func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws
  func syncDirectory(_ path: String) throws
}
