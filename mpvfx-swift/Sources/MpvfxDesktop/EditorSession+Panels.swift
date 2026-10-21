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
import MpvfxShared
import MpvfxTimeline
import MpvfxPlayer
import MpvfxPanels
import MpvfxDesktopCore

/// Host-side wiring of the side panels:
/// the left sidebar (the Media panel) gets the project's media list (DesktopBackend.listMedia), thumbnails, waveforms
/// and the library views; the Design panel's inspector edits the open document at the playhead for the current
/// selection; the Renders panel exports; context-menu and navigator commands go to the backend. They draw into
/// `shell.panes[.left]`, `[.right]` and `[.renders]`, three dock panels.
final class SessionPanels {
    unowned let session: EditorSession
    let left: LeftSidebarPanel
    /// The Design panel (the inspector) and the Renders panel: one `RightPanel` each, docked to its tab.
    let right: RightPanel
    let rendersPanel: RightPanel
    let userData: String
    /// Native file/folder dialogs (GtkDialogs / MacDialogs); library commands that need a chooser no-op without one.
    var dialogs: NativeDialogs?
    /// Bin asset drags onto the timeline / stage (EditorSession+AssetDrag.swift); the router holds it weakly.
    var assetDrag: BinAssetDrag?
    /// Puts text on the system clipboard (asset "Copy path").
    var copyToClipboard: ((String) -> Void)?
    /// Shows a file in the system file manager (render "Show in folder").
    var revealPath: ((String) -> Void)?

    /// Project media as listed by the backend (project-relative paths).
    private(set) var media: [DesktopMediaEntry] = []
    private(set) var libraryViews: [DesktopLibraryView] = []
    private var libraryTimerCancel: (() -> Void)?
    /// Renders lane state (EditorSession+Renders.swift).
    var renders = RenderQueueState()
    /// Grade preset tile thumbnails, and the composition time they show.
    private(set) var presetPreviews: PresetPreviewRenderer?
    /// Effects catalog and look tile demos on the built-in sample picture.
    private(set) var effectPreviews: EffectPreviewRenderer?
    private(set) var presetPreviewTime = 0.0
    private var panelsAnimating = false

    init(session: EditorSession, layout: PanelLayoutState, userData: String) {
        self.session = session
        self.userData = userData
        left = LeftSidebarPanel(layout: layout)
        right = RightPanel(layout: layout)
        right.dockedTab = .design
        rendersPanel = RightPanel(layout: layout)
        rendersPanel.dockedTab = .renders
        wireLeft()
        wireRight()
    }

    var backend: DesktopBackend? { session.backend }
    var projectId: String? { session.project?.id }

    func redraw() { session.redraw() }

    /// Hops to the UI thread through whatever the shell installed by the time it is called.
    var uiPost: (@escaping () -> Void) -> Void {
        { [weak session] body in session?.postToUI(body) }
    }

    private var started = false
    /// First paint: the shell has finished wiring (postToUI, schedule, dialogs), so the panels start reading.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        syncItems()
        refreshMedia()
        refreshRenders()
        startLibraryPolling()
        refreshLibraries()
        refreshRecents()
    }

    // MARK: Left sidebar

    private func wireLeft() {
        left.onChange = { [weak self] in self?.redraw() }
        left.onAnimate = { [weak self] in self?.animatePanels() }
        left.thumbnail = { [weak self] id in self?.thumbnail(id) }
        left.bars = { [weak self] id in self?.bars(id) }
        left.onImport = { [weak self] in self?.session.onImportRequested?() }
        left.onAddAtPlayhead = { [weak self] id in self?.addToTimeline(path: id, at: nil) }
        left.onRenameAsset = { [weak self] id, name in self?.renameAsset(path: id, newName: name) }
        left.onDeleteAsset = { [weak self] id, removeUsages in self?.deleteAsset(path: id, removeUsages: removeUsages) }
        left.onCopyPath = { [weak self] path in self?.copyToClipboard?(path) }
        left.onLibrary = { [weak self] cmd in self?.runLibrary(cmd) }
        left.library.available = backend?.libraries != nil
    }

    /// Re-reads the project's media (after import, rename, delete, a project switch, or an external change).
    func refreshMedia() {
        guard let backend, let projectId else { media = []; syncItems(); return }
        let post = uiPost
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listed = (try? backend.listMedia(projectId: projectId, query: nil)) ?? []
            post { guard let self, self.projectId == projectId else { return }; self.media = listed; self.syncItems(); self.redraw() }
        }
    }

    /// Bin items from the media list; "Added" follows the open document (an asset points at the file), so it
    /// updates on every edit without re-listing.
    func syncItems() {
        let used = Set(session.editor.document.assets.compactMap(\.source))
        left.items = media.map { m in
            MediaBinItem(id: m.path, name: m.name, path: m.path, category: MediaBinItem.Category(rawValue: m.category.rawValue) ?? .video,
                         duration: m.duration ?? probedDurations[m.path], used: used.contains(m.path))
        }
        probeMissingDurations()
    }

    /// Files the media manifest has no duration for are probed once (the bin's duration badge / audio row time).
    private var probedDurations: [String: Double] = [:]
    private var probing: Set<String> = []
    private func probeMissingDurations() {
        guard let backend, let projectId else { return }
        let post = uiPost
        for m in media where m.duration == nil && (m.category == .video || m.category == .audio)
            && probedDurations[m.path] == nil && !probing.contains(m.path) {
            probing.insert(m.path)
            let path = m.path
            Task { [weak self] in
                let d = (try? await backend.mediaStreams(projectId: projectId, source: path))?.duration
                post {
                    guard let self, self.projectId == projectId else { return }
                    self.probing.remove(path)
                    self.probedDurations[path] = d ?? 0
                    if let d, d > 0, let i = self.left.items.firstIndex(where: { $0.id == path }) { self.left.items[i].duration = d; self.redraw() }
                }
            }
        }
    }

    /// Duration of a bin file in seconds, from the manifest or a probe.
    func knownDuration(_ path: String) -> Double? {
        let d = media.first { $0.path == path }?.duration ?? probedDurations[path]
        return d.flatMap { $0 > 0 ? $0 : nil }
    }

    func absolutePath(_ projectRelative: String) -> String? {
        guard let dir = session.projectDir else { return nil }
        return projectRelative.hasPrefix("/") ? projectRelative : dir.appendingPathComponent(projectRelative).path
    }

    /// Bin card picture from the session's shared thumbnail service: video at 10% in (capped at 1 s), images as stills.
    func thumbnail(_ id: String) -> CanvasImage? {
        guard let entry = media.first(where: { $0.path == id }), entry.category == .video || entry.category == .images,
              let abs = absolutePath(id) else { return nil }
        let still = entry.category == .images
        let at = still ? 0 : min(1, max(0, (knownDuration(id) ?? 0) * 0.1))
        return session.mediaThumbnails.frame(path: abs, at: at, width: 320, height: 180, still: still)
    }

    /// Level bars for an audio row: the backend waveform (24 bars, AudioRow's count).
    func bars(_ id: String) -> [Double]? {
        guard let backend, let projectId, media.first(where: { $0.path == id })?.category == .audio else { return nil }
        guard let peaks = session.mediaThumbnails.waveform(backend: backend, projectId: projectId, source: id, bars: 24), !peaks.isEmpty else { return nil }
        let top = peaks.max() ?? 1
        return top > 0 ? peaks.map { $0 / top } : peaks
    }

    /// Double-click / "Add to timeline": the file becomes a document asset (if it is not one yet) and a clip at
    /// `time` (the playhead by default), as one undo step.
    func addToTimeline(path: String, at time: Double?, trackId: String? = nil) {
        guard let entry = media.first(where: { $0.path == path }) else { return }
        let kind: NativeProjectAssetKind
        switch entry.category { case .video: kind = .video; case .audio: kind = .audio; case .images: kind = .image; case .fonts: return }
        let place: (Double, NativeMediaNaturalSize?) -> Void = { [weak self] seconds, natural in
            guard let self else { return }
            let editor = self.session.editor
            let fps = editor.fps
            let frames = kind == .image ? (5 * fps).rounded() : max(1, (seconds * fps).rounded(.down))
            let before = editor.document
            let existing = before.assets.first { $0.source == path && $0.kind == kind }?.id
            if let natural, existing.map({ id in before.assets.first { $0.id == id }?.naturalSize == nil }) ?? false {
                self.session.naturalSizes[path] = natural   // an older asset without one: the session keeps it
            }
            guard let assetId = existing ?? editor.addAsset(kind: kind, name: entry.name, source: path, durationFrames: frames,
                                                            naturalSize: natural) else { return }
            let t = time ?? self.session.playback.currentTime
            guard let clipId = editor.insertClip(assetId: assetId, at: t, trackId: trackId) else {
                if existing == nil { editor.undo() }
                return
            }
            if existing == nil {
                // Fold "add asset" + "insert clip" into one undo step.
                let after = editor.document
                editor.undo(); editor.undo()
                editor.replaceDocument(after, inverse: .restoreDocument(before))
            }
            self.session.timeline.view.selection = [clipId]
            self.session.playback.duration = editor.duration
            self.session.composedDocument = nil
            self.session.syncStage(); self.syncItems(); self.redraw()
        }
        // The clip's default box needs the media's natural size (resolveDroppedAssetDimensions): known from the
        // document, the manifest or an earlier probe, else probed with the duration before the clip is placed.
        let cachedNatural = session.editor.document.assets.first { $0.source == path && $0.kind == kind }?.naturalSize
            ?? session.naturalSizes[path]
            ?? entry.width.flatMap { w in entry.height.map { NativeMediaNaturalSize(width: w, height: $0) } }.flatMap { $0.isValid ? $0 : nil }
        let needsNatural = kind != .audio && cachedNatural == nil
        let duration = kind == .image ? 5 : knownDuration(path)
        if let duration, !needsNatural { place(duration, cachedNatural); return }
        guard let backend, let projectId else { if let duration { place(duration, nil) }; return }
        let post = uiPost
        Task { [weak self] in
            do {
                let s = try await backend.mediaStreams(projectId: projectId, source: path)
                post { place(duration ?? s.duration, cachedNatural ?? s.naturalSize) }
            } catch {
                // An image the media engine cannot probe still goes on the timeline (full frame, as for any media without a size).
                if let duration { post { place(duration, nil) } }
                else { post { self?.session.onError("Could not add media", "\(error)") } }
            }
        }
    }

    /// AssetContextMenu rename: the file is renamed in place (same folder) and the document's assets follow it.
    func renameAsset(path: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(".."), trimmed != (path as NSString).lastPathComponent else {
            if trimmed.contains("/") || trimmed.contains("..") { session.onError("Could not rename", "Name can't contain / or ..") }
            return
        }
        let dir = path.contains("/") ? String(path[...path.lastIndex(of: "/")!]) : ""
        do {
            try session.renameMedia(path, to: dir + trimmed)
            if let abs = absolutePath(path) { session.mediaThumbnails.forget(path: abs) }
            session.mediaThumbnails.forget(source: path)
            refreshMedia()
        } catch { session.onError("Could not rename", "\(error)") }
    }

    /// AssetContextMenu delete: the file goes to the recovery folder; with "remove placements" its clips go too.
    func deleteAsset(path: String, removeUsages: Bool) {
        do {
            try session.deleteMedia(path, removeUsages: removeUsages)
            if let abs = absolutePath(path) { session.mediaThumbnails.forget(path: abs) }
            session.mediaThumbnails.forget(source: path)
            refreshMedia()
        } catch { session.onError("Could not delete", "\(error)") }
    }

    // MARK: Libraries

    /// Re-reads the libraries (the navigator polls every 3 s).
    func refreshLibraries() {
        guard let backend, backend.libraries != nil else { left.library.available = false; return }
        let post = uiPost
        let directory = session.project?.directory
        Task { [weak self] in
            let views = (try? await backend.libraryViews()) ?? []
            let currentLibraryProject = directory.flatMap { dir in backend.listProjects().first { $0.directory == dir }?.libraryProjectId }
            post { self?.applyLibraries(views, currentProjectId: currentLibraryProject) }
        }
    }

    func applyLibraries(_ views: [DesktopLibraryView], currentProjectId: String?) {
        libraryViews = views
        var model = left.library
        model.available = backend?.libraries != nil
        model.currentProjectId = currentProjectId
        model.isStandalone = currentProjectId == nil
        model.libraries = views.map { v in
            LibraryNavModel.Library(id: v.id, name: v.name,
                events: v.events.map { .init(id: $0.id, name: $0.name) },
                projects: v.projects.filter(\.ready).map { .init(id: $0.id, name: $0.name, eventId: $0.eventId) },
                assets: v.assets.map { .init(id: $0.id, name: $0.name, kind: $0.kind, eventId: $0.eventId, available: $0.available,
                                             linked: $0.mode == "linked") },
                exports: v.exports.map { .init(id: $0.id, label: $0.output.isEmpty ? $0.id : ($0.output as NSString).lastPathComponent,
                                               status: $0.status) })
        }
        guard model != left.library else { return }
        left.library = model
        redraw()
    }

    /// Re-reads the navigator's "Recent" list (first paint, a project switch, File > Open Recent > Clear Menu).
    func refreshRecents() {
        guard let backend else { return }
        let post = uiPost, open = session.project?.directory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let recent = EditorSession.recents(backend, excluding: open).map { LibraryNavModel.RecentProject(path: $0.directory, name: $0.title) }
            post {
                // A refresh started before a project switch was filtered for the project open then: drop it.
                guard let self, self.session.project?.directory == open, recent != self.left.library.recentProjects else { return }
                self.left.library.recentProjects = recent
                self.redraw()
            }
        }
    }

    func startLibraryPolling() {
        guard libraryTimerCancel == nil, let schedule = session.schedule, backend?.libraries != nil else { return }
        libraryTimerCancel = schedule(3) { [weak self] in self?.libraryTimerCancel = nil; self?.refreshLibraries(); self?.startLibraryPolling() }
    }

    /// Runs a navigator command through LibraryCommands, then switches project / adds the
    /// attached asset / shows errors as the navigator does.
    func runLibrary(_ cmd: LibraryNavCommand) {
        guard let backend else { return }
        switch cmd {
        case .switchProject(let id): switchToLibraryProject(id); return
        case .openStandalone: switchToStandalone(); return
        case .openProject: session.requestOpenProject(); return
        case .openRecentProject(let dir): session.openProject(path: dir); return
        default: break
        }
        guard let service = backend.libraries, !left.library.busy else {
            if backend.libraries == nil { left.library.error = "Library service is unavailable"; redraw() }
            return
        }
        var command: JSONObject
        switch cmd {
        case .createLibrary: command = ["type": .string("create")]
        case .openLibrary: command = ["type": .string("open")]
        case .createEvent(let l, let name): command = ["type": .string("event"), "libraryId": .string(l), "name": .string(name)]
        case .createProject(let l, let e, let name): command = ["type": .string("project"), "libraryId": .string(l), "eventId": .string(e), "name": .string(name)]
        case .importIntoEvent(let l, let e, let linked):
            command = ["type": .string("import"), "libraryId": .string(l), "eventId": .string(e), "mode": .string(linked ? "linked" : "managed")]
            if left.library.currentProjectId != nil, let id = projectId,
               libraryViews.first(where: { $0.id == l })?.projects.contains(where: { $0.id == id }) == true {
                command["projectId"] = .string(id)
            }
        case .attach(let l, let a):
            guard let id = projectId else { return }
            command = ["type": .string("attach"), "libraryId": .string(l), "projectId": .string(id), "assetId": .string(a)]
        case .relink(let l, let a): command = ["type": .string("relink"), "libraryId": .string(l), "assetId": .string(a)]
        case .saveOutput(let l, let j): command = ["type": .string("saveOutput"), "libraryId": .string(l), "jobId": .string(j)]
        case .reveal(let l): command = ["type": .string("reveal"), "libraryId": .string(l)]
        case .switchProject, .openStandalone, .openProject, .openRecentProject: return
        }
        left.library.busy = true; left.library.error = nil; redraw()
        let dialogs = self.dialogs, post = uiPost, origin = projectId
        let request = JSONValue.object(command)
        Task { [weak self] in
            do {
                let result = try await LibraryCommands.dispatch(service: service, backend: backend, dialogs: dialogs, command: request)
                post { self?.libraryResult(result, command: cmd, origin: origin) }
            } catch {
                post { guard let self else { return }; self.left.library.busy = false; self.left.library.error = "\(error)"; self.redraw() }
            }
        }
    }

    private func libraryResult(_ result: JSONValue, command: LibraryNavCommand, origin: String?) {
        left.library.busy = false
        let errors = result["errors"]?.array?.compactMap(\.string) ?? []
        left.library.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if let next = result["projectId"]?.string { switchToLibraryProject(next) }
        if let path = result["path"]?.string, origin == projectId, case .attach(let l, let a) = command {
            // The attached file is now project media; video/audio/image also lands on the timeline (onAddAsset).
            let kind = libraryViews.first { $0.id == l }?.assets.first { $0.id == a }?.kind ?? ""
            let place = ["video", "audio", "image"].contains(kind)
            refreshMediaThen { [weak self] in if place { self?.addToTimeline(path: path, at: nil) } }
        }
        refreshLibraries()
        redraw()
    }

    private func refreshMediaThen(_ body: @escaping () -> Void) {
        guard let backend, let projectId else { return }
        let post = uiPost
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listed = (try? backend.listMedia(projectId: projectId, query: nil)) ?? []
            post { guard let self else { return }; self.media = listed; self.syncItems(); self.redraw(); body() }
        }
    }

    func switchToLibraryProject(_ libraryProjectId: String) {
        guard libraryProjectId != left.library.currentProjectId,
              let dir = libraryViews.flatMap(\.projects).first(where: { $0.id == libraryProjectId })?.directory
                ?? backend?.listProjects().first(where: { $0.libraryProjectId == libraryProjectId })?.directory else { return }
        session.switchProject { backend in try backend.openProject(path: dir) }
    }

    func switchToStandalone() {
        guard !left.library.isStandalone else { return }
        session.switchProject { backend in try backend.openDefaultProject() }
    }

    /// After the session opened another project: everything per-project is re-read.
    func projectSwitched() {
        media = []; probedDurations = [:]; probing = []; session.mediaThumbnails.reset()
        renders.reset()
        effectPreviews?.reset()   // sample tiles resolve LUT paths against the project folder
        syncItems()
        refreshMedia(); refreshLibraries(); refreshRenders(); refreshRecents()
        redraw()
    }

    // MARK: Right panel

    private func wireRight() {
        right.onChange = { [weak self] in self?.redraw() }
        let inspector = right.inspector
        inspector.editor = session.editor
        inspector.onEdited = { [weak self] in
            guard let self else { return }
            self.session.playback.duration = self.session.editor.duration
            self.session.syncStage(); self.redraw()
        }
        inspector.onSeek = { [weak self] t in
            guard let self else { return }
            self.session.playback.seek(t); self.session.timeline.syncFromPlayback(); self.session.syncStage(); self.redraw()
        }
        inspector.onClearSelection = { [weak self] in
            guard let self else { return }
            self.session.timeline.view.selection = []; self.session.syncStage(); self.redraw()
        }
        inspector.onCopyGrade = { [weak self] in self?.session.timeline.copyGradeSelection() ?? false }
        inspector.onPasteGrade = { [weak self] in self?.session.timeline.pasteGradeSelection() ?? false }
        inspector.onOpenGroupChanged = { [weak self] _ in self?.redraw() }
        right.easing.editor = session.editor
        right.easing.onEdited = inspector.onEdited   // the same save, duration and stage refresh as an inspector edit
        inspector.onAudition = { [weak self] request in self?.session.audition(request) }
        right.onAnimate = { [weak self] in self?.animatePanels() }
        rendersPanel.onChange = { [weak self] in self?.redraw() }
        rendersPanel.onAnimate = { [weak self] in self?.animatePanels() }
        inspector.onImportLut = { [weak self] in self?.importLut() }
        inspector.lutAssets = { [weak self] in self?.media.filter { $0.path.lowercased().hasSuffix(".cube") }.map(\.path) ?? [] }
        wirePresetPreviews(inspector)
        wireEffectPreviews(inspector)
        wireRenders()
    }

    /// Drives the side panels' motion (wheel glides, scrollbar fades, the accordion's 120 ms entrance) at ~60 Hz on
    /// the shell's main-loop timer, then stops.
    private func animatePanels() {
        guard !panelsAnimating, let schedule = session.schedule else { return }
        panelsAnimating = true
        var last = Date()
        func step() {
            let now = Date(), dt = now.timeIntervalSince(last); last = now
            let a = right.tick(dt), b = left.tick(dt), r = rendersPanel.tick(dt)
            redraw()
            if a || b || r { _ = schedule(1.0 / 60, step) } else { panelsAnimating = false }
        }
        _ = schedule(1.0 / 60, step)
    }

    /// Grade preset tiles: the selected clip's frame graded with each preset (PresetPreviewRenderer). While playing
    /// the tiles keep the frame they showed when playback started, so playback does not re-grade 18 thumbnails a frame.
    private func wirePresetPreviews(_ inspector: InspectorPanel) {
        let renderer = PresetPreviewRenderer(compositor: session.compositor)
        renderer.projectDir = { [weak session] in session?.projectDir?.path }
        renderer.onReady = { [weak self] in self?.uiPost { self?.redraw() } }
        presetPreviews = renderer
        inspector.presetPreview = { [weak self, weak inspector] req in
            guard let self, let inspector else { return .unavailable }
            if !self.session.playback.isPlaying { self.presetPreviewTime = inspector.time }
            switch renderer.preview(clipId: req.clipId, presetId: req.presetId, lutSrc: req.lutSrc, lutIntensity: req.lutIntensity,
                                    time: self.presetPreviewTime, pixelWidth: req.pixelWidth, pixelHeight: req.pixelHeight, version: req.version) {
            case .ready(let img): return .ready(img)
            // Media that gave up decoding never sends a frame: answer "no picture" so the tile shows the sample.
            case .rendering: return renderer.decodeGaveUp(clipId: req.clipId) ? .unavailable : .rendering
            case .unavailable: return .unavailable
            }
        }
        inspector.presetPreviewsAvailable = { renderer.isAvailable(clipId: $0) }
        inspector.onRetryPresetPreviews = { [weak self] in renderer.reset(); self?.effectPreviews?.reset() }
        wireScopes(inspector, clip: renderer)
    }

    /// Effects catalog tiles: the selected clip's frame with its grade plus each effect or look (the preset tiles'
    /// PresetPreviewRenderer); when the clip has no picture, the built-in sample picture (EffectPreviewRenderer), which
    /// is also what preset tiles fall back to. Both render off the UI thread; a finished tile redraws the panels.
    private func wireEffectPreviews(_ inspector: InspectorPanel) {
        let demos = EffectPreviewRenderer()
        demos.projectDir = { [weak session] in session?.projectDir?.path }
        demos.onReady = { [weak self] in self?.uiPost { self?.redraw() } }
        effectPreviews = demos
        inspector.effectPreview = { [weak self, weak inspector] req in
            if let self, let inspector, let frames = self.presetPreviews {
                // Like the preset tiles: paused, follow the playhead; playing, keep the frame shown when playback began.
                if !self.session.playback.isPlaying { self.presetPreviewTime = inspector.time }
                switch frames.effectPreview(req, time: self.presetPreviewTime) {
                case .ready(let img): return .ready(img)
                case .rendering: return .rendering
                case .unavailable: break   // no picture on the clip: the sample picture below
                }
            }
            return demos.preview(req)
        }
    }

    /// LUT "+": choose .cube files; they are copied into the project and become selectable LUTs.
    func importLut() {
        guard let dialogs, let backend, let projectId else { return }
        let post = uiPost
        Task { [weak self] in
            let files = await dialogs.showOpen(.init(title: "Import LUT", directory: false, multiple: true)).filter { $0.lowercased().hasSuffix(".cube") }
            guard !files.isEmpty else { return }
            do {
                _ = try await backend.importFiles(projectId: projectId, paths: files, directory: nil)
                post { self?.refreshMedia() }
            } catch { post { self?.session.onError("Could not import the LUT", "\(error)") } }
        }
    }

    /// Smoke/automation hook: runs the inspector row `key` with `value` (number/slider/toggle/segment/button) for
    /// the current selection, exactly as a click or typed value would.
    @discardableResult
    func applyInspectorRow(_ key: String, _ value: String) -> Bool {
        syncBeforePaint()
        for g in right.inspector.groups { for r in g.addressableRows {
            switch r.kind {
            case .number(let n) where n.key == key: n.commit(value); return true
            case .pair(_, let a, let b):
                if a.key == key { a.commit(value); return true }
                if b.key == key { b.commit(value); return true }
            case .quad(let ns): if let n = ns.first(where: { $0.key == key }) { n.commit(value); return true }
            case .slider(let sl) where sl.key == key: if let v = Double(value) { sl.commit(v); return true }
            case .toggle(let t) where t.key == key: t.set(value == "1" || value == "true"); return true
            case .segmented(let sg) where sg.key == key: sg.select(value); return true
            case .buttons(let bs): if let b = bs.first(where: { $0.key == key }) { b.action(); return true }
            case .subheader(_, let bs): if let b = bs.first(where: { $0.key == key }) { b.action(); return true }
            case .fxNode(let n) where n.key == key: if value == "remove" { n.remove() } else { n.toggle() }; return true
            default: break
            }
        } }
        return false
    }

    /// Per-frame state the panels read: selection and playhead (cheap; called before each paint).
    func syncBeforePaint() {
        let inspector = right.inspector
        let sel = session.timeline.view.selection.sorted()
        if inspector.selection != sel { inspector.selection = sel }
        inspector.gradeClipboardAvailable = session.timeline.gradeClipboard != nil
        let keys = session.timeline.view.selectedKeyframes
        if inspector.selectedKeyframes != keys { inspector.selectedKeyframes = keys }
        inspector.time = session.playback.currentTime
        let easing = right.easing   // the Keyframe Easing panel follows the same clip, keys and playhead
        if easing.clipId != sel.first { easing.clipId = sel.first }
        if easing.selectedKeyframes != keys { easing.selectedKeyframes = keys }
        easing.time = session.playback.currentTime
        right.canvasSize = CanvasSize(session.editor.document.canvas.width, session.editor.document.canvas.height)
        rendersPanel.canvasSize = right.canvasSize
    }
}

/// CanvasInput adapter for the left sidebar pane (region-local coordinates).
final class LeftSidebarInput: CanvasInput {
    unowned let panels: SessionPanels
    var last = CanvasPoint(0, 0)
    init(_ panels: SessionPanels) { self.panels = panels }
    var panel: LeftSidebarPanel { panels.left }
    func pointerDown(x: Double, y: Double, shift: Bool) { last = .init(x, y); if panel.pointerDown(.init(x, y)) { panels.redraw() } }
    func pointerMove(x: Double, y: Double) { last = .init(x, y); if panel.pointerMove(.init(x, y)) { panels.redraw() } }
    func pointerUp(x: Double, y: Double) { last = .init(x, y); panel.pointerUp(.init(x, y)) }
    func secondaryClick(x: Double, y: Double) { if panel.secondaryClick(.init(x, y)) { panels.redraw() } }
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool) { scroll(dx: dx, dy: dy, x: x, ctrl: ctrl, shift: shift, precise: false) }
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool, precise: Bool) {
        if panel.scroll(.init(x, last.y), dy: dy, precise: precise) { panels.redraw() }
    }
    func keyDown(_ k: EditorKey) -> Bool { let h = panel.keyDown(k); if h { panels.redraw() }; return h }
    func keyUp(_ k: EditorKey) {}
    func resized(_ size: CanvasSize) {}
}

/// CanvasInput adapter for the Design and Renders panes.
final class RightPanelInput: CanvasInput {
    unowned let panels: SessionPanels
    let panel: RightPanel
    var last = CanvasPoint(0, 0)
    init(_ panels: SessionPanels, panel: RightPanel) { self.panels = panels; self.panel = panel }
    func pointerDown(x: Double, y: Double, shift: Bool) { last = .init(x, y); if panel.pointerDown(.init(x, y)) { panels.redraw() } }
    func pointerMove(x: Double, y: Double) { last = .init(x, y); if panel.pointerMove(.init(x, y)) { panels.redraw() } }
    func pointerUp(x: Double, y: Double) { last = .init(x, y); panel.pointerUp(.init(x, y)); panels.redraw() }
    func secondaryClick(x: Double, y: Double) {}
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool) { scroll(dx: dx, dy: dy, x: x, ctrl: ctrl, shift: shift, precise: false) }
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool, precise: Bool) {
        // ctrl: the host's zoom modifier (as the timeline reads it) zooms the Easing tab's graph.
        if panel.scroll(.init(x, last.y), dy: dy, precise: precise, zoom: ctrl) { panels.redraw() }
    }
    func keyDown(_ k: EditorKey) -> Bool {
        // Typing into a field stays in the panel; everything else falls through to the timeline/playback shortcuts.
        let h = panel.keyDown(k); if h { panels.redraw() }; return h
    }
    func keyUp(_ k: EditorKey) {}
    func resized(_ size: CanvasSize) {}
}

extension RightPanelInput: CanvasAccessibilityProvider {
    var accessibilityControls: [CanvasAccessibilityControl] { panels.right.accessibilityControls }
}

extension EditorSession {
    /// Puts the Media, Design and Renders panels into the shell (called from installShell).
    func installPanels(_ router: EditorShellRouter, userData: String) {
        let p = SessionPanels(session: self, layout: router.layout, userData: userData)
        panels = p
        let li = LeftSidebarInput(p), ri = RightPanelInput(p, panel: p.right), rr = RightPanelInput(p, panel: p.rendersPanel)
        let drag = BinAssetDrag(p)
        p.assetDrag = drag
        router.crossPaneDrag = drag
        shellInputs += [li, ri, rr]
        router.panes[.left] = ShellPane(input: li) { [weak p] c, size in p?.startIfNeeded(); p?.left.draw(c, size: size) }
        router.panes[.right] = ShellPane(input: ri) { [weak p] c, size in p?.startIfNeeded(); p?.syncBeforePaint(); p?.right.draw(c, size: size) }
        router.panes[.renders] = ShellPane(input: rr) { [weak p] c, size in
            p?.startIfNeeded(); p?.syncBeforePaint(); p?.rendersPanel.draw(c, size: size)
        }
        router.panes[.left]?.hint = { [weak p] in p?.left.hint }
        router.panes[.right]?.hint = { [weak p] in p?.right.hint }
        router.panes[.renders]?.hint = { [weak p] in p?.rendersPanel.hint }
        installDockedPanels(router, p)
        let previous = editor.onChange
        editor.onChange = { [weak p] in previous?(); p?.syncItems() }
        p.syncItems()
    }

    /// Opens another project in this window (library project picker, "Open existing standalone project", File > Open):
    /// saves the current one, swaps the document, history and watcher, and re-reads the panels.
    func switchProject(_ open: (DesktopBackend) throws -> DesktopProject) {
        guard let backend else { return }
        if let failure = flushSave() { onError("Could not save the project", failure); return }
        do {
            let opened = try open(backend)
            guard opened.id != project?.id else { return }
            if let old = project { backend.closeProject(id: old.id) }
            compositor.releaseAll()   // the closed project's decoders, frames and graded pictures
            try adoptProject(opened)
            watchOpenProject()
            timeline.view.selection = []
            playback.seek(0); timeline.syncFromPlayback()
            panels?.projectSwitched()
        } catch { onError("Could not open the project", "\(error)") }
    }
}
