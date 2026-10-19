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
#if os(Linux)
import CGtk3

/// GTK is single-threaded and its loop does not drain DispatchQueue.main, so
/// work coming back from Swift tasks is posted with g_idle_add.
final class MainWork { let body: () -> Void; init(_ b: @escaping () -> Void) { body = b } }

func onMain(_ body: @escaping () -> Void) {
    let p = Unmanaged.passRetained(MainWork(body)).toOpaque()
    _ = mpvfx_idle({ data in
        Unmanaged<MainWork>.fromOpaque(data!).takeRetainedValue().body()
        return 0 // G_SOURCE_REMOVE
    }, p)
}

@inline(__always) func raw<T>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }
@inline(__always) func typed<T>(_ p: UnsafeMutableRawPointer?, _: T.Type = T.self) -> UnsafeMutablePointer<T>? {
    p?.assumingMemoryBound(to: T.self)
}
@inline(__always) func typed<T>(_ p: OpaquePointer?, _: T.Type = T.self) -> UnsafeMutablePointer<T>? {
    p.map { UnsafeMutablePointer<T>($0) }
}

@inline(__always) func raw(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }

func connect(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ cb: GCallback) {
    _ = mpvfx_connect(instance, signal, cb, nil)
}

func takeString(_ p: UnsafeMutablePointer<gchar>?) -> String? {
    guard let p else { return nil }
    defer { g_free(p) }
    return String(cString: p)
}
#endif
