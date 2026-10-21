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

/// What the dock needs to know about a panel: register one with `DockRegistry.register(_:)`.
///
///     try registry.register(DockPanelSpec(id: "easing", title: "Easing", defaultDock: .right,
///                                         minSize: CanvasSize(240, 160)))
///     try registry.register(DockPanelSpec(id: "scopes", title: "Scopes", defaultDock: .right,
///                                         minSize: CanvasSize(240, 180)).preferring(CanvasSize(360, 0)))
public struct DockPanelSpec: Equatable, Sendable {
    /// Stable id, `^[a-z][a-z0-9-]{0,31}$` with single dots allowed inside (`design.style`): saved layouts refer to
    /// it, so never rename a shipped one.
    public var id: DockPanelID
    /// The tab label and the Window menu entry.
    public var title: String
    /// Where it opens the first time, and after a reset.
    public var defaultDock: DockZone
    /// Smallest content size in points (the 32 pt tab strip comes on top); splitters stop there.
    public var minSize: CanvasSize
    /// The size a splitter double-click and the default layout give it (0 on an axis: no preference).
    public var preferredSize = CanvasSize(0, 0)
    /// Preview and Timeline are not (docs: dock decision); every other panel is.
    public var closable = true
    /// The default layout leaves it closed (a Design group lives in the Design tab until it is dragged out).
    public var startsClosed = false
    public init(id: DockPanelID, title: String, defaultDock: DockZone, minSize: CanvasSize) {
        self.id = id; self.title = title; self.defaultDock = defaultDock; self.minSize = minSize
    }

    /// This spec with a preferred size.
    public func preferring(_ size: CanvasSize) -> DockPanelSpec { var s = self; s.preferredSize = size; return s }
    /// This spec, not closable.
    public func alwaysOpen() -> DockPanelSpec { var s = self; s.closable = false; return s }
    /// This spec, closed in the default layout (it still opens from the Window menu).
    public func closedByDefault() -> DockPanelSpec { var s = self; s.startsClosed = true; return s }
}

public enum DockRegistryError: Error, Equatable, CustomStringConvertible {
    case invalidID(String)
    case duplicateID(String)
    case invalidTitle(String)
    case invalidSize(String)

    public var description: String {
        switch self {
        case .invalidID(let id): return "Panel id \"\(id)\" must be 1–32 lowercase letters, digits or dashes, starting with a letter"
        case .duplicateID(let id): return "A panel with id \"\(id)\" is already registered"
        case .invalidTitle(let id): return "Panel \"\(id)\" needs a title of 1–40 characters"
        case .invalidSize(let id): return "Panel \"\(id)\" has a minimum or preferred size outside 0…4096 points"
        }
    }
}

/// The panels the dock can show, in registration order (the Window menu's order).
public struct DockRegistry: Equatable, Sendable {
    public private(set) var specs: [DockPanelSpec] = []
    public static let maxExtent = 4096.0
    public init() {}

    /// The built-in editor panels: Media, Preview, Design, Renders, Timeline, History, Info.
    public static var editor: DockRegistry {
        var r = DockRegistry()
        for spec in DockPanels.builtIn + DesignGroups.specs { r.specs.append(spec) }
        return r
    }

    public mutating func register(_ spec: DockPanelSpec) throws {
        try Self.validate(spec)
        guard self.spec(spec.id) == nil else { throw DockRegistryError.duplicateID(spec.id) }
        specs.append(spec)
    }

    public func spec(_ id: DockPanelID) -> DockPanelSpec? { specs.first { $0.id == id } }
    public func contains(_ id: DockPanelID) -> Bool { spec(id) != nil }
    public func isClosable(_ id: DockPanelID) -> Bool { spec(id)?.closable ?? true }
    public func title(_ id: DockPanelID) -> String { spec(id)?.title ?? id }

    public static func isValidID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard (1...32).contains(scalars.count), let first = scalars.first, ("a"..."z").contains(first), scalars.last != "." else { return false }
        for (i, ch) in scalars.enumerated() {
            let plain = ("a"..."z").contains(ch) || ("0"..."9").contains(ch) || ch == "-"
            if !plain && !(ch == "." && scalars[i - 1] != ".") { return false }
        }
        return true
    }

    static func validate(_ spec: DockPanelSpec) throws {
        guard isValidID(spec.id) else { throw DockRegistryError.invalidID(spec.id) }
        let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(title.count) else { throw DockRegistryError.invalidTitle(spec.id) }
        let extents = [spec.minSize.width, spec.minSize.height, spec.preferredSize.width, spec.preferredSize.height]
        guard extents.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= maxExtent }) else { throw DockRegistryError.invalidSize(spec.id) }
    }
}

/// The editor's own panels and their ids (saved in layouts: never rename).
public enum DockPanels {
    public static let media: DockPanelID = "media"
    public static let preview: DockPanelID = "preview"
    public static let inspector: DockPanelID = "inspector"
    public static let renders: DockPanelID = "renders"
    public static let timeline: DockPanelID = "timeline"
    public static let history: DockPanelID = "history"
    public static let info: DockPanelID = "info"
    public static let scopes: DockPanelID = "scopes"

    /// Minimums follow `PanelFit` (the preview's 360 × 200 floor, the 200 / 280 pt side panels, the 100 pt timeline).
    public static let builtIn: [DockPanelSpec] = [
        DockPanelSpec(id: media, title: "Media", defaultDock: .left, minSize: CanvasSize(PanelFit.minLeft, 120))
            .preferring(CanvasSize(370, 0)),
        DockPanelSpec(id: preview, title: "Preview", defaultDock: .center,
                      minSize: CanvasSize(PanelFit.minPreviewWidth, PanelFit.minPreviewHeight)).alwaysOpen(),
        DockPanelSpec(id: inspector, title: "Design", defaultDock: .right, minSize: CanvasSize(PanelFit.minRight, 120))
            .preferring(CanvasSize(409, 0)),
        DockPanelSpec(id: renders, title: "Renders", defaultDock: .right, minSize: CanvasSize(PanelFit.minRight, 120))
            .preferring(CanvasSize(409, 0)),
        DockPanelSpec(id: timeline, title: "Timeline", defaultDock: .bottom, minSize: CanvasSize(320, PanelFit.minTimelineHeight))
            .preferring(CanvasSize(0, 360)).alwaysOpen(),
        DockPanelSpec(id: history, title: "History", defaultDock: .right, minSize: CanvasSize(PanelFit.minRight, 120)),
        DockPanelSpec(id: info, title: "Info", defaultDock: .right, minSize: CanvasSize(PanelFit.minRight, 120)),
        DockPanelSpec(id: scopes, title: "Scopes", defaultDock: .right, minSize: CanvasSize(240, 180))
            .preferring(CanvasSize(360, 0)).closedByDefault(),
    ]
}
