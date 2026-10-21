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

/// What the stage shows while Record motion is armed: a red outline round the composition and a banner that says
/// what the next press will do (or why it won't record).
public struct RecordOverlay: Equatable {
    public enum State: Equatable { case ready, blocked, recording }
    public var state: State
    public var message: String
    /// Seconds into the take (recording only).
    public var elapsed: Double
    public init(state: State, message: String, elapsed: Double = 0) { self.state = state; self.message = message; self.elapsed = elapsed }

    /// The banner's lead label: "REC 0:01.2" during a take, else "Record armed".
    public var title: String {
        guard state == .recording else { return "Record armed" }
        let t = max(0, elapsed), m = Int(t / 60), s = t - Double(m) * 60
        return "REC " + String(format: "%d:%04.1f", m, s)
    }
}
