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
import MpvfxAudioGraph
import MpvfxShared
import MpvfxTimeline

/// The Make room for voice sheet (issue #310): the settings of the command that lowers music and ambience under speech.
/// It is a card at the top of the inspector, opened from the clip menu, the Audio FX rack or ⌥⌘D. Opening and closing it
/// change nothing in the document; Make room hands a `Run` to the host, which writes the result as one undo step.
public struct VoiceRoomSheet: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable { case volume, carve }

    public struct Clip: Equatable, Sendable {
        public var clipId: String
        public var name: String
        public var kind: AudioCarve.NameKind
        public var start: Double
    }

    public struct Bed: Equatable, Sendable {
        public var clip: Clip
        public var checked: Bool
    }

    /// What the host runs.
    public struct Run: Equatable, Sendable {
        public var mode: Mode
        public var settings: VoiceRoomSettings
        public var voiceClipIds: [String]
        public var bedClipIds: [String]
    }

    public var settings = VoiceRoomSettings()
    public var mode = Mode.volume
    public var voices: [Clip]
    public var beds: [Bed]
    /// The sentence under the fields when a value or the choice of clips cannot be used.
    public var error: String?

    /// The sheet for `selection`: the selected sound clips are the voice; with nothing selected, the clips that read as voice.
    /// Beds are every other sounding clip on an unlocked track, never one that reads as voice; music and ambience start ticked.
    public static func open(_ doc: NativeProjectDocument, selection: [String], previous: Run? = nil) -> VoiceRoomSheet {
        let fps = max(1e-9, doc.frameRate.numerator / max(doc.frameRate.denominator, 1e-9))
        let assets = Dictionary(doc.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var all: [(clip: Clip, writable: Bool)] = []
        for track in doc.sequence.tracks where track.hidden != true {
            for clip in track.clips where clip.hidden != true && clip.holdSourceFrame == nil {
                guard let asset = assets[clip.assetId], asset.kind == .audio || asset.kind == .video else { continue }
                all.append((Clip(clipId: clip.id, name: clip.name?.isEmpty == false ? clip.name! : asset.name,
                                 kind: AudioCarve.classify([clip.name, asset.name]), start: clip.startFrame / fps), track.locked != true))
            }
        }
        // A voice is only read, so it may sit on a locked track; a bed is written, so it may not.
        let chosen = Set(selection)
        var voices = all.map(\.clip).filter { chosen.contains($0.clipId) }
        if voices.isEmpty { voices = all.map(\.clip).filter { $0.kind == .voice } }
        let voiceIds = Set(voices.map(\.clipId))
        let beds = all.filter { $0.writable && $0.clip.kind != .voice && !voiceIds.contains($0.clip.clipId) }.map(\.clip)
            .map { Bed(clip: $0, checked: $0.kind == .music || $0.kind == .sfx) }
        var sheet = VoiceRoomSheet(voices: voices, beds: beds)
        if let previous { sheet.settings = previous.settings; sheet.mode = previous.mode }
        return sheet
    }

    public init(voices: [Clip], beds: [Bed]) { self.voices = voices; self.beds = beds }

    /// The run these settings make, or nil without a voice or a ticked bed.
    public var run: Run? {
        let ticked = beds.filter(\.checked).map(\.clip.clipId)
        guard !voices.isEmpty, !ticked.isEmpty else { return nil }
        return Run(mode: mode, settings: settings, voiceClipIds: voices.map(\.clipId), bedClipIds: ticked)
    }

    /// Why Make room has nothing to do, in words that say what to change.
    public var blocker: String? {
        if voices.isEmpty { return "No voice found. Select the voice clips, or name them so they read as voice." }
        if !beds.contains(where: \.checked) { return "Tick at least one clip to lower." }
        return nil
    }
}

extension InspectorPanel {
    static let voiceRoomGroupId = "voice-room"

    /// Opens the sheet for the current selection and shows it.
    public func openVoiceRoomSheet() {
        guard let editor else { return }
        voiceRoom = VoiceRoomSheet.open(editor.document, selection: selection, previous: lastVoiceRoomRun)
        if openGroupId != Self.voiceRoomGroupId { groupBeforeVoiceRoom = openGroupId }
        openGroupId = Self.voiceRoomGroupId
        onEdited?()
    }

    /// Esc: closes the sheet and changes nothing.
    public func closeVoiceRoomSheet() {
        guard voiceRoom != nil else { return }
        voiceRoom = nil
        if openGroupId == Self.voiceRoomGroupId { openGroupId = groupBeforeVoiceRoom }
        onEdited?()
    }

    /// Enter: hands the run to the host and closes the sheet.
    public func runVoiceRoom() {
        guard var sheet = voiceRoom else { return }
        guard let run = sheet.run else {
            sheet.error = sheet.blocker
            voiceRoom = sheet; onEdited?(); return
        }
        lastVoiceRoomRun = run
        voiceRoom = nil
        if openGroupId == Self.voiceRoomGroupId { openGroupId = groupBeforeVoiceRoom }
        onMakeRoomForVoice?(run)
        onEdited?()
    }

    /// Runs the last settings again over the same clips (the toast's Re-run, the rack's Re-run).
    public func rerunVoiceRoom() {
        guard let run = lastVoiceRoomRun else { return }
        onMakeRoomForVoice?(run)
    }

    /// Esc closes and Enter runs while the sheet is open, unless a button has the focus (it takes the Enter) or a field is being edited.
    func voiceRoomKey(_ k: EditorKey) -> Bool {
        guard voiceRoom != nil, field == nil else { return false }
        if k.code == .escape { closeVoiceRoomSheet(); return true }
        if k.code == .enter, !k.command, !k.alt {
            if focus.visible, case .button? = focus.current { return false }
            runVoiceRoom(); return true
        }
        return false
    }

    func voiceRoomGroup(_ sheet: VoiceRoomSheet) -> InspectorGroup {
        let update: (VoiceRoomSheet) -> Void = { [weak self] next in self?.voiceRoom = next; self?.onEdited?() }
        var rows: [InspectorRow] = []
        let who: String = {
            guard let first = sheet.voices.first else { return "no voice" }
            return sheet.voices.count == 1 ? first.name : "\(first.name) and \(sheet.voices.count - 1) more"
        }()
        rows.append(.init(.note("Lowers the music and ambience under \(who) with ordinary volume points you can adjust. Enter makes room, Esc closes.")))
        func field(_ key: String, _ label: String, _ unit: String, _ value: Double, _ def: Double, _ range: ClosedRange<Double>,
                   _ assign: @escaping (inout VoiceRoomSheet, Double) -> Void) -> InspectorRow {
            let shown = { (v: Double) in String(format: "%g", v) }
            return .init(.number(.init(
                key: key, label: "\(label) (\(unit))", text: shown(value), tier: value == def ? .default : .explicitCustom,
                commit: { text in
                    var next = sheet
                    if let v = PanelFormat.parse(text), v.isFinite, range.contains(v) { assign(&next, v); next.error = nil }
                    else { next.error = "\(label) must be between \(shown(range.lowerBound)) and \(shown(range.upperBound)) \(unit)." }
                    update(next)
                },
                reset: { var next = sheet; assign(&next, def); next.error = nil; update(next) })))
        }
        rows.append(field("vr:amount", "Amount", "dB", sheet.settings.amountDb, -12, -60...0) { $0.settings.amountDb = $1 })
        rows.append(field("vr:attack", "Ramp in", "ms", sheet.settings.attackMs, 250, 1...5000) { $0.settings.attackMs = $1 })
        rows.append(field("vr:release", "Ramp out", "ms", sheet.settings.releaseMs, 400, 1...5000) { $0.settings.releaseMs = $1 })
        rows.append(field("vr:hold", "Hold between phrases", "ms", sheet.settings.holdMs, 500, 0...10_000) { $0.settings.holdMs = $1 })
        rows.append(.init(.segmented(.init(key: "vr:mode", label: "Mode", options: VoiceRoomSheet.Mode.allCases.map {
            (key: $0.rawValue, label: $0 == .volume ? "Volume" : "Carve", active: sheet.mode == $0)
        }, select: { key in
            var next = sheet; next.mode = VoiceRoomSheet.Mode(rawValue: key) ?? .volume; update(next)
        }))))
        rows.append(.init(.heading("Lower these clips", trailing: nil)))
        if sheet.beds.isEmpty { rows.append(.init(.note("There are no other sound clips on unlocked tracks."))) }
        for (i, bed) in sheet.beds.enumerated() {
            rows.append(.init(.toggle(.init(key: "vr:bed:\(i)", label: bed.clip.name, on: bed.checked, set: { on in
                var next = sheet; next.beds[i].checked = on; next.error = nil; update(next)
            }))))
        }
        if let error = sheet.error { rows.append(.init(.note(error))) }
        rows.append(.init(.buttons([
            .init(key: "vr:run", label: "Make room", style: .accent, action: { [weak self] in self?.runVoiceRoom() }),
            .init(key: "vr:cancel", label: "Cancel", style: .muted, action: { [weak self] in self?.closeVoiceRoomSheet() }),
        ])))
        return InspectorGroup(id: Self.voiceRoomGroupId, title: "Make room for voice", summary: sheet.mode == .volume ? "Volume" : "Carve", rows: rows, spacing: 0)
    }

    /// The rack's own entry: open the sheet, or run the last settings again.
    func voiceRoomRackRows() -> [InspectorRow] {
        var buttons: [InspectorRow.Button] = [
            .init(key: "vr:open", label: "Make room for voice…", style: .muted, action: { [weak self] in self?.openVoiceRoomSheet() }),
        ]
        if lastVoiceRoomRun != nil {
            buttons.append(.init(key: "vr:rerun", label: "Re-run", style: .muted, action: { [weak self] in self?.rerunVoiceRoom() }, disabled: onMakeRoomForVoice == nil))
        }
        return [.init(.buttons(buttons))]
    }
}
