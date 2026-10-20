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
// Native menu model:
// - Linux/Windows: NO menu bar.
// - macOS: the standard application menu
//   (App, File, Edit, View, Window), without
//   web-only items (Reload, Force Reload, Toggle Developer Tools, page zoom, Speech, Help > Learn More).
//   Quit is routed through ShellLifecycle.quitRequested() -> SaveBarrier. The editor sees a key
//   first and the menu only acts on shortcuts the editor did not handle.
public struct MenuItem: Equatable, Sendable {
    public enum Command: String, Sendable {
        case about, services, hide, hideOthers, showAll, quit
        case closeWindow
        case undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll
        case toggleFullScreen
        /// View > appearance (native addition): System / Light / Dark.
        case appearanceSystem, appearanceLight, appearanceDark
        case minimize, zoom, bringAllToFront
    }
    public var label: String, command: Command
    /// Key equivalent without modifiers ("q"); modifier set below.
    public var key: String?
    public var modifiers: Set<Modifier> = []
    /// Draw a separator above this item.
    public var separatorBefore = false
    public enum Modifier: Sendable { case command, option, shift, control }
    public init(label: String, command: Command, key: String? = nil, modifiers: Set<Modifier> = [], separatorBefore: Bool = false) {
        self.label = label; self.command = command; self.key = key; self.modifiers = modifiers; self.separatorBefore = separatorBefore
    }
}
public struct Menu: Equatable, Sendable { public var label: String, items: [MenuItem] }

public enum MenuPlatform: Sendable { case linux, windows, macOS }

public enum MenuModel {
    public static func bar(for platform: MenuPlatform, appName: String = "MpVFX") -> [Menu] {
        switch platform {
        case .linux, .windows: return []
        case .macOS:
            return [
                Menu(label: appName, items: [
                    MenuItem(label: "About \(appName)", command: .about),
                    MenuItem(label: "Services", command: .services, separatorBefore: true),
                    MenuItem(label: "Hide \(appName)", command: .hide, key: "h", modifiers: [.command], separatorBefore: true),
                    MenuItem(label: "Hide Others", command: .hideOthers, key: "h", modifiers: [.command, .option]),
                    MenuItem(label: "Show All", command: .showAll),
                    MenuItem(label: "Quit \(appName)", command: .quit, key: "q", modifiers: [.command], separatorBefore: true),
                ]),
                Menu(label: "File", items: [
                    MenuItem(label: "Close Window", command: .closeWindow, key: "w", modifiers: [.command]),
                ]),
                Menu(label: "Edit", items: [
                    MenuItem(label: "Undo", command: .undo, key: "z", modifiers: [.command]),
                    MenuItem(label: "Redo", command: .redo, key: "z", modifiers: [.command, .shift]),
                    MenuItem(label: "Cut", command: .cut, key: "x", modifiers: [.command], separatorBefore: true),
                    MenuItem(label: "Copy", command: .copy, key: "c", modifiers: [.command]),
                    MenuItem(label: "Paste", command: .paste, key: "v", modifiers: [.command]),
                    MenuItem(label: "Paste and Match Style", command: .pasteAndMatchStyle, key: "v", modifiers: [.command, .option, .shift]),
                    MenuItem(label: "Delete", command: .delete),
                    MenuItem(label: "Select All", command: .selectAll, key: "a", modifiers: [.command]),
                ]),
                Menu(label: "View", items: [
                    MenuItem(label: "Toggle Full Screen", command: .toggleFullScreen, key: "f", modifiers: [.command, .control]),
                    MenuItem(label: "System Appearance", command: .appearanceSystem, separatorBefore: true),
                    MenuItem(label: "Light Appearance", command: .appearanceLight),
                    MenuItem(label: "Dark Appearance", command: .appearanceDark),
                ]),
                Menu(label: "Window", items: [
                    MenuItem(label: "Minimize", command: .minimize, key: "m", modifiers: [.command]),
                    MenuItem(label: "Zoom", command: .zoom),
                    MenuItem(label: "Bring All to Front", command: .bringAllToFront, separatorBefore: true),
                ]),
            ]
        }
    }

    public static var current: MenuPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(Windows)
        return .windows
        #else
        return .linux
        #endif
    }
}
