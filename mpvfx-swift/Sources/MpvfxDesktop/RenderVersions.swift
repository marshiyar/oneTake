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
// "Export versions": one render per checked export preset, run one after another (#334). A version is what one
// preset renders (its settings, and the project at the preset's composition size when it has one); the batch is
// the order they run in and what became of each.
import Foundation
import MpvfxShared
import MpvfxRuntime
import MpvfxPanels

struct RenderVersionError: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// What one preset renders. `document` is a copy: a preset with its own composition size renders the project refit
/// to that size (nativeDocumentResizingCanvas, the rules of a composition size change) while the open project keeps
/// the size it has.
struct RenderVersion {
    var presetName: String
    var preset: RenderPreset
    var model: RenderSettingsModel
    var document: NativeProjectDocument
    var settings: ExportSettings
    /// The output file's name without extension, "<project> – <preset>".
    var fileStem: String

    /// "<project> – <preset>" as the file will be named (no separators or colons), so the queued row shows its final name.
    static func fileStem(project: String, preset: String) -> String {
        let joined = "\(project) – \(preset)"
        return ProjectRenders.safeFileStem(joined) ?? joined
    }

    static func make(_ preset: RenderPreset, project: String, document: NativeProjectDocument,
                     natural: (NativeProjectAsset) -> NativeMediaNaturalSize?, engine: KeyframeEngine?) throws -> RenderVersion {
        guard preset.hasValidSettings else { throw RenderVersionError(message: "The preset \"\(preset.name)\" has settings that cannot be used.") }
        if let reason = preset.unavailableReason { throw RenderVersionError(message: "The preset \"\(preset.name)\": \(reason).") }
        var versionDocument = document
        if let size = preset.composition, size.width != document.canvas.width || size.height != document.canvas.height {
            do {
                versionDocument = try nativeDocumentResizingCanvas(document, width: size.width, height: size.height,
                                                                   natural: natural, engine: engine)
            } catch {
                let reason = (error as? NativeCanvasSizeError)?.message ?? "the project cannot be fitted to that size."
                throw RenderVersionError(message: "The preset \"\(preset.name)\" cannot render at \(Int(size.width)) × \(Int(size.height)): \(reason)")
            }
        }
        return RenderVersion(presetName: preset.name, preset: preset, model: preset.settings, document: versionDocument,
                             settings: RenderSettingsBridge.exportSettings(preset.settings, canvas: versionDocument.canvas),
                             fileStem: fileStem(project: project, preset: preset.name))
    }
}

/// The versions of one run, in the order they render. Only one renders at a time; cancelling one affects only that
/// version, so the ones before it stay finished and the ones after it stay queued and still run.
struct RenderBatch {
    enum State: Equatable { case queued, rendering, complete, cancelled, failed }
    struct Item {
        var jobId: String
        var version: RenderVersion
        var state: State = .queued
    }

    let projectId: String
    private(set) var items: [Item]

    init(projectId: String, versions: [RenderVersion], newJobId: () -> String = { "render-" + UUID().uuidString.lowercased() }) {
        self.projectId = projectId
        items = versions.map { Item(jobId: newJobId(), version: $0) }
    }

    /// The version to start now: the first queued one, and only when none is rendering.
    var nextToStart: Item? {
        items.contains { $0.state == .rendering } ? nil : items.first { $0.state == .queued }
    }
    var isFinished: Bool { !items.contains { $0.state == .queued || $0.state == .rendering } }
    func item(_ jobId: String) -> Item? { items.first { $0.jobId == jobId } }
    func state(_ jobId: String) -> State? { item(jobId)?.state }

    /// Moves a version along; a finished version stays as it ended (a late callback cannot revive it).
    mutating func set(_ jobId: String, _ state: State) {
        guard let i = items.firstIndex(where: { $0.jobId == jobId }) else { return }
        switch items[i].state {
        case .queued, .rendering: items[i].state = state
        case .complete, .cancelled, .failed: break
        }
    }

    /// Cancels a version that has not started; it never renders. False when it is not waiting.
    mutating func cancelQueued(_ jobId: String) -> Bool {
        guard state(jobId) == .queued else { return false }
        set(jobId, .cancelled)
        return true
    }
}
