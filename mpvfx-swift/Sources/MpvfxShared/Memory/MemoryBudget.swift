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
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

#if os(Windows)
private final class MemoryNotificationHandle: @unchecked Sendable {
    let value: HANDLE
    init(_ value: HANDLE) { self.value = value }
    deinit { CloseHandle(value) }
}
#endif

/// Byte budgets for the app's in-memory caches, sized from the machine's physical memory.
///
/// Every cache that holds pictures or samples has one of these and evicts least recently used entries to stay
/// under it, purges on a memory-pressure warning (`MemoryPressureMonitor`) and drops what belongs to a removed clip
/// or a closed project. The numbers (16 GB Mac / 8 GB box):
///
/// - Raw decoded preview frames (`PreviewFrameCache`): 10% of RAM, at most 2 GB, at least 256 MB
///   (1.6 GB / 819 MB: about 200 / 100 frames of 1080p RGBA, many seconds of decode-ahead and scrub history).
///   Frames a decode lane is producing count against it before they are stored (`PreviewFrameCache.reserve`).
/// - Graded preview pictures memoised per clip: 2% of RAM, 64…256 MB.
/// - Media bin thumbnails, timeline filmstrips and waveform peaks (`MediaThumbnails`): 2% of RAM, 64…256 MB.
///
/// `MPVFX_PREVIEW_CACHE_MB` overrides the preview frame budget (tests, low-memory runs).
public enum MemoryBudget {
    public static var physicalMemory: Int { Int(clamping: ProcessInfo.processInfo.physicalMemory) }

    /// `fraction` of `physical`, clamped to floor…cap.
    public static func bytes(fraction: Double, cap: Int, floor: Int, physical: Int = physicalMemory) -> Int {
        max(floor, min(cap, Int(Double(max(0, physical)) * fraction)))
    }

    /// Raw decoded preview frames: min(2 GB, 10% of RAM), at least 256 MB.
    public static func previewFrames(physical: Int = physicalMemory,
                                     env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        if let mb = env["MPVFX_PREVIEW_CACHE_MB"].flatMap(Int.init), mb > 0 { return mb << 20 }
        return bytes(fraction: 0.10, cap: 2 << 30, floor: 256 << 20, physical: physical)
    }

    /// Everything the preview pane's caches may hold together: raw frames (cached and in flight) plus graded
    /// pictures. The preview benchmark compares its peak resident memory with this (`budget_sum_mib`).
    public static func previewTotal(physical: Int = physicalMemory,
                                    env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        previewFrames(physical: physical, env: env) + gradedFrames(physical: physical)
    }

    /// Graded pictures the preview memoises per clip: 2% of RAM, 64…256 MB.
    public static func gradedFrames(physical: Int = physicalMemory) -> Int {
        bytes(fraction: 0.02, cap: 256 << 20, floor: 64 << 20, physical: physical)
    }

    /// Thumbnails, filmstrips and waveform peaks: 2% of RAM, 64…256 MB.
    public static func mediaThumbnails(physical: Int = physicalMemory) -> Int {
        bytes(fraction: 0.02, cap: 256 << 20, floor: 64 << 20, physical: physical)
    }
}

/// The process's memory as the OS accounts it: `phys_footprint` on macOS (what Activity Monitor's Memory column
/// and jetsam use), `VmRSS` from /proc/self/status on Linux, the working set (GetProcessMemoryInfo) on Windows.
public enum ResidentMemory {
    public static func footprintBytes() -> Int? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint)
        #elseif os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return nil }
        return parseVmRSS(text)
        #elseif os(Windows)
        var counters = PROCESS_MEMORY_COUNTERS()
        counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        guard K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) else { return nil }
        return Int(counters.WorkingSetSize)
        #else
        return nil
        #endif
    }

    /// Bytes from the `VmRSS:` line of a /proc/<pid>/status text.
    public static func parseVmRSS(_ status: String) -> Int? {
        for line in status.split(separator: "\n") where line.hasPrefix("VmRSS:") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let kb = Int(parts[1]) else { return nil }
            return kb * 1024
        }
        return nil
    }
}

/// Memory-pressure notifications for the caches. On macOS a `DispatchSource.makeMemoryPressureSource` watches the
/// system (warning and critical) and calls every observer on the main queue; elsewhere there is no system source
/// and `simulate` is how tests and the smoke hook exercise the same path. Observers stop when their token is
/// released.
public final class MemoryPressureMonitor: @unchecked Sendable {
    public enum Level: Sendable, Equatable { case warning, critical }

    public static let shared = MemoryPressureMonitor()

    let lock = NSLock()
    var observers: [Int: (Level) -> Void] = [:]
    var nextId = 0
    #if canImport(Darwin)
    var source: DispatchSourceMemoryPressure?
    #elseif os(Windows)
    var lowMemoryWatcher: Thread?
    /// Runs a warning on the UI thread. A Win32 message loop does not drain the main dispatch queue, so the shell
    /// sets this to post onto its loop before observers are added.
    public var deliverOnUIThread: (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    #endif

    public init() {}

    /// Removes its observer when released.
    public final class Token: @unchecked Sendable {
        let id: Int
        weak var monitor: MemoryPressureMonitor?
        init(id: Int, monitor: MemoryPressureMonitor) { self.id = id; self.monitor = monitor }
        deinit { monitor?.remove(id) }
    }

    /// `handler` runs on the main queue (macOS; on Windows the shell's UI thread) for every system warning; keep the token as long as it should.
    public func observe(_ handler: @escaping (Level) -> Void) -> Token {
        lock.lock()
        nextId += 1
        let id = nextId
        observers[id] = handler
        lock.unlock()
        startSystemSource()
        return Token(id: id, monitor: self)
    }

    func remove(_ id: Int) { lock.lock(); observers[id] = nil; lock.unlock() }

    public var observerCount: Int { lock.lock(); defer { lock.unlock() }; return observers.count }

    /// Calls every observer now, on the calling thread (tests, the memory smoke hook).
    public func simulate(_ level: Level) { notify(level) }

    func notify(_ level: Level) {
        lock.lock(); let handlers = Array(observers.values); lock.unlock()
        for h in handlers { h(level) }
    }

    func startSystemSource() {
        #if canImport(Darwin)
        lock.lock()
        guard source == nil else { lock.unlock(); return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source = s
        lock.unlock()
        // The handler reads the source through `self` rather than capturing it (the source existential is not Sendable).
        s.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let event = self.source?.data; self.lock.unlock()
            guard let event else { return }
            if event.contains(.critical) { self.notify(.critical) } else if event.contains(.warning) { self.notify(.warning) }
        }
        s.resume()
        #elseif os(Windows)
        // LowMemoryResourceNotification is signalled while available physical memory is low: one warning per low
        // spell, delivered on the main queue, then wait for the spell to end before arming again.
        lock.lock()
        guard lowMemoryWatcher == nil, let rawHandle = CreateMemoryResourceNotification(LowMemoryResourceNotification) else {
            lock.unlock(); return
        }
        let handle = MemoryNotificationHandle(rawHandle)
        let watcher = Thread { [weak self] in
            while WaitForSingleObject(handle.value, DWORD.max) == 0 {   // INFINITE, WAIT_OBJECT_0
                guard self != nil else { break }
                self?.deliverOnUIThread { [weak self] in self?.notify(.warning) }
                var low: WindowsBool = true
                while QueryMemoryResourceNotification(handle.value, &low), low.boolValue { Thread.sleep(forTimeInterval: 1) }
            }
        }
        lowMemoryWatcher = watcher
        lock.unlock()
        watcher.start()
        #endif
    }
}

/// Runs `body` in an autorelease pool on Apple platforms (a no-op wrapper elsewhere). Long loops on background
/// threads (decoders, export, audio feeders) never return to a run loop that would drain one, so every Foundation
/// or Metal object autoreleased inside them would otherwise live until the loop ends.
@inline(__always)
public func withAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}
