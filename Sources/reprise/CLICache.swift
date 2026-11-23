// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLICache.swift
//  reprise (terminal)
//
//  Whole audio files kept between runs in ~/Library/Caches/reprise-cli/audio,
//  up to 4 GB, the least recently played removed first. A file is named for
//  its server, Plex part id and size, so a track replaced on the server is a
//  new file and a stale copy is never played. Files are written as `.part`
//  and renamed only once complete, so AVPlayer never opens half a file.
//

import Foundation

final class CLICache {
    static let limit: Int64 = 4 * 1024 * 1024 * 1024

    private struct File {
        let url: URL
        let size: Int64
        var used: Date
    }

    /// Complete files, by name.
    private var files: [String: File] = [:]
    /// Downloads under way, by name; the id tells a fetch from a later one of the same name.
    private var fetching: [String: (id: UUID, task: Task<URL?, Never>)] = [:]
    /// Never evicted: the playing track and the ones read ahead.
    var protected: Set<String> = []

    nonisolated static var folder: URL {
        URL.cachesDirectory.appending(path: "reprise-cli/audio", directoryHint: .isDirectory)
    }

    init() {
        let fm = FileManager.default
        let parent = Self.folder.deletingLastPathComponent()
        for dir in [parent, Self.folder] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        for url in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: Array(keys))) ?? [] {
            // Left by a run that quit mid-download.
            if url.pathExtension == "part" {
                try? fm.removeItem(at: url)
                continue
            }
            let values = try? url.resourceValues(forKeys: keys)
            files[url.lastPathComponent] = File(url: url, size: Int64(values?.fileSize ?? 0),
                                                used: values?.contentModificationDate ?? .distantPast)
        }
        evict()
    }

    /// The cache name of a track's file on a server, nil when it has no part.
    static func name(for track: PlexMetadata, serverID: String) -> String? {
        guard let media = track.Media?.first, let part = media.Part?.first else { return nil }
        let safe = { (s: String) in String(s.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }) }
        let ext = safe(media.container ?? part.container ?? "")
        return "\(safe(String(serverID.prefix(16))))-\(part.id)-\(part.size ?? 0).\(ext.isEmpty ? "audio" : ext)"
    }

    func contains(_ name: String) -> Bool { files[name] != nil }

    /// The file to play, marked as just used.
    func file(for name: String) -> URL? {
        guard var file = files[name] else { return nil }
        file.used = Date()
        files[name] = file
        try? FileManager.default.setAttributes([.modificationDate: file.used], ofItemAtPath: file.url.path)
        return file.url
    }

    /// A file that wouldn't play: gone, so it is fetched afresh next time.
    func remove(_ name: String) {
        guard let file = files.removeValue(forKey: name) else { return }
        try? FileManager.default.removeItem(at: file.url)
    }

    /// Downloads `url` as `name`, once; the task gives the file, or nil.
    func fetch(_ name: String, from url: URL, size: Int?) -> Task<URL?, Never> {
        if let file = files[name] { return Task { file.url } }
        if let running = fetching[name] { return running.task }
        let id = UUID()
        let destination = Self.folder.appending(path: name)
        let task = Task { [weak self] () -> URL? in
            let file = await Self.download(url, to: destination, size: size)
            guard let self else { return file }
            if self.fetching[name]?.id == id { self.fetching[name] = nil }
            guard let file, !Task.isCancelled else {
                if let file { try? FileManager.default.removeItem(at: file) }
                return nil
            }
            self.add(file, name: name)
            return file
        }
        fetching[name] = (id, task)
        return task
    }

    /// Stops every download not named.
    func cancel(except wanted: Set<String>) {
        for (name, running) in fetching where !wanted.contains(name) {
            running.task.cancel()
            fetching[name] = nil
        }
    }

    private func add(_ file: URL, name: String) {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        files[name] = File(url: file, size: Int64(size), used: Date())
        evict()
    }

    /// Least recently played first, until the cache is under its limit.
    private func evict() {
        var total = files.values.reduce(0) { $0 + $1.size }
        guard total > Self.limit else { return }
        for (name, file) in files.sorted(by: { $0.value.used < $1.value.used }) where !protected.contains(name) {
            try? FileManager.default.removeItem(at: file.url)
            files[name] = nil
            total -= file.size
            if total <= Self.limit { break }
        }
    }

    /// Downloads beside the destination as `.part`, then renames it: the move from
    /// URLSession's temp folder may copy, and a half-copied file must never be
    /// found under its real name. Nil on failure or a size other than Plex's.
    nonisolated private static func download(_ url: URL, to destination: URL, size: Int?) async -> URL? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (temp, response) = try? await PlexCertificateDelegate.session.download(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let fm = FileManager.default
        let part = destination.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        guard (try? fm.moveItem(at: temp, to: part)) != nil else {
            try? fm.removeItem(at: temp)
            return nil
        }
        let got = (try? part.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, size > 0, got != size {
            try? fm.removeItem(at: part)
            return nil
        }
        try? fm.removeItem(at: destination)
        guard (try? fm.moveItem(at: part, to: destination)) != nil else {
            try? fm.removeItem(at: part)
            return nil
        }
        return destination
    }
}
