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
import MpvfxTimeline

/// A dockable view of the composited program at the playhead. It shares the Grade scopes' background analysis and
/// drawing, but works without a selected clip. Scope choice is a user-layout preference, never a document edit.
public final class ScopesPanel: DockedPanelView {
    public static let modes: [ColorScopes.Mode] = [.waveform, .parade, .vectorscope, .histogram]
    public let layout: PanelLayoutState
    public let worker = ScopeWorker()
    public var programFrame: ((Int, Int) -> PresetPreviewState)?
    public var onChange: (() -> Void)?
    public private(set) var mode: ColorScopes.Mode
    public private(set) var status = "unavailable"
    public private(set) var focused = 0
    public private(set) var choices: [CanvasRect] = []
    private var keyboardFocus = false

    public init(layout: PanelLayoutState) {
        self.layout = layout
        mode = ColorScopes.Mode(rawValue: layout.prefs.scopePanelKind ?? "") ?? .waveform
        focused = Self.modes.firstIndex(of: mode) ?? 0
    }

    public var scopeKind: ScopeKind {
        switch mode {
        case .waveform: return .waveform
        case .parade: return .parade
        case .vectorscope: return .vectorscope
        case .histogram: return .histogram
        }
    }

    @discardableResult public func select(_ mode: ColorScopes.Mode) -> Bool {
        focused = Self.modes.firstIndex(of: mode) ?? 0
        guard self.mode != mode else { return false }
        self.mode = mode
        layout.update { $0.scopePanelKind = mode.rawValue }
        worker.reset()
        onChange?()
        return true
    }

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        DockedPanelDraw.background(c, size: size)
        let columns = size.width >= 480 ? 4 : 2, gap = 6.0, padding = 12.0
        let width = max(1, (size.width - 2 * padding - Double(columns - 1) * gap) / Double(columns))
        choices = Self.modes.indices.map { i in
            CanvasRect(x: padding + Double(i % columns) * (width + gap), y: 30 + Double(i / columns) * 28,
                       width: width, height: 24)
        }
        let top = (choices.last?.maxY ?? 30) + 10
        let tile = CanvasRect(x: padding, y: top, width: max(0, size.width - 2 * padding), height: max(0, size.height - top - padding))
        var settings = ScopeSettings()
        if !settings.kinds.contains(scopeKind) { settings.toggle(scopeKind) }
        for kind in settings.kinds where kind != scopeKind { settings.toggle(kind) }
        var result: ScopeResult?
        status = "enlarge panel"
        if tile.width >= 48, tile.height >= 40 {
            switch programFrame?(InspectorPanel.scopeFrameSide, InspectorPanel.scopeFrameSide) ?? .unavailable {
            case .ready(let frame):
                let request = InspectorPanel.scopeRequest(settings, [(scopeKind, tile)], scale: c.deviceScale)
                let current = worker.result(for: frame, request: request)
                result = current.result
                status = worker.lastFailure != nil ? "unreadable frame" : (current.current ? "ready" : "analysing")
            case .rendering: status = "loading"
            case .unavailable, .failed: status = "unavailable"
            }
            ScopeTile(kind: scopeKind, rect: tile, result: result, settings: settings).draw(c)
        }
        PanelDraw.text(c, "Program · " + status, in: CanvasRect(x: padding, y: 8, width: max(0, size.width - 2 * padding), height: 16),
                       font: PanelTheme.font(10), color: PanelTheme.text3)
        for (i, r) in choices.enumerated() {
            let selected = Self.modes[i] == mode
            PanelDraw.smallButton(c, r, label: Self.modes[i].label, fill: selected ? PanelTheme.accent.withAlpha(0.22) : PanelTheme.panelSurface,
                                  color: selected ? PanelTheme.text0 : PanelTheme.text2)
            if keyboardFocus && focused == i { c.strokeRoundedRect(r.insetBy(1), radius: 3, PanelTheme.accent, width: 1) }
        }
    }

    public func pointerDown(_ p: CanvasPoint, shift: Bool) -> Bool {
        guard let i = choices.firstIndex(where: { $0.contains(p) }) else { return false }
        keyboardFocus = false
        _ = select(Self.modes[i])
        return true
    }

    public func keyDown(_ key: EditorKey) -> Bool {
        guard !key.command && !key.alt else { return false }
        keyboardFocus = true
        switch key.code {
        case .tab:
            focused = (focused + (key.shift ? Self.modes.count - 1 : 1)) % Self.modes.count
        case .left, .up:
            focused = (focused + Self.modes.count - 1) % Self.modes.count
            _ = select(Self.modes[focused])
        case .right, .down:
            focused = (focused + 1) % Self.modes.count
            _ = select(Self.modes[focused])
        case .home: _ = select(Self.modes[0])
        case .end: _ = select(Self.modes[Self.modes.count - 1])
        case .enter, .space: _ = select(Self.modes[focused])
        default: return false
        }
        onChange?()
        return true
    }

    public var hint: String? { "Program scopes at the playhead · arrows choose a scope, Tab and Enter activate a choice" }
}
