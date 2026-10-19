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
// The `MPVFX_SMOKE_*` variables, parsed once for every shell. A hook read by one shell alone made macOS runs that
// passed MPVFX_SMOKE_SELECT capture a frame with nothing selected (issue #28); the shells now hand these values to
// one shared runner (`MpvfxDesktop/SmokeRunner.swift`) instead of reading the environment themselves.
import MpvfxTheme

/// Every smoke variable name. `SmokeHookParityTests` fails when a source file quotes an `MPVFX_SMOKE_` name outside
/// this file, or when a shell handles a different set of names than the others.
public enum SmokeHookName: String, CaseIterable, Sendable {
    case snapshot = "MPVFX_SMOKE_SNAPSHOT"
    case delayMS = "MPVFX_SMOKE_DELAY_MS"
    case seek = "MPVFX_SMOKE_SEEK"
    case select = "MPVFX_SMOKE_SELECT"
    case setAppearance = "MPVFX_SMOKE_SET_APPEARANCE"
    case marquee = "MPVFX_SMOKE_MARQUEE"
    case gapMenu = "MPVFX_SMOKE_GAPMENU"
    case drag = "MPVFX_SMOKE_DRAG"
    case click = "MPVFX_SMOKE_CLICK"
    case popover = "MPVFX_SMOKE_POPOVER"
    case razor = "MPVFX_SMOKE_RAZOR"
    case addMedia = "MPVFX_SMOKE_ADD_MEDIA"
    case binDrag = "MPVFX_SMOKE_BIN_DRAG"
    case fileDrop = "MPVFX_SMOKE_FILE_DROP"
    case dropPaths = "MPVFX_SMOKE_DROP_PATHS"
    case inspector = "MPVFX_SMOKE_INSPECTOR"
    case rightTab = "MPVFX_SMOKE_RIGHT_TAB"
    case export = "MPVFX_SMOKE_EXPORT"
    case audioFxStress = "MPVFX_SMOKE_AUDIOFX_STRESS"
    case audioFxSeek = "MPVFX_SMOKE_AUDIOFX_SEEK"
    case audioFxVerbose = "MPVFX_SMOKE_AUDIOFX_VERBOSE"
    case audioFxStacks = "MPVFX_SMOKE_AUDIOFX_STACKS"
    case memory = "MPVFX_SMOKE_MEMORY"
    case memoryLimitMB = "MPVFX_SMOKE_MEMORY_LIMIT_MB"
    case memoryMedia = "MPVFX_SMOKE_MEMORY_MEDIA"
    case memoryVerbose = "MPVFX_SMOKE_MEMORY_VERBOSE"
}

/// Two window points: where a press starts and where the pointer moves to.
public struct SmokeSegment: Equatable, Sendable {
    public var from: SmokePoint, to: SmokePoint
}

/// Files dropped from the file manager at a window point.
public struct SmokeFileDrop: Equatable, Sendable {
    public var at: SmokePoint
    public var paths: [String]
}

/// A point in window points (x, y), or seconds and timeline rows for `SmokeClipDrag`.
public struct SmokePoint: Equatable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// MPVFX_SMOKE_DRAG "t0,row0,t1,row1[,release[,alt]]": seconds and row positions (row 0.5 = middle of the top row).
public struct SmokeClipDrag: Equatable, Sendable {
    public var from: SmokePoint, to: SmokePoint
    /// The 5th value is 1: the pointer is released at `to`.
    public var release: Bool
    /// The 6th value: 0 no Option/Alt, 1 held (no swap onto a busy row), 2 held and let go before the release.
    public var alt: Int
}

/// MPVFX_SMOKE_BIN_DRAG "x0,y0,x1,y1[,release]": a drag through the shell router; release unless the 5th value is 0.
public struct SmokeBinDrag: Equatable, Sendable {
    public var from: SmokePoint, to: SmokePoint
    public var release: Bool
}

/// MPVFX_SMOKE_POPOVER: the transport popover a run opens.
public enum SmokePopover: String, Equatable, Sendable { case speed, volume, shortcuts }

/// The parsed smoke variables. A malformed value is treated as absent (smoke runs are developer tooling; the
/// snapshot shows the state that was not reached).
public struct SmokeHooks: Equatable, Sendable {
    /// MPVFX_SMOKE_SNAPSHOT: the PNG to write; the run opens the demo unless MPVFX_PROJECT is set, then quits.
    public var snapshotPath: String?
    /// MPVFX_SMOKE_DELAY_MS in seconds (default 1.5): time to the snapshot, or to the appearance switch without one.
    public var delay: Double = 1.5
    public var seek: Double?
    /// MPVFX_SMOKE_SELECT: a clip id ("clip:a") made the timeline selection.
    public var select: String?
    public var setAppearance: ThemeAppearance?
    /// MPVFX_SMOKE_MARQUEE "x0,y0,x1,y1": a marquee pressed at `from` and dragged to `to` on the timeline.
    public var marquee: SmokeSegment?
    /// MPVFX_SMOKE_GAPMENU "x,y": a secondary click on the timeline, hovering the menu's first items.
    public var gapMenu: SmokePoint?
    public var drag: SmokeClipDrag?
    /// MPVFX_SMOKE_CLICK "x,y": a primary click on the timeline.
    public var click: SmokePoint?
    public var popover: SmokePopover?
    /// MPVFX_SMOKE_RAZOR "x,y": the razor tool hovering at a timeline point.
    public var razor: SmokePoint?
    /// MPVFX_SMOKE_ADD_MEDIA: a bin file added at the playhead (selects the new clip).
    public var addMedia: String?
    public var binDrag: SmokeBinDrag?
    /// MPVFX_SMOKE_FILE_DROP "x,y" with MPVFX_SMOKE_DROP_PATHS (":"-separated): files dropped from the file manager.
    public var fileDrop: SmokeFileDrop?
    /// MPVFX_SMOKE_INSPECTOR "key=value;key=value": inspector rows run on the selection, in order.
    public var inspector: [SmokeInspectorRow] = []
    /// MPVFX_SMOKE_RIGHT_TAB=renders: the right panel shows the Renders tab.
    public var rightTabRenders = false
    /// MPVFX_SMOKE_EXPORT=1: Export is pressed on the Renders tab.
    public var export = false
    /// MPVFX_SMOKE_AUDIOFX_STRESS=<rounds> (+ _SEEK seconds, _VERBOSE=1, _STACKS=1 on Linux).
    public var audioFxStress: Int?
    public var audioFxSeek: Double = 0
    public var audioFxVerbose = false
    public var audioFxStacks = false
    /// MPVFX_SMOKE_MEMORY=<rounds> (+ _LIMIT_MB, default 256; _MEDIA ":"-separated; _VERBOSE=1).
    public var memoryRounds: Int?
    public var memoryLimitMB = 256
    public var memoryMedia: [String] = []
    public var memoryVerbose = false

    public init() {}

    public init(env: [String: String]) {
        func value(_ n: SmokeHookName) -> String? { env[n.rawValue] }
        func list(_ n: SmokeHookName, _ sep: Character) -> [String] { value(n).map { $0.split(separator: sep).map(String.init) } ?? [] }
        func nums(_ n: SmokeHookName) -> [Double] { list(n, ",").compactMap { Double($0) } }
        func flag(_ n: SmokeHookName) -> Bool { value(n) == "1" }
        snapshotPath = value(.snapshot)
        if let ms = value(.delayMS).flatMap(Double.init) { delay = ms / 1000 }
        seek = value(.seek).flatMap(Double.init)
        select = value(.select)
        setAppearance = value(.setAppearance).flatMap(ThemeAppearance.init(rawValue:))
        parseGestures(nums)
        popover = value(.popover).flatMap(SmokePopover.init(rawValue:))
        addMedia = value(.addMedia)
        if let at = Self.point(nums(.fileDrop), exactly: 2), let paths = value(.dropPaths) {
            fileDrop = SmokeFileDrop(at: at, paths: paths.split(separator: ":").map(String.init))
        }
        inspector = list(.inspector, ";").compactMap(SmokeInspectorRow.init)
        rightTabRenders = value(.rightTab) == "renders"
        export = flag(.export)
        audioFxStress = value(.audioFxStress).flatMap(Int.init)
        if let s = value(.audioFxSeek).flatMap(Double.init) { audioFxSeek = s }
        audioFxVerbose = flag(.audioFxVerbose); audioFxStacks = flag(.audioFxStacks)
        memoryRounds = value(.memory).flatMap(Int.init)
        if let mb = value(.memoryLimitMB).flatMap(Int.init) { memoryLimitMB = mb }
        memoryMedia = list(.memoryMedia, ":")
        memoryVerbose = flag(.memoryVerbose)
    }

    /// The comma-separated pointer hooks; each keeps the value counts the Linux shell accepted before #28.
    private mutating func parseGestures(_ nums: (SmokeHookName) -> [Double]) {
        let m = nums(.marquee)
        if m.count == 4 { marquee = SmokeSegment(from: SmokePoint(m[0], m[1]), to: SmokePoint(m[2], m[3])) }
        gapMenu = Self.point(nums(.gapMenu), exactly: nil)
        let d = nums(.drag)
        if d.count >= 4 {
            drag = SmokeClipDrag(from: SmokePoint(d[0], d[1]), to: SmokePoint(d[2], d[3]),
                                 release: d.count >= 5 && d[4] == 1, alt: d.count >= 6 ? Int(d[5]) : 0)
        }
        click = Self.point(nums(.click), exactly: nil)
        razor = Self.point(nums(.razor), exactly: 2)
        let b = nums(.binDrag)
        if b.count >= 4 {
            binDrag = SmokeBinDrag(from: SmokePoint(b[0], b[1]), to: SmokePoint(b[2], b[3]), release: b.count < 5 || b[4] != 0)
        }
    }

    /// "x,y" with at least two values, or exactly `exactly` values.
    private static func point(_ v: [Double], exactly: Int?) -> SmokePoint? {
        guard v.count >= 2, exactly.map({ v.count == $0 }) != false else { return nil }
        return SmokePoint(v[0], v[1])
    }

    /// Seconds after the window is up when the gesture hooks and the appearance switch run: after the first layout
    /// (the viewport is known) and before the snapshot; 2 s for the audio FX stress, which runs as long as it needs.
    public var gestureDelay: Double { audioFxStress != nil ? 2.0 : max(0.1, delay - 0.5) }
}

/// One "key=value" pair of MPVFX_SMOKE_INSPECTOR.
public struct SmokeInspectorRow: Equatable, Sendable {
    public var key: String, value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
    init?(_ pair: String) {
        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { return nil }
        key = kv[0]; value = kv[1]
    }
}
