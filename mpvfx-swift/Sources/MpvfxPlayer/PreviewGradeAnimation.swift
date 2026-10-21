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
import MpvfxColor
import MpvfxShared

/// A clip whose grade parameters are keyframed (issue #179): its grade at a frame is the effect's JSON with the
/// animated values of that frame written in (`ColorGradeParams.clipGrade(_:animated:)`). Preview and export both get
/// it through `PreviewComposition.layer(_:at:)`, so the exported frame is graded exactly as the previewed one.
///
/// Building a renderer derives its shader program and signature, so the last few are memoised by their values: a
/// paused preview redraws the same frame many times, and the decode lanes ask for the layers of nearby times.
/// Shared by copies of the composition entry; the lock makes it safe from the preview and export threads.
public final class PreviewGradeAnimation: @unchecked Sendable {
    public let parameterIds: [String]
    let projectDir: String?
    private let lock = NSLock()
    private var memo: [[String: Double]: ColorGradeRenderer?] = [:]
    static let memoLimit = 16

    init(parameterIds: [String], projectDir: String?) { self.parameterIds = parameterIds; self.projectDir = projectDir }

    /// nil when no grade parameter of the clip is keyframed (its grade is built once, as before).
    public static func forClip(_ clip: NativeProjectClip, projectDir: String?) -> PreviewGradeAnimation? {
        let ids = NativeGradeParameter.animatedIds(clip)
        return ids.isEmpty ? nil : PreviewGradeAnimation(parameterIds: ids, projectDir: projectDir)
    }

    /// The renderer for the clip at the evaluated parameter values of one frame; nil when the grade there is inactive.
    public func renderer(_ clip: NativeProjectClip, values: [String: NativeParameterValue]) -> ColorGradeRenderer? {
        var animated: [String: Double] = [:]
        for id in parameterIds { if case .number(let v)? = values[id] { animated[id] = v } }
        lock.lock()
        if let hit = memo[animated] { lock.unlock(); return hit }
        lock.unlock()
        let made = ColorGradeRenderer.forClip(ColorGradeParams.clipGrade(clip, animated: animated), clipId: clip.id, projectDir: projectDir)
        lock.lock()
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        memo[animated] = made
        lock.unlock()
        return made
    }
}
