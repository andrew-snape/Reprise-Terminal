// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The kind of release an album is, for grouping an artist's page as record
/// shops do. Read from Plex's `Format` (Album, EP, Single) and `Subformat`
/// (Live, Compilation, Soundtrack, Remix, Demo) tags.
nonisolated enum MusicReleaseGroup: Int, CaseIterable, Identifiable, Sendable {
    case albums, singlesAndEPs, live, compilations, soundtracks, remixes, demos

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .albums: "Albums"
        case .singlesAndEPs: "Singles & EPs"
        case .live: "Live"
        case .compilations: "Compilations"
        case .soundtracks: "Soundtracks"
        case .remixes: "Remixes"
        case .demos: "Demos"
        }
    }

    /// What an album is a kind of wins over how long it is: a live EP is Live.
    /// An album with no tags is an album.
    static func classify(formats: [String], subformats: [String]) -> MusicReleaseGroup {
        let sub = Set(subformats.map { $0.lowercased() })
        if sub.contains("live") { return .live }
        if sub.contains("compilation") { return .compilations }
        if sub.contains("soundtrack") { return .soundtracks }
        if sub.contains("remix") { return .remixes }
        if sub.contains("demo") { return .demos }
        let format = Set(formats.map { $0.lowercased() })
        if format.contains("ep") || format.contains("single") { return .singlesAndEPs }
        return .albums
    }
}

nonisolated extension PlexMetadata {
    /// Plex tagged this album with a format or subformat.
    var hasReleaseTags: Bool { !(Format ?? []).isEmpty || !(Subformat ?? []).isEmpty }

    var releaseGroup: MusicReleaseGroup {
        MusicReleaseGroup.classify(formats: (Format ?? []).compactMap(\.tag),
                                   subformats: (Subformat ?? []).compactMap(\.tag))
    }
}
