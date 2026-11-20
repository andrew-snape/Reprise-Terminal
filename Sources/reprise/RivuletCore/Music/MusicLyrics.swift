// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A song's words, from a Plex lyric stream (`streamType` 4): LRC with a time
/// for each line, or plain text.
nonisolated struct MusicLyrics: Sendable, Equatable {
    nonisolated struct Line: Sendable, Equatable, Identifiable {
        let id: Int
        /// When the line is sung, in seconds; nil in plain lyrics.
        let time: TimeInterval?
        let text: String
    }

    let lines: [Line]

    /// Every line has a time, so the playing one can be followed.
    var isSynced: Bool { !lines.isEmpty && lines.allSatisfy { $0.time != nil } }

    /// The line being sung at `time`: the last one that has started.
    func lineIndex(at time: TimeInterval) -> Int? {
        guard isSynced else { return nil }
        var found: Int?
        for (index, line) in lines.enumerated() {
            guard let start = line.time, start <= time else { break }
            found = index
        }
        return found
    }

    /// Reads LRC (`[mm:ss.xx] words`, several stamps on a line allowed, `[offset:±ms]`
    /// honoured, other tags dropped) or, with no stamps at all, plain lines.
    init?(text: String) {
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var offset: TimeInterval = 0
        var timed: [(TimeInterval, String)] = []
        var plain: [String] = []
        for row in rows {
            var rest = Substring(row.trimmingCharacters(in: .whitespaces))
            var stamps: [TimeInterval] = []
            var isTag = false
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let inside = rest[rest.index(after: rest.startIndex)..<close]
                if let seconds = Self.seconds(inside) {
                    stamps.append(seconds)
                } else if inside.lowercased().hasPrefix("offset:") {
                    offset = (Double(inside.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                    isTag = true
                } else if inside.contains(":") {
                    isTag = true
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            if !stamps.isEmpty {
                for stamp in stamps { timed.append((stamp, words)) }
            } else if !isTag {
                plain.append(words)
            }
        }
        if !timed.isEmpty {
            let sorted = timed.sorted { $0.0 < $1.0 }
            lines = sorted.enumerated().map { Line(id: $0.offset, time: max(0, $0.element.0 - offset), text: $0.element.1) }
        } else {
            // Trim blank lines at either end; keep the gaps between verses.
            var words = plain
            while words.first?.isEmpty == true { words.removeFirst() }
            while words.last?.isEmpty == true { words.removeLast() }
            lines = words.enumerated().map { Line(id: $0.offset, time: nil, text: $0.element) }
        }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
    }

    /// "mm:ss", "mm:ss.xx" or "mm:ss:xx" as seconds.
    private static func seconds(_ stamp: Substring) -> TimeInterval? {
        let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let minutes = Double(parts[0]),
              parts[0].allSatisfy(\.isNumber) else { return nil }
        guard let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        var total = minutes * 60 + seconds
        if parts.count == 3, let hundredths = Double(parts[2]) { total += hundredths / 100 }
        return total
    }
}

extension PlexStream {
    var isLyrics: Bool { streamType == 4 }
}

extension PlexMetadata {
    /// The track's lyric stream, timed lyrics first.
    var lyricStream: PlexStream? {
        let streams = (Media ?? []).flatMap { ($0.Part ?? []).flatMap { $0.Stream ?? [] } }.filter(\.isLyrics)
        return streams.first { ($0.codec ?? $0.format)?.lowercased() == "lrc" } ?? streams.first
    }
}
