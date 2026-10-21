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
// Library commands (create, open, import, attach, relink, rename, save output) with dialogs behind NativeDialogs.
import Foundation

public struct FileFilter: Equatable, Sendable { public var name: String; public var extensions: [String] }

public struct SaveDialogOptions: Equatable, Sendable {
    public var title: String, defaultPath: String, buttonLabel: String?, filters: [FileFilter]
}
public struct OpenDialogOptions: Equatable, Sendable {
    public var title: String
    public var directory: Bool, multiple: Bool
    public init(title: String, directory: Bool, multiple: Bool) { self.title = title; self.directory = directory; self.multiple = multiple }
}

public protocol NativeDialogs: Sendable {
    /// nil when cancelled.
    func showSave(_ options: SaveDialogOptions) async -> String?
    /// empty when cancelled.
    func showOpen(_ options: OpenDialogOptions) async -> [String]
    func showError(title: String, message: String) async
    func openPath(_ path: String) async
}

public enum LibraryCommands {
    public static func dispatch(service: LibraryService, backend: DesktopBackend, dialogs: NativeDialogs?,
                                command: JSONValue) async throws -> JSONValue {
        guard let type = command["type"]?.string else { throw DesktopError("Invalid library command") }
        @Sendable func str(_ k: String) -> String { command[k]?.string ?? "" }
        var projectId: String?
        var path: String?
        var errors: [String] = []
        switch type {
        case "list": break
        case "create":
            if let selected = await dialogs?.showSave(.init(title: "Create Library", defaultPath: "Untitled.mpvfxlibrary",
                    buttonLabel: "Create Library", filters: [.init(name: "MpVFX Library", extensions: ["mpvfxlibrary"])])), !selected.isEmpty {
                let root = selected.hasSuffix(".mpvfxlibrary") ? selected : selected + ".mpvfxlibrary"
                let libraryId = try await service.create(root: root)
                let views = try await service.views()
                let eventId = views.array?.first { $0["id"]?.string == libraryId }?["events"]?.array?.first?["id"]?.string ?? ""
                projectId = try await service.createProject(libraryId: libraryId, eventId: eventId, name: "Untitled Project")
            }
        case "open":
            if let first = await dialogs?.showOpen(.init(title: "Open Library", directory: true, multiple: false)).first {
                let libraryId = try await service.open(root: first)
                projectId = try await service.views().array?.first { $0["id"]?.string == libraryId }?["projects"]?.array?
                    .first { $0["state"]?.string == "ready" }?["id"]?.string
            }
        case "event": try await service.createEvent(libraryId: str("libraryId"), name: str("name"))
        case "project": projectId = try await service.createProject(libraryId: str("libraryId"), eventId: str("eventId"), name: str("name"))
        case "import":
            let mode = str("mode")
            guard ["managed", "linked"].contains(mode) else { throw DesktopError("Invalid import mode") }
            let files = await dialogs?.showOpen(.init(title: mode == "linked" ? "Link Media" : "Import Media into Library",
                                                     directory: false, multiple: true)) ?? []
            if !files.isEmpty {
                let pid = command["projectId"]?.string
                let op: @Sendable () async throws -> [(String, String)] = {
                    try await service.importMedia(libraryId: str("libraryId"), eventId: str("eventId"), paths: files, mode: mode, projectId: pid)
                }
                let invalid = try await (pid != nil && pid != "" ? backend.withProject(pid!, { try await op().map { [$0.0, $0.1] } }).map { ($0[0], $0[1]) } : op())
                errors += invalid.map { "\($0.0): \($0.1)" }
            }
        case "attach":
            path = try await backend.withProject(str("projectId")) {
                try await service.attach(libraryId: str("libraryId"), projectId: str("projectId"), assetId: str("assetId"))
            }
        case "relink":
            if let first = await dialogs?.showOpen(.init(title: "Locate Original Media", directory: false, multiple: false)).first {
                try await service.relink(libraryId: str("libraryId"), assetId: str("assetId"), path: first)
            }
        case "reveal":
            await dialogs?.openPath(try service.root(libraryId: str("libraryId")))
        case "renameEvent", "renameProject": try await rename(service: service, command: command)
        case "saveOutput":
            try await saveOutput(service: service, dialogs: dialogs, libraryId: str("libraryId"), jobId: str("jobId"))
        default: throw DesktopError("Unknown library command")
        }
        // Key order { libraries, projectId, path, errors }.
        var result: JSONObject = ["libraries": try await service.views()]
        if let projectId { result["projectId"] = .string(projectId) }
        if let path { result["path"] = .string(path) }
        result["errors"] = .array(errors.map { .string($0) })
        return .object(result)
    }
}
