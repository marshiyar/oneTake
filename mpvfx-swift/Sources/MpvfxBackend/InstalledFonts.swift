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
// Installed font families for the text tools, read from the system.
import Foundation
#if canImport(CoreText)
import CoreText
#endif

enum InstalledFonts {
    static func families() -> [String] {
        #if canImport(CoreText)
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        return Array(Set(names.filter { !$0.hasPrefix(".") })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #else
        // fontconfig: one line per face, families comma-separated (localized names first).
        guard let fcList = ["/usr/bin/fc-list", "/usr/local/bin/fc-list", "/bin/fc-list"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: fcList)
        p.arguments = [":", "family"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var set = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if let first = line.split(separator: ",").first?.trimmingCharacters(in: .whitespaces), !first.isEmpty { set.insert(first) }
        }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #endif
    }
}
