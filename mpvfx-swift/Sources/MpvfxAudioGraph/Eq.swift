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

/// The parametric EQ (`eq`): one node holding up to eight bands. The band layout lives here once, so the unit that
/// filters, the response the rack draws and the live edits all read the same sections.
public enum AudioFxEq {
    public static let maxBands = 8
    public static let bandTypes = ["bell", "lowshelf", "highshelf", "lowcut", "highcut", "notch"]
    public static let slopes = ["12", "24", "48"]
    /// Butterworth section Qs by cascade length (2, 4 and 8 poles); the band's Q scales all of them.
    static let butterworth: [String: [Double]] = [
        "12": [0.70710678118],
        "24": [0.54119610015, 1.30656296488],
        "48": [0.50979557910, 0.60134488693, 0.89997622313, 2.56291544774],
    ]

    public static func key(_ band: Int, _ name: String) -> String { "band\(band).\(name)" }

    /// One biquad of a band; a cut's cascade has one per Butterworth section.
    public struct Section: Equatable, Sendable {
        public var type: BiquadType
        public var frequency: Double, q: Double, gain: Double
    }

    /// The bands that filter: the first `bands` of them, minus bypassed ones, as band number (1-based) and sections.
    public static func activeBands(_ p: FxParams) -> [(band: Int, sections: [Section])] {
        let count = min(maxBands, max(1, Int(p.num("bands").rounded())))
        return (1...count).compactMap { k in
            guard p[key(k, "bypass")]?.string != "on" else { return nil }
            return (k, sections(p, band: k))
        }
    }

    /// The Float-rounded values the unit's `BiquadFilter` parameters hold, so the response matches the sound exactly.
    static func sections(_ p: FxParams, band k: Int) -> [Section] {
        func f(_ name: String) -> Double { Double(Float(p.num(key(k, name)))) }
        let kind = p[key(k, "type")]?.string ?? "bell"
        let frequency = f("freq"), gain = f("gain"), q = f("q")
        switch kind {
        case "lowshelf": return [Section(type: .lowshelf, frequency: frequency, q: 1, gain: gain)]
        case "highshelf": return [Section(type: .highshelf, frequency: frequency, q: 1, gain: gain)]
        case "notch": return [Section(type: .notch, frequency: frequency, q: q, gain: 0)]
        case "lowcut", "highcut":
            let ratio = q / butterworth["12"]![0]
            return (butterworth[p[key(k, "slope")]?.string ?? "12"] ?? butterworth["12"]!).map {
                Section(type: kind == "lowcut" ? .highpass : .lowpass, frequency: frequency, q: Double(Float($0 * ratio)), gain: 0)
            }
        default: return [Section(type: .peaking, frequency: frequency, q: q, gain: gain)]
        }
    }

    /// The Q a cascade section takes when the band's Q is `q` (live edits and automation).
    static func sectionQ(_ band: String, slope: String, section: Int, q: Double) -> Double {
        guard band == "lowcut" || band == "highcut" else { return q }
        return Double(Float((butterworth[slope] ?? butterworth["12"]!)[section] * q / butterworth["12"]![0]))
    }
}

/// `eq`: every active band's sections in series, each a `BiquadFilter` whose frequency, Q and gain glide on live edits.
final class EqUnit: FxUnit {
    struct Band {
        var kind: String, slope: String
        var filters: [BiquadFilter]
    }
    /// Active bands by band number.
    private(set) var bands: [Int: Band] = [:]
    private let order: [Int]

    init(_ p: FxParams, _ sr: Double) {
        var built: [Int: Band] = [:]
        var order: [Int] = []
        for (k, sections) in AudioFxEq.activeBands(p) {
            let filters = sections.map { s in
                BiquadFilter(s.type, sampleRate: sr, frequency: s.frequency, q: s.q, gain: s.gain, linearPassQ: true)
            }
            built[k] = Band(kind: p[AudioFxEq.key(k, "type")]?.string ?? "bell", slope: p[AudioFxEq.key(k, "slope")]?.string ?? "12", filters: filters)
            order.append(k)
        }
        bands = built
        self.order = order
    }

    func process(_ x: [[Float]], frame: Int) -> [[Float]] {
        var y = x
        for k in order {
            for filter in bands[k]!.filters { y = filter.process(y, frame: frame) }
        }
        return y
    }

    /// The glides that move a band's `name` (freq, gain or q) to `value`; nil when that cannot happen in place.
    /// A band that is not built (bypassed or beyond `bands`) has nothing to move, which is not an error.
    func liveEdit(band k: Int, name: String, value: Double, glideFrames: Int) -> [() -> Void]? {
        guard let band = bands[k] else { return [] }
        var edits: [() -> Void] = []
        for (i, filter) in band.filters.enumerated() {
            let param: ParamTimeline, target: Float
            switch name {
            case "freq": param = filter.frequency; target = Float(value)
            case "gain" where band.kind != "lowcut" && band.kind != "highcut" && band.kind != "notch": param = filter.gain; target = Float(value)
            case "gain": continue
            case "q" where band.kind != "lowshelf" && band.kind != "highshelf":
                param = filter.q; target = Float(AudioFxEq.sectionQ(band.kind, slope: band.slope, section: i, q: value))
            case "q": continue
            default: return nil
            }
            guard !param.hasEvents else { return nil }
            edits.append { param.glide(to: target, frames: glideFrames) }
        }
        return edits
    }

    var automation: [String: [ParamTarget]] {
        var a: [String: [ParamTarget]] = [:]
        for (k, band) in bands {
            a[AudioFxEq.key(k, "freq")] = band.filters.map { ParamTarget(param: $0.frequency, map: nil) }
            if band.kind != "lowcut" && band.kind != "highcut" && band.kind != "notch" {
                a[AudioFxEq.key(k, "gain")] = band.filters.map { ParamTarget(param: $0.gain, map: nil) }
            }
            if band.kind != "lowshelf" && band.kind != "highshelf" {
                a[AudioFxEq.key(k, "q")] = band.filters.enumerated().map { i, f in
                    ParamTarget(param: f.q, map: { AudioFxEq.sectionQ(band.kind, slope: band.slope, section: i, q: $0) })
                }
            }
        }
        return a
    }
}
