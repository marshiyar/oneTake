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
import Foundation

// Voice room: ducking automation for a bed (music or ambience) from the speech regions of a voice clip.
// A pure plan: regions and settings in, volume points tagged `origin: voice-room` out. Re-running replaces
// only those points; points drawn by hand stay. Times are seconds from the start of the bed clip.

public struct VoiceRoomSettings: Equatable, Sendable {
    public var amountDb: Double
    public var attackMs: Double
    public var releaseMs: Double
    public var holdMs: Double
    public init(amountDb: Double = -12, attackMs: Double = 250, releaseMs: Double = 400, holdMs: Double = 500) {
        self.amountDb = amountDb; self.attackMs = attackMs; self.releaseMs = releaseMs; self.holdMs = holdMs
    }
    /// Values clamped to what the plan accepts: a dip of 0 to −60 dB, ramps 1 ms to 5 s, hold 0 to 10 s.
    var clamped: VoiceRoomSettings {
        func fix(_ v: Double, _ lo: Double, _ hi: Double, _ d: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : d }
        return VoiceRoomSettings(amountDb: fix(amountDb, -60, 0, -12), attackMs: fix(attackMs, 1, 5000, 250),
                                 releaseMs: fix(releaseMs, 1, 5000, 400), holdMs: fix(holdMs, 0, 10_000, 500))
    }
}

public struct SpeechRegion: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public enum VoiceRoom {
    public static let origin = "voice-room"

    /// Speech regions after clean-up: unreadable or empty ones dropped, sorted, and merged when the gap between
    /// them is shorter than the hold (the bed stays dipped through a breath) or too short for the bed to come back.
    static func merged(_ regions: [SpeechRegion], _ s: VoiceRoomSettings) -> [SpeechRegion] {
        let sorted = regions.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .map { SpeechRegion(start: max(0, $0.start), end: max(0, $0.end)) }
            .filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let minGap = max(s.holdMs, s.attackMs + s.releaseMs) / 1000
        var out: [SpeechRegion] = []
        for r in sorted {
            if let last = out.last, r.start - last.end < minGap { out[out.count - 1].end = max(last.end, r.end) } else { out.append(r) }
        }
        return out
    }

    /// The ducking points for `regions`: full level one attack before speech, the dip while it lasts, full level
    /// one release after it.
    public static func points(regions: [SpeechRegion], settings: VoiceRoomSettings = .init()) -> [AutomationPoint] {
        let s = settings.clamped
        let dip = pow(10, s.amountDb / 20)
        var out: [AutomationPoint] = []
        for r in merged(regions, s) {
            out.append(AutomationPoint(t: max(0, r.start - s.attackMs / 1000), v: 1, origin: origin))
            out.append(AutomationPoint(t: r.start, v: dip, origin: origin))
            out.append(AutomationPoint(t: r.end, v: dip, origin: origin))
            out.append(AutomationPoint(t: r.end + s.releaseMs / 1000, v: 1, origin: origin))
        }
        return out
    }

    /// `existing` with every voice-room point replaced by the plan for `regions`. Hand-drawn points, other
    /// lanes and the lane's other tags are kept; a plan point that lands on the time of a kept point yields to it.
    public static func apply(to existing: Automation?, regions: [SpeechRegion], settings: VoiceRoomSettings = .init()) -> Automation {
        var lanes = existing?.lanes ?? []
        let index = lanes.firstIndex { $0.target == AudioAutomation.volumeTarget }
        let kept = index.map { lanes[$0].points.filter { $0.origin != origin } } ?? []
        let keptTimes = Set(kept.map(\.t))
        let planned = points(regions: regions, settings: settings).filter { !keptTimes.contains($0.t) }
        let all = kept + planned
        let lane = AutomationLane(target: AudioAutomation.volumeTarget, points: all)
        if let index { lanes[index] = lane } else { lanes.append(lane) }
        return AudioAutomation.normalize(Automation(lanes: lanes))
    }
}
