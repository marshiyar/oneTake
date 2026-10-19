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
import OneTakeKeyframes
import MpvfxAudio
import MpvfxAudioGraph
import Foundation
import MpvfxCanvas
import MpvfxTheme
import MpvfxShared
import MpvfxTimeline
import MpvfxPlayer
import MpvfxPanels
import MpvfxDesktopCore

/// Wires the document, playback clock, timeline and player together (host-neutral).
final class EditorSession {
    let editor: TimelineEditor
    let playback: PlaybackState
    let timeline: TimelineController
    let player: PlayerController
    var redraw: () -> Void = {}
    /// Hop to the UI thread (GTK idle on Linux); set by the shell. Work posted before the shell sets it (background
    /// tasks the session starts while it is built) waits in `uiPoster` and runs through the shell's hop once set.
    var postToUI: (@escaping () -> Void) -> Void {
        get { { [uiPoster] body in uiPoster.post(body) } }
        set { uiPoster.install(newValue) }
    }
    private let uiPoster = UIPoster()
    /// Composites every visible video/image layer at the playhead (decoders run off the UI thread).
    let compositor: PreviewCompositor
    let engine: KeyframeRuntime?
    var composedDocument: NativeProjectDocument?
    /// Natural pixel sizes probed for assets that have none cached (project-relative source -> size; EditorSession+NaturalSize).
    var naturalSizes: [String: NativeMediaNaturalSize] = [:]
    var naturalSizeProbes: Set<String> = []
    /// Sources whose natural-size probe is in flight: their clips are not drawn until the box is known (the size
    /// is read before placing), so nothing ever flashes full frame and snaps.
    var naturalSizePending: Set<String> = []
    var animationFramePending = false
    let transport = TransportPopovers()
    /// Window regions and input routing (EditorShellLayout.swift); set by the shell via installShell.
    var shell: EditorShellRouter?
    var shellInputs: [CanvasInput] = []
    /// Timeline card content (toolbar + tracks); set by installShell.
    var timelineRegion: TimelineRegion?
    var volumeAnimating = false
    private(set) var projectDir: URL?
    /// Left sidebar + right panel wiring (EditorSession+Panels.swift); set by installShell.
    var panels: SessionPanels?
    var desktopPreferences: DesktopPreferences?
    /// System / Light / Dark setting (EditorSession+Appearance); set by the shell via installAppearance.
    var appearance: AppearanceSettings?
    /// Shared media frames/peaks cache (MediaThumbnails.swift): bin cards, audio rows, timeline filmstrips.
    lazy var mediaThumbnails: MediaThumbnails = {
        let t = MediaThumbnails(post: { [weak self] body in self?.postToUI(body) })
        t.onReady = { [weak self] in self?.redraw() }
        return t
    }()
    /// Where the document is loaded from and saved to; nil for the built-in demo (nothing to save).
    let backend: DesktopBackend?
    private(set) var project: DesktopProject?
    /// The document as last loaded or saved; the session is dirty when the editor's differs.
    private(set) var savedDocument: NativeProjectDocument
    /// Writes the undo history after every edit (EditorSession+EditHistory); set by installShell for a saved project.
    var editHistory: TimelineHistoryPersister?
    /// Save/import failures for the shell to show (stderr until a shell sets it).
    var onError: (_ title: String, _ message: String) -> Void = { t, m in FileHandle.standardError.write(Data("[MpVFX] \(t): \(m)\n".utf8)) }

    /// `projectPath` (MPVFX_PROJECT) opens that project; otherwise the default project, or the built-in demo
    /// when `demo` is set (smoke tests) or there is no backend.
    init(backend: DesktopBackend? = nil, projectPath: String?, demo: Bool = false) throws {
        engine = try? KeyframeRuntime()
        if let backend, !demo {
            let opened = try projectPath.map { try backend.openProject(path: $0) } ?? backend.openDefaultProject()
            project = opened
            editor = try TimelineEditor(json: opened.content, engine: engine)
            projectDir = URL(fileURLWithPath: opened.directory)
        } else if let projectPath, !demo {
            // No backend: read a bare document file (read-only; nothing to save through).
            editor = try TimelineEditor(json: try String(contentsOfFile: projectPath, encoding: .utf8), engine: engine)
            projectDir = URL(fileURLWithPath: projectPath).deletingLastPathComponent()
        } else {
            editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: engine)
            projectDir = nil
        }
        self.backend = backend
        savedDocument = editor.document
        playback = PlaybackState(duration: editor.duration, fps: editor.fps)
        let tv = TimelineView(tracks: [], duration: editor.duration)
        timeline = TimelineController(view: tv, playback: playback, editor: editor)
        let pv = PlayerView(playback: playback)
        pv.canvasSize = CanvasSize(editor.document.canvas.width, editor.document.canvas.height)
        let bg = CanvasColor(hex: editor.document.canvas.background) ?? CanvasColor(ThemeTokens.stageDefaultBackground)
        compositor = PreviewCompositor(background: bg)
        pv.frameSource = compositor
        player = PlayerController(view: pv)
        timeline.needsDisplay = { [weak self] in self?.syncStage(); self?.redraw() }
        player.needsDisplay = { [weak self] in self?.redraw() }
        compositor.frameReady = { [weak self] in self?.postToUI { self?.redraw() } }
        player.onSelectionChange = { [weak self] ids in self?.timeline.view.selection = Set(ids); self?.redraw() }
        player.onCommit = { [weak self] e in self?.stageCommitted(e) }
        player.onDelete = { [weak self] ids in self?.deleteClips(ids) }
        player.onZOrder = { [weak self] ids, action in self?.applyZOrder(ids, action) }
        player.zOrderEnabled = { [weak self] id in self?.zOrderActions(id) ?? [] }
        pv.requestAnimationFrame = { [weak self] in self?.scheduleAnimationFrame() }
        editor.naturalSize = { [weak self] asset in asset.naturalSize ?? asset.source.flatMap { self?.naturalSizes[$0] } }
        makeAudio()
        setupTransportPopovers()
        syncStage()
        let previousOnChange = editor.onChange
        editor.onChange = { [weak self] in previousOnChange?(); self?.documentChanged(); self?.rebuildAudioGraphIfNeeded() }
        if let backend, let project {
            do {
                try backend.watchProject(id: project.id) { [weak self] text in
                    self?.postToUI { self?.externalChange(text) }   // postToUI hops to the UI thread
                }
            } catch { FileHandle.standardError.write(Data("[MpVFX] not watching the project file: \(error)\n".utf8)) }
        }
    }

    // MARK: Save / import (through the DesktopBackend)

    var isDirty: Bool { project != nil && editor.document != savedDocument }

    /// Writes the document through the backend (journaled, crash-safe) and waits for it. No-op when nothing changed.
    /// Explicit saves only (Cmd+S, before a render, the close barrier); edits autosave in the background.
    func save() throws {
        saveQueue.sync {}   // an autosave in flight lands first, so writes stay in order
        guard let backend, let project, isDirty else { return }
        let document = editor.document
        let content = try serializeNativeProjectDocument(document, engine: engine)
        try backend.saveProject(id: project.id, content: content)
        saveGeneration += 1   // an autosave still posting its result back is older than this write
        self.project?.content = content
        savedDocument = document
    }

    // MARK: Autosave and external changes
    // Every edit is written shortly after it is made, so a
    // crash or power loss costs at most the last moment of work.

    static let autosaveDelay = 0.75
    var autosaveEnabled = true
    /// Main-loop timer from the shell: (seconds, body) -> cancel. Without one, saves happen on Cmd/Ctrl+S and close only.
    var schedule: ((Double, @escaping () -> Void) -> () -> Void)?
    private var cancelAutosave: (() -> Void)?
    /// Set by the shell to ask: the file changed on disk while there are unsaved edits. Answer true to keep
    /// the edits (they overwrite the file), false to load the file. Without it, edits are kept and reported.
    var onExternalConflict: ((_ answer: @escaping (_ keepMine: Bool) -> Void) -> Void)?
    private var conflictOpen = false

    private func documentChanged() {
        guard autosaveEnabled, project != nil, let schedule else { return }
        cancelAutosave?()
        cancelAutosave = schedule(Self.autosaveDelay) { [weak self] in self?.autosave() }
    }

    /// Autosave writes on `saveQueue`: serializing the document and the journaled, fsynced write cost far more
    /// than a frame on a real project (seconds on a large one in a debug build), and ran on the UI thread 0.75 s
    /// after every edit, which is exactly when the user presses play: the reported "edit, then play hangs".
    /// The document is a value, so the worker writes a snapshot; the result comes back through `postToUI`.
    let saveQueue = DispatchQueue(label: "mpvfx.autosave", qos: .userInitiated)
    private var autosaveInFlight = false
    private var autosaveAgain = false
    private var saveGeneration = 0

    private func autosave() {
        cancelAutosave = nil
        guard let backend, let project, isDirty else { return }
        if autosaveInFlight { autosaveAgain = true; return }
        autosaveInFlight = true
        let document = editor.document, engine = self.engine, id = project.id, generation = saveGeneration
        let post = postToUI
        saveQueue.async { [weak self] in
            let result = Result { () throws -> String in
                let content = try serializeNativeProjectDocument(document, engine: engine)
                try backend.saveProject(id: id, content: content)
                return content
            }
            post { self?.autosaveFinished(document, generation: generation, result) }
        }
    }

    private func autosaveFinished(_ document: NativeProjectDocument, generation: Int, _ result: Result<String, Error>) {
        autosaveInFlight = false
        switch result {
        case .success(let content):
            if generation == saveGeneration { project?.content = content; savedDocument = document }
        case .failure(let e as DesktopError) where e.name == "ConflictError":
            resolveConflict(diskContent: nil)
        case .failure(let e):
            onError("Could not save the project", "\(e)")
        }
        if autosaveAgain { autosaveAgain = false; autosave() }
    }

    /// The document on disk changed outside the app.
    func externalChange(_ text: String) {
        guard project != nil else { return }
        if !isDirty { takeDiskVersion(); return }
        resolveConflict(diskContent: text)
    }

    private func resolveConflict(diskContent: String?) {
        guard !conflictOpen else { return }
        conflictOpen = true
        let answer: (Bool) -> Void = { [weak self] keepMine in
            guard let self else { return }
            self.conflictOpen = false
            if keepMine { self.overwriteDisk() } else { self.takeDiskVersion() }
        }
        if let onExternalConflict { onExternalConflict(answer) }
        else {
            onError("The project file changed on disk", "Your unsaved edits were kept and will overwrite the file.")
            answer(true)
        }
    }

    /// Loads the document now on disk (history is cleared: it no longer applies).
    func takeDiskVersion() {
        guard let backend, let project else { return }
        do {
            let reloaded = try backend.reloadProject(id: project.id)
            try loadContent(reloaded.content)
        } catch { onError("Could not reload the project", "\(error)") }
    }

    /// Saves the editor's document over a file that changed on disk.
    func overwriteDisk() {
        guard let backend, let project else { return }
        do { _ = try backend.reloadProject(id: project.id); try save() }
        catch { onError("Could not save the project", "\(error)") }
    }

    /// Replaces the open document with saved text (no undo entry).
    func loadContent(_ content: String) throws {
        let doc = try TimelineEditor(json: content, engine: nil).document
        let wasAutosave = autosaveEnabled
        autosaveEnabled = false
        editor.loadDocument(doc)
        autosaveEnabled = wasAutosave
        self.project?.content = content
        savedDocument = doc
        playback.duration = editor.duration
        syncStage(); redraw()
    }

    /// Makes `opened` the session's project: its document replaces the open one (history cleared) and media
    /// resolves against its folder.
    func adoptProject(_ opened: DesktopProject) throws {
        _ = try TimelineEditor(json: opened.content, engine: nil)   // validate before anything changes
        project = opened
        projectDir = URL(fileURLWithPath: opened.directory)
        composedDocument = nil; graphInputs = nil
        try loadContent(opened.content)
        player.view.canvasSize = CanvasSize(editor.document.canvas.width, editor.document.canvas.height)
        if let notice = editor.document.undrawnElementLayersNotice { player.view.showToast(notice) }
    }

    // MARK: Media in the project

    /// Renames media and repoints the document's assets (one saved edit; history is cleared).
    func renameMedia(_ from: String, to: String) throws {
        guard let backend, let project else { return }
        let content = try serializeNativeProjectDocument(editor.document, engine: engine)
        try loadContent(try backend.renameMedia(projectId: project.id, from: from, to: to, content: content).content)
    }

    /// Deletes media to the recovery folder; `removeUsages` also removes its clips and assets.
    func deleteMedia(_ path: String, removeUsages: Bool) throws {
        guard let backend, let project else { return }
        let content = try serializeNativeProjectDocument(editor.document, engine: engine)
        try loadContent(try backend.deleteMedia(projectId: project.id, path: path, removeUsages: removeUsages, content: content).content)
    }

    /// For the save barrier on close/quit: nil when saved, else the message to show (the window stays open).
    func flushSave() -> String? {
        do { try save(); return nil } catch { return "\(error)" }
    }

    /// Set by the shell: show a file chooser and call importMedia(paths:).
    var onImportRequested: (() -> Void)?

    /// Cmd+S / Ctrl+S saves now; Cmd+I / Ctrl+I imports media (when the shell offers a chooser).
    func commandKey(_ k: EditorKey) -> Bool {
        guard k.command, !k.alt, !k.shift, case .char(let c) = k.code else { return false }
        switch c.lowercased() {
        case "s":
            do { try save() } catch { onError("Could not save the project", "\(error)") }
            return true
        case "i":
            guard let onImportRequested, project != nil else { return false }
            onImportRequested(); return true
        default: return false
        }
    }

    /// Copies files into the project, then adds each video, audio and image file to the document's assets
    /// (one undoable edit). Fonts and LUTs are copied but not added as timeline assets.
    func importMedia(paths: [String], completion: @escaping (DesktopMediaImport) -> Void = { _ in }) {
        guard let backend, let project, !paths.isEmpty else { return }
        panels?.left.importing = true; redraw()
        Task { [weak self] in
            do {
                let result = try await backend.importMedia(projectId: project.id, paths: paths, directory: nil)
                self?.postToUI {
                    guard let self else { return }
                    self.panels?.left.importing = false
                    self.addImportedAssets(result.media)
                    self.panels?.refreshMedia()
                    if !result.invalid.isEmpty {
                        self.onError("Media not imported", result.invalid.map { "\($0.name) (\($0.reason))" }.joined(separator: ", "))
                    }
                    if !result.notices.isEmpty {
                        self.onError("Imported without sound", result.notices.map { "\($0.name) (\($0.reason))" }.joined(separator: ", "))
                    }
                    completion(result)
                }
            } catch {
                self?.postToUI { self?.panels?.left.importing = false; self?.redraw(); self?.onError("Import failed", "\(error)") }
            }
        }
    }

    /// Imported media as document assets: source is the project-relative copy, duration in frames.
    func addImportedAssets(_ media: [DesktopImportedMedia]) {
        let before = editor.document
        var doc = before
        let fps = editor.fps
        let known = Set(doc.assets.compactMap(\.source))
        for m in media where !known.contains(m.path) {
            let kind: NativeProjectAssetKind
            switch m.kind { case "video": kind = .video; case "audio": kind = .audio; case "image": kind = .image; default: continue }
            // Stills have no length of their own: 5 s, the length of the starter sequence.
            // The natural size probed during the import rides on the asset: its box is known before it is placed or drawn.
            doc.assets.append(nativeImportedMediaAsset(id: "asset:\(UUID().uuidString.lowercased())", kind: kind, name: m.name,
                                                       source: m.path, durationSeconds: m.duration, fps: fps, width: m.width, height: m.height))
        }
        guard doc != before else { return }
        editor.replaceDocument(doc, inverse: .restoreDocument(before))
        syncStage(); redraw()
    }

    /// Crop lives on the clip in the native document (undoable like any other edit).
    func savedCrop(_ id: String) -> CropInsets {
        guard let c = editor.crop(clipId: id) else { return .zero }
        return CropInsets(top: c.top, right: c.right, bottom: c.bottom, left: c.left)
    }

    func persistCrop(id: String, _ crop: CropInsets) {
        editor.setCrop(clipId: id, NativeClipCrop(top: crop.top, right: crop.right, bottom: crop.bottom, left: crop.left))
    }

    /// Rebuilds the compositor's layers when the document changed (media files are checked then, not per frame).
    func syncDecoderClips() {
        guard editor.document != composedDocument else { return }
        composedDocument = editor.document
        compositor.composition = PreviewComposition(document: editor.document, projectDir: projectDir, engine: engine,
                                                    naturalSize: editor.naturalSize, sizePending: { [weak self] in self?.isSizePending($0) ?? false })
    }

    func syncStage() {
        // The composition size is an edit like any other (Design tab, undo, an external change): the stage frame
        // follows it at once, letterboxed in the viewport at the new aspect.
        let canvas = CanvasSize(editor.document.canvas.width, editor.document.canvas.height)
        if player.view.canvasSize != canvas { player.view.canvasSize = canvas }
        requestNaturalSizes()   // first: a clip whose size is still unknown is held back from this very composition
        syncDecoderClips()
        let t = playback.currentTime
        // A drag or the crop tool in progress keeps its live element until it commits.
        let editing = player.editingIds
        let live = Dictionary(player.view.elements.filter { editing.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        player.view.elements = editor.activeElements(at: t).filter { !isSizePending(clipId: $0.id) }.map { e in
            if let l = live[e.id] { return l }
            let base = stageBase(e.id, kind: e.kind, time: t)
            let tr = editor.transform(clipId: e.id, time: t)
            return StageElement(id: e.id, name: e.name, rect: StageGeometry.rect(base: base, tr), kind: e.kind,
                                rotation: tr.rotation ?? 0, crop: savedCrop(e.id), scale: StageGeometry.uniformScale(editor: editor, clipId: e.id, time: t))
        }
        let sel = timeline.view.selection
        player.view.selectedIds = player.view.elements.filter { sel.contains($0.id) }.map(\.id)
    }

    /// Capture-phase keyframe keys (K toggles the selected element's position keyframe), before playback JKL.
    func keyframeKey(_ k: EditorKey) -> Bool {
        let sel = player.view.selection
        let kind = player.view.elements.first { $0.id == sel }?.kind
        guard KeyframeKeyboard.handle(k, editor: editor, stageSelection: sel, kind: kind, time: playback.currentTime) else { return false }
        syncStage(); redraw(); return true
    }

    func stageBase(_ id: String, kind: TimelineClipKind, time: Double) -> CanvasRect {
        StageGeometry.baseRect(editor: editor, clipId: id, kind: kind, time: time)
    }

    func stageCommitted(_ e: StageElement) {
        persistCrop(id: e.id, e.crop)
        let t = playback.currentTime
        let base = stageBase(e.id, kind: e.kind, time: t)
        let before = StageElement(id: e.id, name: e.name, rect: StageGeometry.rect(base: base, editor.transform(clipId: e.id, time: t)),
                                  kind: e.kind, rotation: editor.transform(clipId: e.id, time: t).rotation ?? 0)
        let tr = StageGeometry.transform(base: base, start: before, end: e)
        if tr != ClipTransform() { editor.applyTransform(clipId: e.id, time: t, tr) }
        syncStage(); redraw()
    }

    /// Advance playback; returns true if still playing.
    func tick(_ dt: Double) -> Bool {
        syncAudio()
        if playback.tick(dt) { timeline.syncFromPlayback() }
        syncAudio()
        return playback.isPlaying
    }

    // MARK: Audio (device clock drives playback; video follows)
    // Live playback renders the same bus/FX graph export uses (MpvfxAudioGraph), built from the open
    // document and pulled in 128-frame blocks; master volume and mute come from the transport.
    var audio: AudioPlayback?
    var graph: GraphAudioSource?
    var graphInputs: DocumentAudioGraph.Inputs?
    var graphDocument: NativeProjectDocument?
    /// Builds and swaps the graph off the UI thread (decode, FX parse, pre-roll); edits only hand it inputs.
    var graphUpdater: LiveAudioGraphUpdater?
    /// Inspector audition (hovering a shelf preset or effect): the live graph plays its document instead of the open
    /// one, and a paused transport is started for it and put back after. Export and undo never see it.
    let audition = AuditionPlayback()
    /// Starts the shell's playback timer once playback is running (the shell's afterKey hook).
    var ensurePlayTimer: (() -> Void)?

    func makeAudio() {
        #if canImport(CPulse)
        var output: AudioOutput? = PulseAudioOutput()
        #elseif os(macOS)
        var output: AudioOutput? = CoreAudioOutput()
        #elseif os(Windows)
        var output: AudioOutput? = WASAPIOutput()
        #else
        var output: AudioOutput? = nil   // no native sink compiled (libpulse headers missing): video uses the wall clock
        #endif
        // Headless runs and stress tests: a sink that consumes at the wall clock without a sound server.
        if ProcessInfo.processInfo.environment["MPVFX_AUDIO_OUTPUT"] == "null" { output = ClockedNullAudioOutput() }
        guard let output else { return }
        let source = GraphAudioSource(project: AudioGraphProject(duration: editor.duration, sampleRate: Double(output.format.sampleRate), tracks: []))
        graph = source
        let updater = LiveAudioGraphUpdater(source: source)   // stems decode through the media engine
        updater.onIssues = { issues in for i in issues { FileHandle.standardError.write(Data("[MpVFX] audio: \(i)\n".utf8)) } }
        graphUpdater = updater
        audio = AudioPlayback(output: output, source: source, blockFrames: GraphAudioSource.quantum)
        playback.externalClock = { [weak self] in self?.audio.flatMap { $0.isPlaying ? $0.currentTime : nil } }
        rebuildAudioGraphIfNeeded()
    }

    /// Hands the graph worker the document's audio inputs when anything the graph depends on changed (tracks,
    /// groups, FX, automation, mute, volume). Cheap on the UI thread: the build, any stem decode and the pre-roll
    /// to the playing position run on the worker, and playback keeps the old graph until the new one is ready.
    func rebuildAudioGraphIfNeeded() {
        guard let graphUpdater else { return }
        // Called every playback tick: the document walk and a file check per clip only run after an edit.
        // An audition overrides the document the graph plays (never the open one, which export and undo read).
        let document = audition.document ?? editor.document
        if graphInputs != nil, let d = graphDocument, d == document { return }
        graphDocument = document
        let inputs = DocumentAudioGraph.inputs(document, duration: editor.duration, projectDir: projectDir)
        guard inputs != graphInputs else { return }
        graphInputs = inputs
        graphUpdater.submit(inputs)
    }

    /// Starts, switches or ends (nil) an inspector audition: the graph takes the auditioned document first, then a
    /// paused transport plays from a span the chain is heard over; ending stops it, seeks back and restores the graph.
    func audition(_ request: AuditionRequest?) {
        let started = audition.apply(request, playback: playback) { rebuildAudioGraphIfNeeded() }
        timeline.syncFromPlayback()
        syncAudio()
        if started { ensurePlayTimer?() }
        syncStage(); redraw()
    }

    func syncAudio() {
        guard let audio, let graph else { return }
        rebuildAudioGraphIfNeeded()
        graph.muted = playback.audioMuted
        graph.masterGain = transport.volume.volume
        // Loop on: the feeder wraps at the loop end itself (seamless, no restart); off: straight through, and the
        // transport stops at the out point.
        let wantLoop = playback.loopEnabled ? (start: playback.loopStart, end: playback.loopEnd) : nil
        if audio.loop?.start != wantLoop?.start || audio.loop?.end != wantLoop?.end { audio.loop = wantLoop }
        if playback.wantsExternalClock {
            if !audio.isPlaying || abs(audio.currentTime - playback.currentTime) > 0.25 { try? audio.play(from: playback.currentTime) }
        } else if audio.isPlaying {
            audio.stop()
        }
    }
}

// MARK: Stage canvas menu and animation frames
extension EditorSession {
    /// Canvas menu Delete: removes the clips (one undo step).
    func deleteClips(_ ids: [String]) {
        let addrs = ids.sorted().compactMap { editor.address(clipId: $0) }
        guard !addrs.isEmpty, editor.apply(addrs.count == 1 ? .delete(address: addrs[0]) : .deleteMany(addrs)) else { return }
        timeline.view.selection = []; syncStage(); redraw()
    }

    /// Visual layers at the playhead, bottom first, with their compositing order key.
    func zStack() -> [(id: String, layer: Double)] {
        guard let comp = compositor.composition else { return [] }
        let t = playback.currentTime, f = Double(comp.frameIndex(at: t))
        return comp.entries.filter { $0.clip.startFrame <= f && f < $0.clip.startFrame + $0.clip.durationFrames }.map { ($0.clip.id, $0.layer) }
    }

    func zOrderActions(_ id: String) -> Set<StageZOrderAction> {
        let stack = zStack()
        guard let i = stack.firstIndex(where: { $0.id == id }) else { return [] }
        var out = Set<StageZOrderAction>()
        if i < stack.count - 1 { out.formUnion([.bringForward, .bringToFront]) }
        if i > 0 { out.formUnion([.sendBackward, .sendToBack]) }
        return out
    }

    /// Restacks a clip among the layers under the playhead by writing its layout.zIndex (the compositing key the
    /// preview and export share).
    func applyZOrder(_ ids: [String], _ action: StageZOrderAction) {
        let stack = zStack()
        for id in ids {
            guard let i = stack.firstIndex(where: { $0.id == id }), let (track, _) = editor.clip(id) else { continue }
            let z: Double
            switch action {
            case .bringToFront: guard i < stack.count - 1 else { continue }; z = (stack.map(\.layer).max() ?? 0) + 1
            case .sendToBack: guard i > 0 else { continue }; z = (stack.map(\.layer).min() ?? 0) - 1
            case .bringForward:
                guard i < stack.count - 1 else { continue }
                let above = stack[i + 1].layer, next = i + 2 < stack.count ? stack[i + 2].layer : above + 2
                z = (above + next) / 2
            case .sendBackward:
                guard i > 0 else { continue }
                let below = stack[i - 1].layer, prev = i >= 2 ? stack[i - 2].layer : below - 2
                z = (below + prev) / 2
            }
            let a = NativeProjectParameterAddress(sequenceId: editor.sequenceId, trackId: track.id, clipId: id, parameterId: "layout.zIndex")
            editor.applyProperty(.atomic(.setStatic(address: a, value: .number(z))))
        }
        syncStage(); redraw()
    }

    /// One more draw ~1/60 s from now while the stage animates (zoom readout fade, play/pause morph).
    func scheduleAnimationFrame() {
        guard !animationFramePending else { return }
        animationFramePending = true
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 1.0 / 60)
            self?.postToUI { guard let self else { return }; self.animationFramePending = false; self.redraw() }
        }
    }
}

/// Routes UI work to the shell's hop. Before the shell installs it, work posted from the UI thread runs inline and
/// work from any other thread is held, then handed to the hop on install, so nothing touches session state off the
/// UI thread.
final class UIPoster: @unchecked Sendable {
    private let lock = NSLock()
    private var hop: ((@escaping () -> Void) -> Void)?
    private var held: [() -> Void] = []

    func post(_ body: @escaping () -> Void) {
        lock.lock()
        if let hop { lock.unlock(); hop(body); return }
        if Thread.isMainThread { lock.unlock(); body(); return }
        held.append(body); lock.unlock()
    }

    func install(_ newHop: @escaping (@escaping () -> Void) -> Void) {
        lock.lock(); hop = newHop; let work = held; held = []; lock.unlock()
        for body in work { newHop(body) }
    }
}
