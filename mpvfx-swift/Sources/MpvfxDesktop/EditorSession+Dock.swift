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
import MpvfxPanels
import MpvfxTimeline

extension EditorSession {
    /// Builds the window router for this session (every shell calls this): the dock with the editor's panels (Media,
    /// Preview, Design, Renders, Timeline), each panel's pane, and the saved layout from `<userData>/dock-layout.json`
    /// (the first launch seeds it from the old `panel-layout.json` sizes). Other panels register in between with
    /// `router.registerPanel(_:pane:)`; the layout is restored after the last registration, at the end.
    func installShell(userData: String, afterKey: @escaping () -> Void) -> EditorShellRouter {
        let store = FilePanelPreferencesStore(url: URL(fileURLWithPath: userData).appendingPathComponent("panel-layout.json"))
        let layout = PanelLayoutState(store: store)
        let dockStore = DockLayoutStore(userData: userData)
        let router = EditorShellRouter(layout: layout, dock: DockView(layout: DockDefaults.layout(.editor), registry: .editor))
        router.isFullscreen = { [weak self] in self?.player.view.isFullscreen ?? false }
        router.stageCursor = { [weak self] in self?.player.stageCursor ?? .arrow }
        installPreview(userData: userData)
        // Track height, zoom and the magnet persist with the UI preferences.
        let region = TimelineRegion(controller: timeline, preferences: FileTimelineUIPreferencesStore(
            url: URL(fileURLWithPath: userData).appendingPathComponent("timeline-ui.json")))
        timelineRegion = region
        region.media = makeTimelineMediaFeeder()
        installEditHistory(userData: userData)
        ensurePlayTimer = afterKey
        let ti = TimelineInput(self, region: region, afterKey: afterKey), pi = PlayerInput(self, afterKey: afterKey)
        shellInputs = [ti, pi]
        router.panes[.player] = ShellPane(input: pi) { [weak self] c, size in self?.drawPlayer(c, size: size) }
        router.panes[.timeline] = ShellPane(input: ti) { c, size in region.draw(c, size: size) }
        router.panes[.timeline]?.hint = { [weak region] in region?.hint }
        router.needsDisplay = { [weak self] in self?.redraw() }
        router.saveFailureStatus = { [weak self] in self?.saveFailureStatus }
        installPanels(router, userData: userData)
        installDocumentPanels(router)
        installSettings(router, userData: userData)
        installTimelineHooks()
        router.restoreDock(store: dockStore, seeds: Self.dockSeeds(layout.prefs))
        shell = router
        return router
    }

    /// The pre-dock panel sizes (`panel-layout.json`) as the first dock layout's shares.
    static func dockSeeds(_ p: PanelPreferences) -> DockSeeds {
        DockSeeds(leftWidth: p.leftWidth, rightWidth: p.rightWidth, bottomHeight: p.timelineHeight)
    }

    /// The side panels' hide buttons, panel menus and reveals (a new text layer, Edit Easing…) act on the dock, and
    /// the Renders panel's own command joins its group's ⋯ menu.
    func installDockedPanels(_ router: EditorShellRouter, _ p: SessionPanels) {
        router.layout.docked = { [weak router] request in router?.dockRequest(request) }
        p.left.docked = true
        router.menuExtras = [DockMenuItem(title: "Hide finished renders", action: .extra(DockPanels.renders, Self.hideFinishedCommand),
                                          section: DockMenu.thisPanelSection)]
        router.onMenuExtra = { [weak p] panel, command in
            guard panel == DockPanels.renders, command == Self.hideFinishedCommand else { return }
            p?.rendersPanel.onRender?(.hideFinished)
        }
    }

    static let hideFinishedCommand = "hide-finished"
}

extension EditorShellRouter {
    /// A side panel asked to be hidden (closed) or shown (opened at its last place and focused).
    func dockRequest(_ request: PanelLayoutState.DockedRequest) {
        switch request {
        case .hide(.left): close(DockPanels.media)
        case .hide(.right): close(DockPanels.inspector)
        case .show(.left): reveal(DockPanels.media)
        case .show(.right): reveal(DockPanels.inspector)
        case .showRightTab(let tab): reveal(tab == .design ? DockPanels.inspector : DockPanels.renders)
        }
        needsDisplay()
    }

    /// Window > Panels (macOS): every registered panel in registration order, checked when it is open.
    var windowMenuPanels: [(id: String, title: String, checked: Bool)] {
        DockMenu.panels(dock.layout, dock.registry).compactMap { item in
            guard case .toggle(let id) = item.action else { return nil }
            return (id, item.title, item.checked)
        }
    }

    /// A Window > Panels pick: opens the panel at its last place, or closes it when it is open.
    func togglePanelFromMenu(_ id: String) { run(.toggle(id)) }

    /// Window > Close Panel: closes the focused panel; false when it cannot be closed.
    @discardableResult
    func closeFocusedPanel() -> Bool {
        let closed = dock.closeFocused()
        needsDisplay()
        return closed
    }

    func close(_ panel: DockPanelID) {
        let registry = dock.registry
        dock.perform { try $0.close(panel, registry: registry) }
    }

    /// Opens a panel (at its last place) or brings it to the front of its group, and gives it the keys.
    func reveal(_ panel: DockPanelID) {
        let registry = dock.registry
        dock.perform { try $0.open(panel, registry: registry) }
        dock.focus(panel)
    }
}

extension EditorShellRouter {
    /// Adds a dockable panel and its content. Call it from `installShell` (before `restoreDock`), so its saved place
    /// is read back. A panel that no saved layout knows opens at its default dock.
    ///
    ///     try router.registerPanel(DockPanelSpec(id: "easing", title: "Easing", defaultDock: .right,
    ///                                            minSize: CanvasSize(240, 160)),
    ///                              pane: ShellPane(input: easingInput) { c, size in easing.draw(c, size: size) })
    func registerPanel(_ spec: DockPanelSpec, pane: ShellPane) throws {
        var registry = dock.registry
        try registry.register(spec)
        dock.registry = registry
        panes[.of(spec.id)] = pane
    }

    /// Reads the saved layout (else the default seeded from the old sizes), opens panels no saved layout knows at
    /// their default dock, and saves every committed change from now on.
    func restoreDock(store: DockLayoutStore, seeds: DockSeeds) {
        let registry = dock.registry
        let fallback = DockFile(workspaces: [DockFile.defaultWorkspace: DockDefaults.layout(registry, seeds: seeds)])
        var file = store.load(registry: registry, fallback: fallback)
        var layout = file.layout ?? DockDefaults.layout(registry, seeds: seeds)
        for spec in registry.specs where !layout.isOpen(spec.id) && layout.closed[spec.id] == nil {
            layout = Self.opening(spec.id, in: layout, registry: registry)
        }
        dock.setLayout(layout)
        file.workspaces[file.current] = layout
        dockFile = file
        dockStore = store
        dock.onCommit = { [weak self] next in self?.commitDock(next) }
    }

    static func opening(_ panel: DockPanelID, in layout: DockLayout, registry: DockRegistry) -> DockLayout {
        var copy = layout
        guard case .success = Result(catching: { try copy.open(panel, registry: registry) }) else { return layout }
        return copy
    }

    /// A gesture changed the layout: the current workspace keeps it, and the file is written.
    func commitDock(_ layout: DockLayout) {
        guard var file = dockFile else { return }
        file.workspaces[file.current] = layout
        dockFile = file
        dockStore?.save(file)
        needsDisplay()
    }
}
