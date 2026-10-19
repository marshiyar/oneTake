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
// Bootstraps the standalone "MpVFX" project: a directory holding an empty native project document.
import Foundation
import MpvfxShared

public let STANDALONE_PROJECT_ID = "MpVFX"

/// The standalone project's starter document (`ProjectDocuments.starterDocument`, sequence "Main").
public func createStandaloneProjectDocument() throws -> String {
    try ProjectDocuments.starterDocument(id: STANDALONE_PROJECT_ID, name: "Main")
}

public struct EnsureStandaloneProjectResult: Equatable, Sendable {
    public var created: Bool
    public var id: String
    public init(created: Bool, id: String) { self.created = created; self.id = id }
}

/// Creates <projectsDir>/MpVFX/.studio/project.json through the transaction store unless it exists. An existing
/// document is never rewritten. No existence check comes first: `createStarter` rolls back a creation a crash
/// interrupted before it decides, so the document that stays is one the next open will not roll back.
public func ensureStandaloneProject(_ projectsDir: String, durableWrite: DurableWrite) throws -> EnsureStandaloneProjectResult {
    let projectDir = PosixPath.join(projectsDir, STANDALONE_PROJECT_ID)
    try ProjectFS.mkdirRecursive(projectDir)
    let written = try ProjectDocuments.createStarter(projectRoot: projectDir, id: STANDALONE_PROJECT_ID, name: "Main", durableWrite: durableWrite)
    return EnsureStandaloneProjectResult(created: written != nil, id: STANDALONE_PROJECT_ID)
}
