// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLIPlayer.swift
//  reprise (terminal)
//
//  An AVQueuePlayer over a list of tracks, gapless within the list, with Plex
//  told what plays. One X-Plex-Session-Identifier covers the whole run and
//  "stopped" is sent only when playback ends (CLAUDE.md, Music: a new id per
//  track or a "stopped" mid-queue makes Plex drop the file still being read).
//  Each transcoded item has its own transcoder session, stopped when the item
//  is left, as the Mac app's `finishMusic` does.
//

import AVFoundation
import Foundation

final class CLIPlayer {
    /// The server address everything plays from. Changed only by `switchConnection`.
    private(set) var connection: CLIConnection
    private let network = PlexNetworkManager.shared
    private let player = AVQueuePlayer()
    private let sessionID = UUID().uuidString

    /// An item in the queue, held until it is left so its identity is never reused.
    private struct Entry {
        let item: AVPlayerItem
        let index: Int
        /// The transcoder's session, when the item is a transcode.
        let transcode: String?
    }

    private(set) var tracks: [PlexMetadata] = []
    /// Index into `tracks` of the item AVPlayer is on.
    private(set) var index: Int?
    private var entries: [Entry] = []
    /// The item `tick()` last saw as current; a change means AVPlayer moved on.
    private var followed: Entry?
    /// The item Plex last heard about; a different one is reported at once.
    private var reportedItem: AVPlayerItem?
    private var lastReport = Date.distantPast
    /// A position to seek to once the current item is ready (after a reload).
    private var pendingSeek: Double?
    /// Start playing once `pendingSeek` is applied, so the track's opening isn't heard first.
    private var playAfterSeek = false
    /// The track a reconnect reloaded; failing again there is the file, not the network.
    private var retriedIndex: Int?
    /// Full metadata by rating key, for the quality text (lists lack stream details).
    private var details: [String: PlexMetadata] = [:]
    private var fetching: Set<String> = []
    /// The current item failed to reach the server; it is retried after a reconnect.
    private(set) var needsReconnect = false

    init(connection: CLIConnection) {
        self.connection = connection
        player.actionAtItemEnd = .advance
    }

    var current: PlexMetadata? { index.map { tracks[$0] } }
    var isPlaying: Bool { player.timeControlStatus != .paused }
    var isWaiting: Bool { needsReconnect || player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
    var time: Double { pendingSeek ?? player.currentTime().seconds }
    var duration: Double {
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { return d }
        return Double(current?.duration ?? 0) / 1000
    }

    // MARK: - Transport

    func play(_ list: [PlexMetadata], from start: Int) {
        tracks = list
        load(from: start)
        player.play()
    }

    func togglePause() {
        if isPlaying { player.pause() } else { player.play() }
        report(force: true)
    }

    func next() {
        guard let index, index + 1 < tracks.count else { return }
        load(from: index + 1)
        player.play()
    }

    func previous() {
        guard let index else { return }
        if time > 3 || index == 0 {
            player.seek(to: .zero)
            report(force: true)
        } else {
            load(from: index - 1)
            player.play()
        }
    }

    func seek(by seconds: Double) {
        let target = max(0, min(time + seconds, duration - 1))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        report(force: true)
    }

    /// Ends playback: Plex hears "stopped" and every transcoder is freed.
    func stop() async {
        player.pause()
        let track = current
        let time = time
        let left = entries
        player.removeAllItems()
        entries = []
        followed = nil
        tracks = []
        index = nil
        await withTaskGroup(of: Void.self) { group in
            if let track {
                group.addTask { await self.report(track, time: time, state: "stopped") }
            }
            for entry in left.prefix(2) {
                group.addTask { await self.stopTranscode(entry) }
            }
        }
    }

    /// The same queue, from the same place, on a new server address.
    func switchConnection(_ new: CLIConnection) {
        // A track held for a reconnect stopped AVPlayer, but the listener wanted it playing.
        let wasPlaying = needsReconnect || isPlaying
        if needsReconnect { retriedIndex = index }
        connection = new
        needsReconnect = false
        guard let index else { return }
        let at = time
        load(from: index)
        if at > 1 {
            pendingSeek = at
            playAfterSeek = wasPlaying
        } else if wasPlaying {
            player.play()
        }
    }

    /// Call often: follows AVPlayer onto the next item and keeps Plex told.
    /// Returns a message when a track could not be played.
    func tick() -> String? {
        var message: String?
        if !needsReconnect, let item = player.currentItem, item.status == .failed {
            let entry = entry(for: item)
            let title = entry.map { tracks[$0.index].title ?? "A track" } ?? "A track"
            if let error = item.error, CLISignIn.isNetworkError(error), retriedIndex != entry?.index {
                // The server went away, not the file: hold here and reconnect.
                needsReconnect = true
                return "Lost \(connection.serverName). Reconnecting…"
            }
            player.advanceToNextItem()
            if let entry {
                forget(entry)
                if player.currentItem == nil {
                    // It was the last track: the queue is done.
                    let track = tracks[entry.index]
                    Task { await report(track, time: 0, state: "stopped") }
                }
            }
            followed = nil
            index = player.currentItem.flatMap { self.entry(for: $0)?.index }
            message = "\(title) wouldn't play, skipped."
        }

        if let at = pendingSeek, let item = player.currentItem, item.status == .readyToPlay {
            pendingSeek = nil
            player.seek(to: CMTime(seconds: at, preferredTimescale: 600))
            if playAfterSeek { player.play() }
            playAfterSeek = false
        }

        let now = player.currentItem.flatMap { entry(for: $0) }
        if now?.item !== followed?.item {
            if let old = followed {
                // AVPlayer moved on by itself: the previous track played out.
                scrobble(tracks[old.index])
                forget(old)
                if now == nil {
                    let track = tracks[old.index]
                    Task { await report(track, time: 0, state: "stopped") }
                }
            }
            followed = now
            index = now?.index
            if index != retriedIndex { retriedIndex = nil }
        }
        if let current { fetchDetails(current) }
        report(force: player.currentItem != nil && player.currentItem !== reportedItem)
        return message
    }

    // MARK: - Loading

    private func load(from start: Int) {
        // The old queue is left. AVPlayer only reads the current item and the next,
        // so only those two can have a transcoder running.
        for entry in entries.prefix(2) { Task { await stopTranscode(entry) } }
        player.removeAllItems()
        entries = []
        pendingSeek = nil
        playAfterSeek = false
        for i in start..<tracks.count {
            guard let (url, transcode) = source(for: tracks[i]) else { continue }
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 30
            entries.append(Entry(item: item, index: i, transcode: transcode))
            player.insert(item, after: nil)
        }
        followed = player.currentItem.flatMap { entry(for: $0) }
        index = followed?.index
    }

    private func entry(for item: AVPlayerItem) -> Entry? {
        entries.first { $0.item === item }
    }

    /// An item that is done with: dropped, and its transcoder freed.
    private func forget(_ entry: Entry) {
        entries.removeAll { $0.item === entry.item }
        Task { await stopTranscode(entry) }
    }

    private func stopTranscode(_ entry: Entry) async {
        guard let session = entry.transcode else { return }
        await network.stopTranscodeSession(serverURL: connection.serverURL, authToken: connection.token,
                                           sessionId: session)
    }

    /// The file itself when AVFoundation opens it, else a 320k AAC transcode
    /// (with its transcoder session). Relay connections always transcode.
    private func source(for track: PlexMetadata) -> (URL, String?)? {
        let media = track.Media?.first
        if !connection.isRelay, Self.avFoundationPlays(media), let partKey = media?.Part?.first?.key,
           let base = URL(string: connection.serverURL),
           var components = URLComponents(url: base.appending(path: partKey), resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "X-Plex-Token", value: connection.token),
                URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
                URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
                URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),
                URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionID)
            ]
            return components.url.map { ($0, nil) }
        }
        guard let key = track.ratingKey else { return nil }
        let transcode = UUID().uuidString
        return network.buildMusicTranscodeURL(serverURL: connection.serverURL, authToken: connection.token,
                                              ratingKey: key, sessionID: transcode).map { ($0, transcode) }
    }

    /// Codecs and containers AVFoundation opens on its own (as MacPlexSession).
    static func avFoundationPlays(_ media: PlexMedia?) -> Bool {
        guard let media else { return false }
        let codecs: Set<String> = ["mp3", "aac", "alac", "flac", "pcm", "ac3", "eac3"]
        let containers: Set<String> = ["mp3", "mp4", "m4a", "flac", "wav", "aiff", "aif", "aac", "caf"]
        return codecs.contains((media.audioCodec ?? "").lowercased())
            && containers.contains((media.container ?? "").lowercased())
    }

    // MARK: - Quality

    /// "FLAC · 24-bit · 96 kHz", or the transcode it will be. Stream details
    /// come from the track's full metadata once it has been fetched.
    func quality(of track: PlexMetadata) -> String {
        guard !connection.isRelay, Self.avFoundationPlays(track.Media?.first) else { return "AAC 320 (transcode)" }
        let media = (track.ratingKey.flatMap { details[$0] } ?? track).Media?.first
        let audio = media?.Part?.first?.Stream?.first { $0.streamType == 2 }
        var parts = [(media?.audioCodec ?? "").uppercased()]
        if let depth = audio?.bitDepth { parts.append("\(depth)-bit") }
        if let rate = audio?.samplingRate {
            let khz = Double(rate) / 1000
            parts.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        } else if let kbps = media?.bitrate {
            parts.append("\(kbps) kbps")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func fetchDetails(_ track: PlexMetadata) {
        guard let key = track.ratingKey, details[key] == nil, !fetching.contains(key) else { return }
        fetching.insert(key)
        let connection = connection
        Task {
            let full = try? await network.getMetadata(serverURL: connection.serverURL, authToken: connection.token,
                                                      ratingKey: key)
            if let full { details[key] = full }
            // A failure is left in `fetching`: the list's own details stand.
        }
    }

    // MARK: - Plex reporting

    private func report(force: Bool) {
        guard let track = current, force || Date().timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = Date()
        reportedItem = player.currentItem
        let state = isPlaying ? "playing" : "paused"
        let time = time
        Task { await report(track, time: time, state: state) }
    }

    private func report(_ track: PlexMetadata, time: Double, state: String) async {
        guard let key = track.ratingKey else { return }
        _ = try? await network.reportProgress(
            serverURL: connection.serverURL, authToken: connection.token, ratingKey: key,
            timeMs: Int(max(0, time.isFinite ? time : 0) * 1000), state: state, duration: track.duration,
            sessionIdentifier: sessionID)
    }

    private func scrobble(_ track: PlexMetadata) {
        guard let key = track.ratingKey else { return }
        let connection = connection
        Task {
            try? await network.markWatched(
                serverURL: connection.serverURL, authToken: connection.token, ratingKey: key)
        }
    }
}
