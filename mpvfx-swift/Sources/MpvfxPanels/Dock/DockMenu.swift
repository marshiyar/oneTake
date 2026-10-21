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

/// One entry of the panel menus: the macOS Window menu and every group's ⋯ menu (the only menus Linux and Windows
/// have: no menu bar there). A command palette, when one lands, lists the same entries.
public struct DockMenuItem: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Close this panel (the group menu's first entry).
        case close(DockPanelID)
        /// A Window ▸ Panels entry: open a closed panel at its last place, close an open one; a panel that cannot be
        /// closed is focused instead.
        case toggle(DockPanelID)
        /// A panel's own command (Renders: "Hide finished renders"), handled by whoever registered it.
        case extra(DockPanelID, String)
    }
    public var title: String
    public var action: Action
    public var checked: Bool
    /// The heading the entry sits under in the ⋯ menu.
    public var section: String
    public init(title: String, action: Action, checked: Bool = false, section: String) {
        self.title = title; self.action = action; self.checked = checked; self.section = section
    }

    /// A stable string for menus that key their entries by value (`PanelDropdown`).
    public var key: String {
        switch action {
        case .close(let id): return "close:\(id)"
        case .toggle(let id): return "toggle:\(id)"
        case .extra(let id, let command): return "extra:\(id):\(command)"
        }
    }
}

public enum DockMenu {
    public static let panelsSection = "Panels"
    public static let thisPanelSection = "This panel"
    public static let closeShortcut = "⌘⇧W"

    /// Every registered panel in registration order, checked when it is open.
    public static func panels(_ layout: DockLayout, _ registry: DockRegistry) -> [DockMenuItem] {
        registry.specs.map { DockMenuItem(title: $0.title, action: .toggle($0.id), checked: layout.isOpen($0.id), section: panelsSection) }
    }

    /// A group's ⋯ menu: close its visible panel (when it can be closed) and that panel's own commands, then every panel.
    public static func groupMenu(_ group: DockGroup, layout: DockLayout, registry: DockRegistry,
                                 extras: [DockMenuItem] = []) -> [DockMenuItem] {
        var items: [DockMenuItem] = []
        if registry.isClosable(group.active), registry.contains(group.active) {
            items.append(DockMenuItem(title: "Close \(registry.title(group.active))", action: .close(group.active), section: thisPanelSection))
        }
        items += extras.filter { if case .extra(let id, _) = $0.action { return id == group.active }; return false }
            .map { var e = $0; e.section = thisPanelSection; return e }
        return items + panels(layout, registry)
    }

    /// Applies a picked entry to the layout. `.extra` is the host's and changes nothing here.
    public static func apply(_ action: DockMenuItem.Action, to view: DockView) {
        switch action {
        case .close(let id):
            view.perform { try $0.close(id, registry: view.registry) }
        case .toggle(let id):
            if view.layout.isOpen(id), view.registry.isClosable(id) {
                view.perform { try $0.close(id, registry: view.registry) }
            } else {
                view.perform { try $0.open(id, registry: view.registry) }
                view.focus(id, visible: true)
            }
        case .extra:
            break
        }
    }
}
