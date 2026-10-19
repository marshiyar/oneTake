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
import MpvfxBackend
import MpvfxDesktopCore
import OneTakeKeyframes
import MpvfxPlayer
import MpvfxShared
import MpvfxRuntime

let paths = AppPaths.resolve(env: ProcessInfo.processInfo.environment, executable: CommandLine.arguments[0])
print("[MpVFX] userData=\(paths.userData) appId=\(paths.appId)")
// Shared startup for every shell: the runtime (export checks, sidecar parsing) reads the process-wide engine.
if let error = installDefaultKeyframeEngineAtStartup() {
    FileHandle.standardError.write(Data("[MpVFX] keyframe engine failed to load: \(error)\n".utf8))
}
// Export paints every frame with the preview's composition, grade and painter, so the export matches the preview.
NativeExportFrames.defaultRenderer = PreviewExportFrames.factory
let backend = RuntimeDesktopBackend(userData: paths.userData)
Task { await backend.restoreLibraries() }   // reopen the libraries from last session
#if os(Linux)
LinuxShell.current = LinuxShell(paths: paths, backend: backend)
exit(LinuxShell.current.run())
#elseif os(Windows)
WindowsShell.current = WindowsShell(paths: paths, backend: backend)
exit(WindowsShell.current.run())
#elseif os(macOS)
MacShell.current = MacShell(paths: paths, backend: backend)
exit(MacShell.current.run())
#endif
