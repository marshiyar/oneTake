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
import struct MpvfxAudioGraph.MasterLoudnessTarget
import MpvfxCanvas
import MpvfxShared
import MpvfxRuntime
import MpvfxPanels
import MpvfxDesktopCore
import MpvfxBackend
import MpvfxPlayer

/// The Renders tab's state: exports started in this window plus the project's render history
/// from the backend, minus the renders the user hid (kept per project in preferences.json, newest 200).
struct RenderQueueState {
    /// An export running (or finished) in this session.
    struct Active {
        var id: String
        var run: RenderRun?
        var view: RenderJobView
        var settings: RenderSettingsModel
        var outputPath: String
        /// The export preset this render is a version of (Export versions…); retrying renders it again the same way.
        var preset: RenderPreset?
    }
    var active: [Active] = []
    /// The versions of the current "Export versions" run, rendering one after another; nil when none is running.
    var batch: RenderBatch?
    var history: [DesktopRender] = []
    var hidden: Set<String> = []
    var loadError: String?

    /// The history id of an export of this session: the output file's name, which is the job id unless the export
    /// named its file (a version of an export run). Not started yet: the id itself.
    func fileId(_ id: String) -> String {
        guard let path = active.first(where: { $0.id == id })?.outputPath, !path.isEmpty else { return id }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    mutating func reset() { active.removeAll { $0.view.status != .rendering && $0.view.status != .queued }; history = []; hidden = []; loadError = nil }

    /// Newest first: this session's exports, then history entries they do not already cover.
    var rows: [RenderJobView] { rows(thumbnail: { _ in nil }) }
    func rows(thumbnail: (String) -> CanvasImage?) -> [RenderJobView] {
        let mine = Set(active.map(\.id) + active.filter { !$0.outputPath.isEmpty }.map { fileId($0.id) })
        let fromHistory = history.filter { !mine.contains($0.id) }.map { r -> RenderJobView in
            RenderJobView(id: r.id, name: r.filename, status: r.status == "failed" ? .failed : .complete, stage: "",
                          progress: 1, detail: RenderQueueState.detail(size: r.size, durationMs: r.durationMs),
                          error: r.status == "failed" ? "Render failed" : nil, thumbnail: r.status == "failed" ? nil : thumbnail(r.path),
                          createdAt: r.createdAt > 0 ? r.createdAt : nil, sizeBytes: r.size > 0 ? Double(r.size) : nil, durationMs: r.durationMs,
                          loudness: RenderQueueState.loudnessLabel(target: r.loudnessTarget, measured: r.loudnessMeasured))
        }
        let current = active.reversed().map { a -> RenderJobView in
            var v = a.view
            if v.status == .complete, v.thumbnail == nil { v.thumbnail = thumbnail(a.outputPath) }
            // A render finished in this window shows the loudness its history record holds, once the history is read.
            if v.status == .complete, v.loudness == nil, let r = history.first(where: { $0.id == a.id }) {
                v.loudness = RenderQueueState.loudnessLabel(target: r.loudnessTarget, measured: r.loudnessMeasured)
            }
            return v
        }
        return (current + fromHistory).filter { !hidden.contains($0.id) }
    }

    /// "12.3 MB · 0:42" (file size · how long the render took).
    static func detail(size: Int64, durationMs: Double?) -> String {
        var parts: [String] = []
        if size > 0 { parts.append(formatBytes(Double(size))) }
        if let ms = durationMs, ms > 0 { parts.append(formatPanelTime(ms / 1000)) }
        return parts.joined(separator: " · ")
    }

    static func formatBytes(_ b: Double) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if b >= gb { return String(format: "%.1f GB", b / gb) }
        if b >= mb { return String(format: "%.1f MB", b / mb) }
        if b >= kb { return String(format: "%.0f KB", b / kb) }
        return "\(Int(b)) B"
    }
}

/// Renders tab model <-> export API and preferences.json (PersistedRenderSettings).
enum RenderSettingsBridge {
    /// The Renders tab's choices as the export API's settings for the composition `canvas`: the resolution scales
    /// the composition with its aspect kept (compositionExportResolution), it never reshapes the frame.
    static func exportSettings(_ m: RenderSettingsModel, canvas: NativeCanvas) -> ExportSettings {
        let format = ExportFormat(rawValue: m.format) ?? .mp4
        let quality = ExportQuality(rawValue: m.quality) ?? .standard
        let fps = ExportFrameRate(rawValue: m.fps) ?? .fps30
        let target = compositionExportResolution(CompositionRenderResolution(stored: m.resolution), customWidth: m.customWidth, canvas: canvas)
        let loudness = m.loudness.map { MasterLoudnessTarget(target: $0, truePeak: m.truePeak ?? MasterLoudnessTarget.defaultTruePeak) }
        return ExportSettings(format: format, quality: quality, fps: fps, resolution: target.resolution, customDimensions: target.customDimensions,
                              loudness: loudness)
    }

    /// `{format, quality, fps, resolution, customDimensions?}` as preferences.json stores it.
    static func json(_ m: RenderSettingsModel) -> JSONValue {
        var o: JSONObject = ["format": .string(m.format), "quality": .string(m.quality), "fps": .number(m.fps), "resolution": .string(m.resolution)]
        if m.resolution == "custom" { o["customDimensions"] = .object(["width": .number(m.customWidth), "height": .number(m.customHeight)]) }
        // Off writes nothing, so a document of settings without loudness saves exactly as it did.
        if let target = m.loudness {
            o["loudness"] = .object(["v": .number(1), "target": .number(target), "truePeak": .number(m.truePeak ?? MasterLoudnessTarget.defaultTruePeak)])
        }
        return .object(o)
    }

    /// Validated like getPersistedRenderSettings: unknown values fall back to the defaults.
    static func model(_ v: JSONValue?) -> RenderSettingsModel {
        var m = RenderSettingsModel()
        guard let v else { return m }
        if let f = v["format"]?.string, ExportFormat(rawValue: f) != nil { m.format = f }
        if let q = v["quality"]?.string, ExportQuality(rawValue: q) != nil { m.quality = q }
        if let n = v["fps"]?.number, ExportFrameRate(rawValue: n) != nil { m.fps = n }
        // A choice saved before resolutions followed the composition (a fixed preset) reads as the scale it means.
        if let r = v["resolution"]?.string { m.resolution = CompositionRenderResolution(stored: r).storedValue }
        if let d = v["customDimensions"], let w = d["width"]?.number, let h = d["height"]?.number, w > 0, h > 0 {
            m.customWidth = w; m.customHeight = h
        }
        // An object of another version, or a value the export refuses, reads as Off rather than being clamped.
        if let l = v["loudness"], l["v"]?.number == 1, let target = l["target"]?.number, let ceiling = l["truePeak"]?.number,
           MasterLoudnessTarget(target: target, truePeak: ceiling).issue == nil {
            m.loudness = target
            m.truePeak = ceiling == MasterLoudnessTarget.defaultTruePeak ? nil : ceiling
        }
        return m
    }
}

extension SessionPanels {
    var preferences: DesktopPreferences { session.preferences(userData: userData) }

    func wireRenders() {
        rendersPanel.settings = RenderSettingsBridge.model(preferences.renderSettings)
        let store = RenderPresetStore(userData: userData)
        do { rendersPanel.renderPresets = try store.load() }
        catch {
            let reason = (error as? RenderPresetStoreError)?.reason
            rendersPanel.actionError = reason ?? "The render presets could not be loaded."
        }
        rendersPanel.onSavePreset = { [weak self] name, settings in
            guard let self else { return }
            do {
                self.rendersPanel.renderPresets = try store.save(name: name, settings: settings)
                self.rendersPanel.presetName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                self.rendersPanel.actionError = nil
            } catch {
                let reason = (error as? RenderPresetStoreError)?.reason
                self.rendersPanel.actionError = reason ?? "The preset could not be saved."
            }
            self.redraw()
        }
        rendersPanel.onDeletePreset = { [weak self] name in
            guard let self else { return }
            do {
                self.rendersPanel.renderPresets = try store.delete(name: name)
                self.rendersPanel.presetName = ""
                self.rendersPanel.actionError = nil
            } catch {
                let reason = (error as? RenderPresetStoreError)?.reason
                self.rendersPanel.actionError = reason ?? "The preset could not be deleted."
            }
            self.redraw()
        }
        rendersPanel.onSetPresetComposition = { [weak self] name, composition in
            guard let self else { return }
            do {
                let presets = try store.setComposition(name: name, composition)
                self.rendersPanel.renderPresets = presets
                self.rendersPanel.versions.setPresets(presets)
                self.rendersPanel.actionError = nil
            } catch {
                self.rendersPanel.actionError = (error as? RenderPresetStoreError)?.reason ?? "The preset could not be saved."
            }
            self.redraw()
        }
        rendersPanel.onExportVersions = { [weak self] names in
            guard let self else { return }
            // In the order of the list, whatever order the card names them in.
            self.startVersions(self.rendersPanel.renderPresets.filter { names.contains($0.name) })
        }
        rendersPanel.onSettingsChanged = { [weak self] m in self?.preferences.renderSettings = RenderSettingsBridge.json(m) }
        rendersPanel.onRender = { [weak self] action in self?.renderAction(action) }
    }

    /// Re-reads the project's render history (finished exports in its renders folder).
    func refreshRenders() {
        guard let backend, let projectId else { renders.history = []; publishRenders(); return }
        renders.hidden = Set(preferences.hiddenRenders(projectId: projectId))
        let post = uiPost
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try backend.renders(projectId: projectId) }
            post {
                guard let self, self.projectId == projectId else { return }
                switch result {
                case .success(let list): self.renders.history = list; self.renders.loadError = nil
                case .failure(let e):
                    self.renders.loadError = (e as? DesktopError)?.message ?? "Couldn't load render history."
                }
                self.publishRenders()
            }
        }
    }

    /// Pushes the queue into the Renders tab.
    func publishRenders() {
        let rows = renders.rows { [weak self] path in self?.session.mediaThumbnails.frame(path: path, at: 0, width: 160, height: 90) }
        rendersPanel.jobs = rows
        let lastMs = renders.active.last(where: { $0.view.status == .complete }).flatMap { a in renders.history.first { $0.id == a.id }?.durationMs }
            ?? renders.history.first(where: { $0.status != "failed" })?.durationMs
        rendersPanel.lastRenderSeconds = lastMs.map { $0 / 1000 }
        if let e = renders.loadError, rendersPanel.actionError == nil { rendersPanel.actionError = e }
        redraw()
    }

    func renderAction(_ action: RenderAction) {
        rendersPanel.actionError = nil
        switch action {
        case .start(let settings): startRender(settings)
        case .retry(let id):
            if let preset = renders.active.first(where: { $0.id == id })?.preset { startVersions([preset]); break }
            let settings = renders.active.first { $0.id == id }?.settings ?? rendersPanel.settings
            startRender(settings)
        case .cancel(let id):
            // A version still waiting never starts; one that renders stops. The others in the run carry on.
            if renders.batch?.cancelQueued(id) == true {
                updateActive(id) { $0.view.status = .cancelled; $0.view.stage = "Cancelled" }
            } else { renders.active.first { $0.id == id }?.run?.cancel() }
        case .delete(let id): deleteRender(id)
        case .reveal(let id):
            if let path = renders.active.first(where: { $0.id == id })?.outputPath ?? renders.history.first(where: { $0.id == id })?.path {
                revealPath?(path)
            }
        case .hideFinished:
            guard let projectId else { return }
            let finished = rendersPanel.jobs.filter { $0.status != .rendering && $0.status != .queued }.map(\.id)
            let fileIds = finished.map { renders.fileId($0) }
            renders.hidden.formUnion(finished + fileIds)
            preferences.setHiddenRenders(projectId: projectId, preferences.hiddenRenders(projectId: projectId) + fileIds)
            publishRenders()
        case .publish:
            rendersPanel.actionError = "Publishing is not part of the desktop app."
            redraw()
        }
    }

    func deleteRender(_ id: String) {
        guard let backend, let projectId else { return }
        renders.active.first { $0.id == id }?.run?.cancel()
        _ = renders.batch?.cancelQueued(id)
        let fileId = renders.fileId(id)
        do {
            try backend.deleteRender(projectId: projectId, id: fileId)
            if let path = renders.active.first(where: { $0.id == id })?.outputPath ?? renders.history.first(where: { $0.id == id })?.path {
                session.mediaThumbnails.forget(path: path)
            }
            renders.active.removeAll { $0.id == id }
            renders.history.removeAll { $0.id == fileId }
            publishRenders()
        } catch {
            rendersPanel.actionError = "Couldn't delete the render — it's still on disk."
            redraw()
        }
    }

    /// Saves, then hands the export to RenderRun (output path, export source, progress/cancel, history record),
    /// with its row in the queue from the moment it is queued.
    func startRender(_ model: RenderSettingsModel) {
        guard let backend, let projectId else {
            rendersPanel.actionError = "Nothing to export from: open or create a project first (the demo timeline has no project folder)."
            redraw(); return
        }
        guard !rendersPanel.isRendering else { return }
        if let failure = session.flushSave() { rendersPanel.actionError = "Save the project before rendering: \(failure)"; redraw(); return }
        let settings = RenderSettingsBridge.exportSettings(model, canvas: session.editor.document.canvas)
        let jobId = "render-" + UUID().uuidString.lowercased()
        let run: RenderRun
        do {
            var request = RenderRequest(projectId: projectId, document: session.editor.document, settings: settings,
                                        settingsJSON: RenderSettingsBridge.json(model))
            request.jobId = jobId; request.keyframeEngine = session.engine
            run = try launchRender(backend, request)
        } catch {
            let message = (error as? DesktopError)?.message ?? "\(error)"
            FileHandle.standardError.write(Data("[MpVFX] export could not start: \(message)\n".utf8))
            rendersPanel.actionError = message; redraw(); return
        }
        let name = (run.outputPath as NSString).lastPathComponent
        renders.active.append(.init(id: jobId, run: run, view: RenderJobView(id: jobId, name: name, status: .queued, stage: "Preparing", createdAt: Date().timeIntervalSince1970),
                                    settings: model, outputPath: run.outputPath))
        publishRenders()
    }

    /// Starts `request` and reports its progress and end to the queue under the request's job id.
    private func launchRender(_ backend: DesktopBackend, _ request: RenderRequest) throws -> RenderRun {
        let jobId = request.jobId, post = uiPost
        var callbacks = RenderCallbacks { [weak self] outcome, ms in post { self?.renderFinished(jobId, outcome, durationMs: ms) } }
        callbacks.started = { [weak self] _ in post { self?.updateActive(jobId) { $0.view.status = .rendering; $0.view.stage = "Rendering" } } }
        callbacks.progress = { [weak self] p in post { self?.renderProgress(jobId, p) } }
        return try RenderRun.start(backend: backend, request, callbacks)
    }

    /// The open project's folder name, which names its exports.
    var projectName: String {
        let name = session.project.map { ($0.directory as NSString).lastPathComponent } ?? ""
        return name.isEmpty ? "Project" : name
    }

    /// Export versions (⇧⌘R): one render per preset, named "<project> – <preset>", run one after another. Every
    /// version is queued at once so each has its own row with its own cancel and retry; the project is saved and
    /// read once, so every version renders the same edit.
    func startVersions(_ presets: [RenderPreset]) {
        rendersPanel.actionError = nil
        guard backend != nil, let projectId else {
            rendersPanel.actionError = "Nothing to export from: open or create a project first (the demo timeline has no project folder)."
            redraw(); return
        }
        guard !presets.isEmpty else { rendersPanel.actionError = "Choose at least one preset to export."; redraw(); return }
        guard !rendersPanel.isRendering else {
            rendersPanel.actionError = "Wait for the renders in progress to finish, then export versions."
            redraw(); return
        }
        if let failure = session.flushSave() { rendersPanel.actionError = "Save the project before rendering: \(failure)"; redraw(); return }
        let document = session.editor.document
        let versions: [RenderVersion]
        do {
            versions = try presets.map {
                try RenderVersion.make($0, project: projectName, document: document, natural: session.editor.naturalSize, engine: session.engine)
            }
        } catch {
            rendersPanel.actionError = (error as? RenderVersionError)?.message ?? "The versions could not be prepared."
            redraw(); return
        }
        let batch = RenderBatch(projectId: projectId, versions: versions)
        let now = Date().timeIntervalSince1970
        // The list shows the newest render first, so the first version goes in last.
        for item in batch.items.reversed() {
            let file = item.version.fileStem + "." + item.version.settings.format.rawValue
            renders.active.append(.init(id: item.jobId, run: nil,
                                        view: RenderJobView(id: item.jobId, name: file, status: .queued, stage: "Waiting", createdAt: now),
                                        settings: item.version.model, outputPath: "", preset: item.version.preset))
        }
        renders.batch = batch
        advanceBatch()
    }

    /// Starts the next waiting version once the one before it has ended. Versions queued for another project than
    /// the open one are dropped (they would render the wrong document).
    func advanceBatch() {
        guard let started = renders.batch else { return }
        if started.projectId != projectId || backend == nil {
            for item in started.items where renders.batch?.cancelQueued(item.jobId) == true {
                updateActive(item.jobId) { $0.view.status = .cancelled; $0.view.stage = "Cancelled" }
            }
        }
        guard let batch = renders.batch, let next = batch.nextToStart else {
            if renders.batch?.isFinished == true { renders.batch = nil }
            return
        }
        startVersion(next)
    }

    private func startVersion(_ item: RenderBatch.Item) {
        guard let backend, let projectId else { return }
        let run: RenderRun
        do {
            var request = RenderRequest(projectId: projectId, document: item.version.document, settings: item.version.settings,
                                        settingsJSON: RenderSettingsBridge.json(item.version.model))
            request.jobId = item.jobId; request.keyframeEngine = session.engine; request.fileStem = item.version.fileStem
            run = try launchRender(backend, request)
        } catch {
            let message = (error as? DesktopError)?.message ?? "The export could not start."
            FileHandle.standardError.write(Data("[MpVFX] export version could not start: \(error)\n".utf8))
            renders.batch?.set(item.jobId, .failed)
            renderFailed(item.jobId, message)
            advanceBatch()
            return
        }
        renders.batch?.set(item.jobId, .rendering)
        updateActive(item.jobId) {
            $0.run = run; $0.outputPath = run.outputPath
            $0.view.name = (run.outputPath as NSString).lastPathComponent; $0.view.stage = "Preparing"
        }
    }

    private func updateActive(_ id: String, _ body: (inout RenderQueueState.Active) -> Void) {
        guard let i = renders.active.firstIndex(where: { $0.id == id }) else { return }
        body(&renders.active[i])
        publishRenders()
    }

    func renderProgress(_ id: String, _ p: ExportProgress) {
        updateActive(id) { a in
            guard a.view.status == .rendering || a.view.status == .queued else { return }
            a.view.status = .rendering; a.view.progress = max(0, min(1, p.percent / 100)); a.view.stage = p.stage
        }
    }

    /// A failed export shows its reason on its row and in the panel's error banner (and in the log).
    func renderFailed(_ id: String, _ message: String) {
        FileHandle.standardError.write(Data("[MpVFX] export \(id) failed: \(message)\n".utf8))
        rendersPanel.actionError = "Export failed: \(message)"
        updateActive(id) { $0.view.status = .failed; $0.view.error = message; $0.view.stage = "" }
    }

    func renderFinished(_ id: String, _ outcome: ExportOutcome, durationMs: Double) {
        switch outcome {
        case .completed(let path, let size, _):
            print("[MpVFX] export \(id) complete: \(path) (\(Int(size)) bytes)")
            updateActive(id) { a in
                a.view.status = .complete; a.view.progress = 1; a.view.stage = "Complete"
                a.view.detail = RenderQueueState.detail(size: Int64(size), durationMs: durationMs)
                a.view.sizeBytes = Double(size); a.view.durationMs = durationMs
            }
        case .cancelled:
            updateActive(id) { $0.view.status = .cancelled; $0.view.stage = "Cancelled" }
        case .failed(let message):
            renderFailed(id, message)
        }
        if renders.batch?.item(id) != nil {
            switch outcome {
            case .completed: renders.batch?.set(id, .complete)
            case .cancelled: renders.batch?.set(id, .cancelled)
            case .failed: renders.batch?.set(id, .failed)
            }
            advanceBatch()
        }
        refreshRenders()
    }
}

extension EditorSession {
    /// `<userData>/preferences.json` (render settings, hidden renders, the Settings window), opened once per session.
    /// The backend's copy when it has one, so a setting the backend reads (the default export folder) is the one the
    /// window wrote, and neither copy overwrites the other's keys.
    func preferences(userData: String) -> DesktopPreferences {
        if let p = desktopPreferences { return p }
        let path = (userData as NSString).appendingPathComponent("preferences.json")
        let p = backend?.preferences.flatMap { $0.path == path ? $0 : nil } ?? DesktopPreferences(userData: userData)
        desktopPreferences = p
        return p
    }
}

extension RenderQueueState {
    /// "-23.0 LUFS target, measured -23.1" for a render with a loudness target; "-23.0 LUFS target" when it has no
    /// measurement; nil without a target.
    static func loudnessLabel(target: Double?, measured: Double?) -> String? {
        guard let target else { return nil }
        let label = String(format: "%.1f LUFS target", target)
        guard let measured else { return label }
        return label + String(format: ", measured %.1f", measured)
    }
}
