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
import MpvfxTimeline
import MpvfxAudioGraph

/// What to play while a preset or effect is auditioned: the open document with the hovered chain in place of the
/// stored one (never committed), and the timeline spans the chain is heard over.
public struct AuditionRequest: Equatable {
    public var document: NativeProjectDocument
    /// [start, end) in composition seconds of the clips the chain plays on.
    public var spans: [ClosedRange<Double>]

    public init(document: NativeProjectDocument, spans: [ClosedRange<Double>]) { self.document = document; self.spans = spans }
}

/// Audition (useFxAudition / useAuditionTransport): hovering a preset on the preset shelf, or a job or effect on
/// the add shelf, plays the chain it would make without writing it; moving off, closing the shelf, or the rack
/// going away puts the stored chain back. Picking the hovered item commits it on top of the STORED chain (never on
/// top of the audition, which would run the effect twice) and ends the audition. A Tone module arrives flat, so
/// it has no audition of its own.
extension InspectorPanel {
    /// The chain a shelf item would make from `chain` (the same builders the picks commit), nil for items with none.
    public static func auditionChain(_ chain: FxChain, key: String) -> FxChain? {
        if key.hasPrefix("preset:"), let p = AudioFxPresets.preset(String(key.dropFirst(7))) { return AudioFxPresets.apply(chain, p) }
        if key.hasPrefix("job:"), let job = AudioFxJobs.all.first(where: { $0.id == String(key.dropFirst(4)) }) {
            return FxChain(nodes: chain.nodes + [AudioFxJobs.node(job, joining: chain)])
        }
        if key.hasPrefix("add:") {
            let id = String(key.dropFirst(4))
            guard AudioFx.definitions.contains(where: { $0.id == id }), !AudioFxJobs.types.contains(id) else { return nil }
            return FxChain(nodes: chain.nodes + [AudioFxJobs.effectNode(id, joining: chain)])
        }
        return nil
    }

    /// The rack's owner as it is stored: the selected clip's chain or the open bus's, with how to place a chain in a
    /// copy of the document and where it is heard.
    func auditionOwner(_ editor: TimelineEditor) -> (chain: FxChain, place: (FxChain) -> NativeProjectDocument, spans: [ClosedRange<Double>])? {
        let doc = editor.document
        let fps = doc.frameRate.numerator / max(doc.frameRate.denominator, 1e-9)
        func span(_ c: NativeProjectClip) -> ClosedRange<Double> { (c.startFrame / fps)...((c.startFrame + c.durationFrames) / fps) }
        func serialized(_ ch: FxChain) -> String? { ch.nodes.isEmpty ? nil : AudioFx.serializeChain(ch) }
        if let g = selectedBus() {
            let chain = (try? g.fxChain.map(AudioFx.parseChain)) ?? nil ?? FxChain()
            let spans = doc.sequence.tracks.flatMap(\.clips).filter { $0.audioGroupId == g.id }.map(span)
            return (chain, { ch in
                var d = doc
                if let i = d.sequence.audioGroups?.firstIndex(where: { $0.id == g.id }) { d.sequence.audioGroups?[i].fxChain = serialized(ch) }
                return d
            }, spans)
        }
        guard let s = selected(), s.hasAudio else { return nil }
        let chain = (try? s.clip.audioFxChain.map(AudioFx.parseChain)) ?? nil ?? FxChain()
        return (chain, { ch in
            var d = doc
            for t in d.sequence.tracks.indices {
                if let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == s.id }) { d.sequence.tracks[t].clips[i].audioFxChain = serialized(ch) }
            }
            return d
        }, [span(s.clip)])
    }

    /// Starts, switches or ends the audition after the hovered control changed.
    func updateAudition() {
        var key: String?
        if case .button(let k)? = hovered, audioFxUI.menu != .none,
           k.hasPrefix("preset:") || k.hasPrefix("job:") || k.hasPrefix("add:") { key = k }
        guard key != auditionKey else { return }
        guard let key, let editor, let owner = auditionOwner(editor), let next = Self.auditionChain(owner.chain, key: key) else {
            endAudition(); return
        }
        auditionKey = key
        onAudition?(AuditionRequest(document: owner.place(next), spans: owner.spans))
    }

    /// Ends any audition: the live graph follows the document again and the transport goes back where it was.
    public func endAudition() {
        guard auditionKey != nil else { return }
        auditionKey = nil
        onAudition?(nil)
    }
}

/// useAuditionTransport: where playback starts for an audition. Inside a span the playhead stays; outside, the
/// next span's start (else the first); nil when there is nothing to hear.
public enum AuditionTransport {
    public static func start(_ spans: [ClosedRange<Double>], at t: Double) -> Double? {
        guard !spans.isEmpty else { return nil }
        if spans.contains(where: { t >= $0.lowerBound && t < $0.upperBound }) { return t }
        let starts = spans.map(\.lowerBound).sorted()
        return starts.first { $0 > t } ?? starts.first
    }
}

/// The host's side of an audition (useFxAudition + useAuditionTransport): holds the document the live audio graph
/// plays instead of the open one, and starts the transport for a paused author (recording where the playhead was,
/// then seeking into a span the chain plays on) and puts it back on the way out. Already playing, the transport is
/// left alone in both directions. The open document, its undo history and export never see the audition.
public final class AuditionPlayback {
    /// The document the live graph should play while an audition runs (nil: the open document).
    public private(set) var document: NativeProjectDocument?
    /// Where the playhead was when this audition started the transport (nil: it did not start it).
    public private(set) var returnTo: Double?

    public init() {}

    public var isActive: Bool { document != nil }

    /// Starts, switches or ends (`nil`) the audition. `graphChanged` runs after the live document changed: on a
    /// start before the transport runs (so the first thing heard is the auditioned chain), on an end after it
    /// stopped (so the last thing heard is still the audition). Returns true when this started the transport.
    @discardableResult
    public func apply(_ request: AuditionRequest?, playback: PlaybackState, graphChanged: () -> Void) -> Bool {
        if let request {
            document = request.document
            graphChanged()
            guard !playback.isPlaying, returnTo == nil else { return false }
            returnTo = playback.currentTime
            if let from = AuditionTransport.start(request.spans, at: playback.currentTime), from != playback.currentTime { playback.seek(from) }
            playback.play()
            return true
        }
        guard document != nil else { return false }
        if let back = returnTo {
            returnTo = nil
            playback.pause()
            playback.seek(back)
        }
        document = nil
        graphChanged()
        return false
    }
}
