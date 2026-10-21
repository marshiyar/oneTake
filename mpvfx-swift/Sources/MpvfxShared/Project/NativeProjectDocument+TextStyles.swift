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

extension NativeProjectDocument {
    public func isUndrawnTextStyleClip(_ clip: NativeProjectClip) -> Bool {
        clip.textStyle != nil && resolvedText(clip, textStyles ?? []) == nil
    }
    public var unsupportedTextStylesNotice: String? {
        let count =
            (textStyles ?? []).filter { !$0.isSupported }.count
            + sequence.tracks.flatMap(\.clips).filter(isUndrawnTextStyleClip).count
        return count > 0
            ? "Text styles from a newer version are kept in the project but not drawn in preview or export." : nil
    }
}
