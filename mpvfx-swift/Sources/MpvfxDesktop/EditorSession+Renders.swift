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
    }
    var active: [Active] = []
    var history: [DesktopRender] = []
    var hidden: Set<String> = []
    var loadError: String?

    mutating func reset() { active.removeAll { $0.view.status != .rendering && $0.view.status != .queued }; history = []; hidden = []; loadError = nil }

    /// Newest first: this session's exports, then history entries they do not already cover.
    var rows: [RenderJobView] { rows(thumbnail: { _ in nil }) }
    func rows(thumbnail: (String) -> CanvasImage?) -> [RenderJobView] {
        let mine = Set(active.map(\.id))
        let fromHistory = history.filter { !mine.contains($0.id) }.map { r -> RenderJobView in
            RenderJobView(id: r.id, name: r.filename, status: r.status == "failed" ? .failed : .complete, stage: "",
                          progress: 1, detail: RenderQueueState.detail(size: r.size, durationMs: r.durationMs),
                          error: r.status == "failed" ? "Render failed" : nil, thumbnail: r.status == "failed" ? nil : thumbnail(r.path),
                          createdAt: r.createdAt > 0 ? r.createdAt : nil, sizeBytes: r.size > 0 ? Double(r.size) : nil, durationMs: r.durationMs)
        }
        let current = active.reversed().map { a -> RenderJobView in
            var v = a.view
            if v.status == .complete, v.thumbnail == nil { v.thumbnail = thumbnail(a.outputPath) }
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
        return ExportSettings(format: format, quality: quality, fps: fps, resolution: target.resolution, customDimensions: target.customDimensions)
    }

    /// `{format, quality, fps, resolution, customDimensions?}` as preferences.json stores it.
    static func json(_ m: RenderSettingsModel) -> JSONValue {
        var o: JSONObject = ["format": .string(m.format), "quality": .string(m.quality), "fps": .number(m.fps), "resolution": .string(m.resolution)]
        if m.resolution == "custom" { o["customDimensions"] = .object(["width": .number(m.customWidth), "height": .number(m.customHeight)]) }
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
        return m
    }
}

extension SessionPanels {
    var preferences: DesktopPreferences { session.preferences(userData: userData) }

    func wireRenders() {
        right.settings = RenderSettingsBridge.model(preferences.renderSettings)
        right.onSettingsChanged = { [weak self] m in self?.preferences.renderSettings = RenderSettingsBridge.json(m) }
        right.onRender = { [weak self] action in self?.renderAction(action) }
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
                case .failure(let e): self.renders.loadError = "Couldn't load render history (\(e))."
                }
                self.publishRenders()
            }
        }
    }

    /// Pushes the queue into the Renders tab.
    func publishRenders() {
        let rows = renders.rows { [weak self] path in self?.session.mediaThumbnails.frame(path: path, at: 0, width: 160, height: 90) }
        right.jobs = rows
        let lastMs = renders.active.last(where: { $0.view.status == .complete }).flatMap { a in renders.history.first { $0.id == a.id }?.durationMs }
            ?? renders.history.first(where: { $0.status != "failed" })?.durationMs
        right.lastRenderSeconds = lastMs.map { $0 / 1000 }
        if let e = renders.loadError, right.actionError == nil { right.actionError = e }
        redraw()
    }

    func renderAction(_ action: RenderAction) {
        right.actionError = nil
        switch action {
        case .start(let settings): startRender(settings)
        case .retry(let id):
            let settings = renders.active.first { $0.id == id }?.settings ?? right.settings
            startRender(settings)
        case .cancel(let id): renders.active.first { $0.id == id }?.run?.cancel()
        case .delete(let id): deleteRender(id)
        case .reveal(let id):
            if let path = renders.active.first(where: { $0.id == id })?.outputPath ?? renders.history.first(where: { $0.id == id })?.path {
                revealPath?(path)
            }
        case .hideFinished:
            guard let projectId else { return }
            let finished = right.jobs.filter { $0.status != .rendering && $0.status != .queued }.map(\.id)
            renders.hidden.formUnion(finished)
            preferences.setHiddenRenders(projectId: projectId, preferences.hiddenRenders(projectId: projectId) + finished)
            publishRenders()
        case .publish:
            right.actionError = "Publishing is not part of the desktop app."
            redraw()
        }
    }

    func deleteRender(_ id: String) {
        guard let backend, let projectId else { return }
        renders.active.first { $0.id == id }?.run?.cancel()
        do {
            try backend.deleteRender(projectId: projectId, id: id)
            if let path = renders.active.first(where: { $0.id == id })?.outputPath ?? renders.history.first(where: { $0.id == id })?.path {
                session.mediaThumbnails.forget(path: path)
            }
            renders.active.removeAll { $0.id == id }
            renders.history.removeAll { $0.id == id }
            publishRenders()
        } catch {
            right.actionError = "Couldn't delete the render — it's still on disk."
            redraw()
        }
    }

    /// Saves, then hands the export to RenderRun (output path, export source, progress/cancel, history record),
    /// with its row in the queue from the moment it is queued.
    func startRender(_ model: RenderSettingsModel) {
        guard let backend, let projectId else {
            right.actionError = "Nothing to export from: open or create a project first (the demo timeline has no project folder)."
            redraw(); return
        }
        guard !right.isRendering else { return }
        if let failure = session.flushSave() { right.actionError = "Save the project before rendering: \(failure)"; redraw(); return }
        let settings = RenderSettingsBridge.exportSettings(model, canvas: session.editor.document.canvas)
        let jobId = "render-" + UUID().uuidString.lowercased()
        let post = uiPost
        let run: RenderRun
        do {
            var request = RenderRequest(projectId: projectId, document: session.editor.document, settings: settings,
                                        settingsJSON: RenderSettingsBridge.json(model))
            request.jobId = jobId; request.keyframeEngine = session.engine
            var callbacks = RenderCallbacks { outcome, ms in post { [weak self] in self?.renderFinished(jobId, outcome, durationMs: ms) } }
            callbacks.started = { _ in post { [weak self] in self?.updateActive(jobId) { $0.view.status = .rendering; $0.view.stage = "Rendering" } } }
            callbacks.progress = { p in post { [weak self] in self?.renderProgress(jobId, p) } }
            run = try RenderRun.start(backend: backend, request, callbacks)
        } catch {
            let message = (error as? DesktopError)?.message ?? "\(error)"
            FileHandle.standardError.write(Data("[MpVFX] export could not start: \(message)\n".utf8))
            right.actionError = message; redraw(); return
        }
        let name = (run.outputPath as NSString).lastPathComponent
        renders.active.append(.init(id: jobId, run: run, view: RenderJobView(id: jobId, name: name, status: .queued, stage: "Preparing", createdAt: Date().timeIntervalSince1970),
                                    settings: model, outputPath: run.outputPath))
        publishRenders()
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
        right.actionError = "Export failed: \(message)"
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
        refreshRenders()
    }
}

extension EditorSession {
    /// `<userData>/preferences.json` (render settings, hidden renders), opened once per session.
    func preferences(userData: String) -> DesktopPreferences {
        if let p = desktopPreferences { return p }
        let p = DesktopPreferences(userData: userData)
        desktopPreferences = p
        return p
    }
}
