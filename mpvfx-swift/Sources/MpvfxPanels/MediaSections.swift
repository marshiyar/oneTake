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

/// One tile of the Media panel: a project file, a library file not in this project yet, or a library export.
/// The three live in different id spaces, so the reference carries which one it is.
public enum MediaTileRef: Hashable {
    case media(String), library(String), export(String), textLook(String)
    public var id: String {
        switch self { case .media(let id), .library(let id), .export(let id), .textLook(let id): id }
    }
}

/// What the search row's filter menu narrows the grid to: one kind (or all), timeline use, and the order.
public struct MediaFilter: Equatable {
    public enum Kind: String, CaseIterable { case all, video, images, audio, fonts, library, exports }
    public enum Usage: String, CaseIterable { case all, inTimeline, notInTimeline }
    public enum Sort: String, CaseIterable { case timelineFirst, name, duration }
    public var kind = Kind.all
    public var usage = Usage.all
    public var sort = Sort.timelineFirst
    public init(kind: Kind = .all, usage: Usage = .all, sort: Sort = .timelineFirst) { self.kind = kind; self.usage = usage; self.sort = sort }
    public var isDefault: Bool { self == MediaFilter() }

    public static let kindLabels: [Kind: String] = [.all: "All media", .video: "Video", .images: "Images", .audio: "Audio", .fonts: "Fonts",
                                                    .library: "Library media", .exports: "Exports"]
    public static let usageLabels: [Usage: String] = [.all: "In and out of the timeline", .inTimeline: "In the timeline",
                                                      .notInTimeline: "Not in the timeline"]
    public static let sortLabels: [Sort: String] = [.timelineFirst: "Timeline first", .name: "Name", .duration: "Duration"]

    /// The non-default choices, in menu order, for the line under the search row ("Video · Not in the timeline").
    public var summary: [String] {
        var out: [String] = []
        if kind != .all { out.append(Self.kindLabels[kind] ?? kind.rawValue) }
        if usage != .all { out.append(Self.usageLabels[usage] ?? usage.rawValue) }
        if sort != .timelineFirst { out.append("By " + (Self.sortLabels[sort] ?? sort.rawValue).lowercased()) }
        return out
    }

    /// Whether a project file of `category` that is (or is not) on the timeline passes.
    func admits(_ item: MediaBinItem) -> Bool {
        switch usage { case .inTimeline: guard item.used else { return false }; case .notInTimeline: guard !item.used else { return false }; case .all: break }
        return kind == .all || kind.rawValue == item.category.rawValue
    }

    /// Library files are never on this project's timeline; exports are not media of it at all.
    var admitsLibrary: Bool { (kind == .all || kind == .library) && usage != .inTimeline }
    var admitsExports: Bool { (kind == .all || kind == .exports) && usage == .all }
}

/// A titled run of tiles: one kind of project file, the library's files, or the exports.
public struct MediaSection: Equatable {
    public enum Layout: Equatable { case grid, rows }
    public var id: String
    public var title: String
    public var layout: Layout
    public var tiles: [MediaTileRef]
}

extension LeftSidebarPanel {
    /// Where `attach` puts a library file in a project (`LibraryService.attachUnlocked`: `assets/<assetId>/<name>`),
    /// so a library file already in this project is recognised by its bin path, not guessed from its name.
    static func attachedPrefix(_ assetId: String) -> String { "assets/\(assetId)/" }

    func matchesSearch(_ name: String) -> Bool {
        searchQuery.isEmpty || name.lowercased().contains(searchQuery.lowercased())
    }

    /// Project files that pass the search and the filter, in the filter's order.
    func sorted(_ list: [MediaBinItem]) -> [MediaBinItem] {
        let indexed = Array(list.enumerated())
        switch filter.sort {
        case .timelineFirst: return indexed.sorted { ($0.element.used ? 0 : 1, $0.offset) < ($1.element.used ? 0 : 1, $1.offset) }.map(\.element)
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .duration:   // shortest first; files with no known duration last, ties in bin order
            return indexed.sorted { ($0.element.duration ?? .infinity, $0.offset) < ($1.element.duration ?? .infinity, $1.offset) }.map(\.element)
        }
    }

    /// The library's files in the shown event that are not in this project yet (the ones in it are bin tiles).
    var libraryOnlyAssets: [LibraryNavModel.Asset] {
        guard let lib = activeLibrary, let ev = activeEvent else { return [] }
        let paths = items.compactMap(\.path)
        return lib.assets.filter { a in
            a.eventId == ev.id && !paths.contains { $0.hasPrefix(Self.attachedPrefix(a.id)) } && matchesSearch(a.name)
        }
    }

    var visibleExports: [LibraryNavModel.Export] { (activeLibrary?.exports ?? []).filter { matchesSearch($0.label) } }

    /// The grid, top to bottom: Video, Images, Audio, Fonts, then Library media and Exports, each only when it has tiles.
    public var sections: [MediaSection] {
        var out = categorized.map { cat, list in
            MediaSection(id: cat.rawValue, title: MediaBinItem.labels[cat] ?? cat.rawValue, layout: cat == .audio || cat == .fonts ? .rows : .grid,
                         tiles: list.map { .media($0.id) })
        }
        let lib = filter.admitsLibrary ? libraryOnlyAssets : []
        if !lib.isEmpty { out.append(MediaSection(id: "library", title: "Library media", layout: .grid, tiles: lib.map { .library($0.id) })) }
        let exp = filter.admitsExports ? visibleExports : []
        if !exp.isEmpty { out.append(MediaSection(id: "exports", title: "Exports", layout: .grid, tiles: exp.map { .export($0.id) })) }
        if onAddTextLook != nil, filter.kind == .all, filter.usage == .all {
            for group in TextLookPreset.Group.allCases {
                let looks = TextLookPreset.all.filter { $0.group == group && matchesSearch($0.name + " " + group.rawValue) }
                if !looks.isEmpty {
                    out.append(MediaSection(id: "text-looks:" + group.rawValue, title: "Text · " + group.rawValue, layout: .grid,
                                            tiles: looks.map { .textLook($0.id) }))
                }
            }
        }
        return out
    }

    /// Kinds with something to show, for the filter menu (the current one stays listed so it can be seen and undone).
    var availableKinds: [MediaFilter.Kind] {
        let cats = Set(items.map(\.category.rawValue))
        return MediaFilter.Kind.allCases.filter { k in
            switch k {
            case .all: return true
            case .library: return !(activeLibrary?.assets.isEmpty ?? true) || filter.kind == k
            case .exports: return !(activeLibrary?.exports.isEmpty ?? true) || filter.kind == k
            default: return cats.contains(k.rawValue) || filter.kind == k
            }
        }
    }

    func mediaItem(_ id: String) -> MediaBinItem? { items.first { $0.id == id } }
    func libraryAsset(_ id: String) -> LibraryNavModel.Asset? { activeLibrary?.assets.first { $0.id == id } }
    func export(_ id: String) -> LibraryNavModel.Export? { activeLibrary?.exports.first { $0.id == id } }

    /// What the tooltip and the status line show for a tile when two lines cut its name short.
    func fullName(_ ref: MediaTileRef) -> String {
        switch ref {
        case .media(let id): return mediaItem(id)?.name ?? id
        case .library(let id): return libraryAsset(id)?.name ?? id
        case .export(let id): return export(id)?.label ?? id
        case .textLook(let id): return TextLookPreset.preset(id)?.name ?? id
        }
    }
}

/// Where the media bin's filter and sort choice lives between launches: one `mediaBinFilter` object inside a JSON
/// preferences file. Other keys in the file are kept; a missing, unreadable or hostile file reads as the default
/// choice, and an unknown value in it falls back to that field's default.
public final class MediaFilterStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> MediaFilter {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["mediaBinFilter"] as? [String: Any] else { return MediaFilter() }
        return MediaFilter(kind: (raw["kind"] as? String).flatMap(MediaFilter.Kind.init) ?? .all,
                           usage: (raw["usage"] as? String).flatMap(MediaFilter.Usage.init) ?? .all,
                           sort: (raw["sort"] as? String).flatMap(MediaFilter.Sort.init) ?? .timelineFirst)
    }

    public func save(_ filter: MediaFilter) {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { object = o }
        object["mediaBinFilter"] = ["kind": filter.kind.rawValue, "usage": filter.usage.rawValue, "sort": filter.sort.rawValue]
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? out.write(to: url, options: .atomic)
    }
}
