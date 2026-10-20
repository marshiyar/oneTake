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
// Render history for the Renders tab: finished exports live in the
// project's renders folder as `<jobId>.<mp4|webm|mov>` with an optional `<jobId>.meta.json` sidecar
// ({"status":"complete"|"failed","durationMs":n}); the list is newest first and deleting a render removes
// the file and its sidecar.
import Foundation
import MpvfxShared

public struct ProjectRender: Equatable, Sendable {
    public enum Status: String, Sendable { case complete, failed }
    public var id: String
    public var filename: String
    /// Absolute path of the rendered file.
    public var path: String
    public var size: Int64
    /// File modification time, seconds since 1970.
    public var createdAt: Double
    public var status: Status
    public var durationMs: Double?
}

public enum ProjectRenders {
    static let extensions = ["mp4", "webm", "mov"]

    /// Where a new render with this job id and format goes (the folder is created).
    public static func outputPath(_ rendersDir: String, jobId: String, format: String) throws -> String {
        guard isTransactionId(jobId), extensions.contains(format) else { throw MediaToolError("Invalid render job") }
        try ProjectFS.mkdirRecursive(rendersDir)
        return PosixPath.join(rendersDir, "\(jobId).\(format)")
    }

    /// Writes the sidecar the history reads (how long the render took and whether it failed).
    public static func recordOutcome(_ rendersDir: String, jobId: String, failed: Bool, durationMs: Double?) throws {
        guard isTransactionId(jobId) else { throw MediaToolError("Invalid render job") }
        try ProjectFS.mkdirRecursive(rendersDir)
        var meta: NativeJSONObject = ["status": .string(failed ? "failed" : "complete")]
        if let durationMs { meta["durationMs"] = .number(durationMs.rounded()) }
        try Data(jsJSONStringify(.object(meta)).utf8).write(to: URL(fileURLWithPath: PosixPath.join(rendersDir, "\(jobId).meta.json")), options: .atomic)
    }

    public static func list(_ rendersDir: String) -> [ProjectRender] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rendersDir)) ?? []
        return names.compactMap { name -> ProjectRender? in
            let ext = PosixPath.extname(name).dropFirst().lowercased()
            guard extensions.contains(String(ext)) else { return nil }
            let path = PosixPath.join(rendersDir, name)
            guard let info = try? ProjectFS.statInfo(path), info.isFile else { return nil }
            let id = String(name.dropLast(ext.count + 1))
            var status = ProjectRender.Status.complete
            var durationMs: Double?
            if let text = try? ProjectFS.readUTF8(PosixPath.join(rendersDir, "\(id).meta.json")),
               let meta = (try? NativeJSONValue.parse(text))?.objectValue {
                if case .number(let d)? = meta["durationMs"], d != 0 { durationMs = d }
                if meta["status"]?.stringValue == "failed" && !FileManager.default.fileExists(atPath: path) { status = .failed }
            }
            return ProjectRender(id: id, filename: name, path: path, size: info.size, createdAt: Double(info.mtimeNs) / 1e9,
                                 status: status, durationMs: durationMs)
        }.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
    }

    /// Whether `id` is an app render's job id: renders are written as `render-<uuid>.<format>` (RenderRequest.jobId,
    /// the Renders tab), so a folder shared with other videos lists only these. A user's own `render-final.mp4` is not
    /// one: the part after `render-` must be a UUID.
    public static func isRenderId(_ id: String) -> Bool {
        id.hasPrefix("render-") && UUID(uuidString: String(id.dropFirst("render-".count))) != nil
    }

    /// Removes the render's file(s) and sidecar. Returns whether anything was removed.
    @discardableResult
    public static func delete(_ rendersDir: String, id: String) throws -> Bool {
        guard isTransactionId(id) else { throw MediaToolError("Invalid render job") }
        var removed = false
        for ext in extensions + ["meta.json"] {
            let p = PosixPath.join(rendersDir, "\(id).\(ext)")
            if FileManager.default.fileExists(atPath: p) { try FileManager.default.removeItem(atPath: p); removed = true }
        }
        return removed
    }
}
