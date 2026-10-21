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
import MpvfxCanvas
import MpvfxTheme

/// The sequence end (docs/TIMELINE.md "Ruler and sequence end"): a marker where playback and export stop, and a shade
/// over the ruler and lanes after it, so the margin reads as outside the sequence rather than as unfinished lanes.
extension TimelineView {
    static let endFlagSize = 6.0

    /// View x of the sequence end's 1 px line (left edge, snapped like the playhead), or nil for an empty sequence.
    public var sequenceEndLineLeft: Double? {
        duration > 0 ? Self.snappedLineLeft(centre: x(for: duration)) : nil
    }

    func drawSequenceEnd(_ c: CanvasContext, size: CanvasSize) {
        typealias L = TimelineLayout
        guard let lx = sequenceEndLineLeft, lx < size.width else { return }
        let left = max(L.contentOrigin, lx + 1)
        c.withState {
            c.clip(CanvasRect(x: L.contentOrigin, y: 0, width: max(0, size.width - L.contentOrigin), height: size.height))
            c.fillRect(CanvasRect(x: left, y: 0, width: max(0, size.width - left), height: size.height),
                       CanvasColor(ThemeTokens.timelineOutOfRangePair.now))
            guard lx >= L.contentOrigin else { return }
            let marker = CanvasColor(ThemeTokens.timelineEndMarkerPair.now)
            c.fillRect(CanvasRect(x: lx, y: 0, width: 1, height: size.height), marker)
            // The flag points back into the sequence from the top of the line, like the closing corner of a bracket.
            var flag = CanvasPath()
            flag.move(to: .init(lx + 1, 0)); flag.line(to: .init(lx + 1 - Self.endFlagSize, 0))
            flag.line(to: .init(lx + 1, Self.endFlagSize)); flag.close()
            c.fill(flag, marker)
        }
    }
}
