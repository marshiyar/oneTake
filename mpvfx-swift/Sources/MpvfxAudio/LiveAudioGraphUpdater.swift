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

/// Turns document edits into graph changes off the UI thread. `submit` is O(1) and never waits on the graph:
/// the newest inputs win and intermediate ones are skipped, so a slider drag or a burst of preset clicks costs
/// one build whenever the worker comes free, not one per edit, and a build still pre-rolling is abandoned for
/// the newer one. Stems decode on the worker (the media engine in the app), cached by key so an edit re-decodes only the
/// clips it changed. Parameter-only edits (EQ band, gain, clip/group volume) reach the running graph in place.
public final class LiveAudioGraphUpdater {
    public let source: GraphAudioSource
    let loadStem: (DocumentAudioGraph.StemKey) throws -> [[Float]]
    let queue = DispatchQueue(label: "mpvfx.audio.graph", qos: .userInitiated)
    let lock = NSLock()
    var pending: DocumentAudioGraph.Inputs?
    var scheduled = false
    var builds_ = 0
    // Worker-only state.
    /// Failures are cached too: an undecodable file is not re-opened on every edit.
    var stemCache: [DocumentAudioGraph.StemKey: Result<[[Float]], Error>] = [:]
    var lastIssues: [String] = []
    /// Called on the worker when the set of problems (unparseable FX, undecodable audio) changes.
    public var onIssues: (([String]) -> Void)?

    public init(source: GraphAudioSource, loadStem: @escaping (DocumentAudioGraph.StemKey) throws -> [[Float]]) {
        self.source = source; self.loadStem = loadStem
    }

    /// Stems decoded by the media engine at the source's sample rate.
    public convenience init(source: GraphAudioSource) {
        let rate = source.format.sampleRate
        self.init(source: source) { key in try DocumentAudioGraph.decodeStem(key, sampleRate: rate) }
    }

    /// Builds that reached `GraphAudioSource.replace` (skipped intermediates are not counted).
    public var builds: Int { lock.lock(); defer { lock.unlock() }; return builds_ }

    public func submit(_ inputs: DocumentAudioGraph.Inputs) {
        lock.lock()
        let busy = scheduled
        pending = inputs
        scheduled = true
        lock.unlock()
        if busy { source.supersedeReplace() } else { queue.async { self.drain() } }
    }

    /// Blocks until every submitted edit has been built (tests, closing a project).
    public func waitUntilIdle() {
        while true {
            queue.sync {}
            lock.lock(); let idle = !scheduled && pending == nil; lock.unlock()
            if idle { return }
        }
    }

    func drain() {
        while true {
            lock.lock()
            guard let inputs = pending else { scheduled = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            withAutoreleasePool { build(inputs) }   // stem decodes; this loop runs as long as edits keep coming
        }
    }

    func build(_ inputs: DocumentAudioGraph.Inputs) {
        var issues: [String] = []
        var project = DocumentAudioGraph.project(inputs, loadStem: { key in
            if let s = stemCache[key] { return try s.get() }
            let s = Result { try loadStem(key) }
            stemCache[key] = s
            return try s.get()
        }, issues: &issues)
        // Stems are decoded at the source's rate, so the graph runs at it too (in-place edits compare the rate).
        project.sampleRate = Double(source.format.sampleRate)
        let live = Set(inputs.tracks.map(\.stem))
        stemCache = stemCache.filter { live.contains($0.key) }
        if issues != lastIssues { lastIssues = issues; onIssues?(issues) }
        lock.lock(); let superseded = pending != nil; lock.unlock()
        if superseded { return }   // a newer edit is waiting: build that one instead
        source.replace(project)
        lock.lock(); builds_ += 1; lock.unlock()
    }
}
