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
import MpvfxShared

/// Audio edits:
/// clip gain / mute / FX chain / automation and audio-group buses. One undo step each.
public extension TimelineEditor {
    /// Fader range: 0 ... +12 dB.
    static let maxAudioGain = pow(10.0, 12.0 / 20.0)
    static let audioVolumeParameter = "audio.volume"

    /// Clip gain, linear (1 = 0 dB). Values past +12 dB within the fader's rounding are clamped; others refused.
    @discardableResult
    func setClipVolume(clipId: String, _ gain: Double) -> Bool {
        guard let g = Self.validGain(gain) else { return false }
        return updateAudioClip(clipId, "Set clip volume") { c in
            var p = c.staticParameters ?? [:]; p[Self.audioVolumeParameter] = .number(g); c.staticParameters = p
        }
    }

    func clipVolume(clipId: String) -> Double {
        if case .number(let v)? = clip(clipId)?.clip.staticParameters?[Self.audioVolumeParameter] { return v }
        return 1
    }

    /// Serialized FX chain on the clip (nil removes it).
    @discardableResult
    func setClipFxChain(clipId: String, _ chain: String?) -> Bool {
        updateAudioClip(clipId, "Set clip effects") { $0.audioFxChain = chain?.isEmpty == false ? chain : nil }
    }

    /// Serialized audio automation on the clip (nil removes it).
    @discardableResult
    func setClipAutomation(clipId: String, _ automation: String?) -> Bool {
        updateAudioClip(clipId, "Set clip automation") { $0.audioAutomation = automation?.isEmpty == false ? automation : nil }
    }

    // MARK: Audio groups

    /// Group audio/video clips onto a new bus. Needs two or more clips; a video track joins only whole.
    /// Returns the group id.
    @discardableResult
    func createAudioGroup(clipIds: [String], label: String? = nil) -> String? {
        let ids = Set(clipIds)
        guard ids.count >= 2, ids.count == clipIds.count else { lastFailure = .init(code: .duplicateTarget, message: "An audio group needs at least two distinct clips"); return nil }
        var touched = Set<String>()
        for id in ids {
            guard let a = address(clipId: id), !isTrackLocked(a.trackId), let (_, c) = clip(id),
                  let kind = document.assets.first(where: { $0.id == c.assetId })?.kind, kind == .audio || kind == .video else {
                lastFailure = .init(code: .incompatibleDestination, message: "Clip \(id) is not an audio or video clip"); return nil
            }
            touched.insert(a.trackId)
        }
        let videoAssets = Set(document.assets.filter { $0.kind == .video }.map(\.id))
        for t in document.sequence.tracks where touched.contains(t.id) && t.clips.contains(where: { videoAssets.contains($0.assetId) }) {
            if t.clips.contains(where: { !ids.contains($0.id) }) {
                lastFailure = .init(code: .incompatibleDestination, message: "Select every clip on a video track before grouping its audio"); return nil
            }
        }
        var d = document
        let existing = Set((d.sequence.audioGroups ?? []).map(\.id))
        var n = existing.count + 1
        while existing.contains("audio-group:\(n)") { n += 1 }
        let gid = "audio-group:\(n)"
        d.sequence.audioGroups = (d.sequence.audioGroups ?? []) + [NativeAudioGroup.bus(id: gid, label: label?.isEmpty == false ? label : nil)]
        for ti in d.sequence.tracks.indices {
            for ci in d.sequence.tracks[ti].clips.indices where ids.contains(d.sequence.tracks[ti].clips[ci].id) {
                d.sequence.tracks[ti].clips[ci].audioGroupId = gid
            }
        }
        return commit(d, "Group audio") ? gid : nil
    }

    /// Dissolve a bus: members go back to the master mix.
    @discardableResult
    func removeAudioGroup(_ groupId: String) -> Bool {
        guard document.sequence.audioGroups?.contains(where: { $0.id == groupId }) == true else { return false }
        var d = document
        d.sequence.audioGroups = d.sequence.audioGroups?.filter { $0.id != groupId }
        if d.sequence.audioGroups?.isEmpty == true { d.sequence.audioGroups = nil }
        for ti in d.sequence.tracks.indices {
            for ci in d.sequence.tracks[ti].clips.indices where d.sequence.tracks[ti].clips[ci].audioGroupId == groupId {
                d.sequence.tracks[ti].clips[ci].audioGroupId = nil
            }
        }
        return commit(d, "Ungroup audio")
    }

    @discardableResult func setAudioGroupVolume(_ groupId: String, _ gain: Double) -> Bool {
        guard let g = Self.validGain(gain) else { return false }
        return updateGroup(groupId, "Set group volume") { $0.volume = g }
    }
    @discardableResult func setAudioGroupMuted(_ groupId: String, _ muted: Bool) -> Bool {
        updateGroup(groupId, muted ? "Mute group" : "Unmute group") { $0.muted = muted }
    }
    @discardableResult func setAudioGroupLabel(_ groupId: String, _ label: String?) -> Bool {
        updateGroup(groupId, "Rename group") { $0.label = label?.isEmpty == false ? label : nil }
    }
    @discardableResult func setAudioGroupFxChain(_ groupId: String, _ chain: String?) -> Bool {
        updateGroup(groupId, "Set group effects") { $0.fxChain = chain?.isEmpty == false ? chain : nil }
    }
    @discardableResult func setAudioGroupAutomation(_ groupId: String, _ automation: String?) -> Bool {
        updateGroup(groupId, "Set group automation") { $0.automation = automation?.isEmpty == false ? automation : nil }
    }

    func audioGroup(_ groupId: String) -> NativeAudioGroup? { document.sequence.audioGroups?.first { $0.id == groupId } }

    // MARK: Helpers

    internal static func validGain(_ v: Double) -> Double? {
        // The fader writes six decimals, so +12 dB may round a hair past the limit.
        guard v.isFinite, v >= 0, v <= maxAudioGain + 0.0000005 else { return nil }
        return min(v, maxAudioGain)
    }

    internal func updateAudioClip(_ clipId: String, _ label: String, _ change: (inout NativeProjectClip) -> Void) -> Bool {
        guard !isClipLocked(clipId), let (_, c) = clip(clipId),
              let kind = document.assets.first(where: { $0.id == c.assetId })?.kind, kind == .audio || kind == .video else { return false }
        var d = document
        for ti in d.sequence.tracks.indices {
            if let ci = d.sequence.tracks[ti].clips.firstIndex(where: { $0.id == clipId }) { change(&d.sequence.tracks[ti].clips[ci]) }
        }
        return commit(d, label)
    }

    internal func updateGroup(_ groupId: String, _ label: String, _ change: (inout NativeAudioGroup) -> Void) -> Bool {
        guard let gi = document.sequence.audioGroups?.firstIndex(where: { $0.id == groupId }) else { return false }
        var d = document
        change(&d.sequence.audioGroups![gi])
        return commit(d, label)
    }
}
