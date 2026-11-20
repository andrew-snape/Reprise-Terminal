// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLIPlayer.swift
//  reprise (terminal)
//
//  An AVQueuePlayer over a list of tracks, gapless within the list, with Plex
//  told what plays. One X-Plex-Session-Identifier covers the whole run and
//  "stopped" is sent only when playback ends (CLAUDE.md, Music: a new id per
//  track or a "stopped" mid-queue makes Plex drop the file still being read).
//

import AVFoundation
import Foundation

final class CLIPlayer {
    let connection: CLIConnection
    private let network = PlexNetworkManager.shared
    private let player = AVQueuePlayer()
    private let sessionID = UUID().uuidString

    private(set) var tracks: [PlexMetadata] = []
    /// Index into `tracks` of the item AVPlayer is on.
    private(set) var index: Int?
    private var items: [ObjectIdentifier: Int] = [:]
    private var lastReport = Date.distantPast
    private var lastReportedIndex: Int?

    init(connection: CLIConnection) {
        self.connection = connection
        player.actionAtItemEnd = .advance
    }

    var current: PlexMetadata? { index.map { tracks[$0] } }
    var isPlaying: Bool { player.timeControlStatus != .paused }
    var isWaiting: Bool { player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
    var time: Double { player.currentTime().seconds }
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
        } else {
            load(from: index - 1)
            player.play()
        }
    }

    func seek(by seconds: Double) {
        let target = max(0, min(time + seconds, duration - 1))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop() async {
        player.pause()
        if let track = current {
            await report(track, state: "stopped")
        }
        player.removeAllItems()
        tracks = []
        index = nil
    }

    /// Call often: follows AVPlayer onto the next item and keeps Plex told.
    /// Returns a message when a track could not be played.
    func tick() -> String? {
        if let item = player.currentItem, item.status == .failed {
            let title = current?.title ?? "A track"
            player.advanceToNextItem()
            index = player.currentItem.flatMap { items[ObjectIdentifier($0)] }
            return "\(title) wouldn't play, skipped."
        }
        let now = player.currentItem.flatMap { items[ObjectIdentifier($0)] }
        if now != index {
            if let old = index {
                if now == old + 1 {
                    // The queue moved on by itself: the previous track played out.
                    scrobble(tracks[old])
                } else if now == nil {
                    // The last track played out: the queue is done.
                    scrobble(tracks[old])
                    let track = tracks[old]
                    Task { await report(track, state: "stopped") }
                }
            }
            index = now
            if now != nil { report(force: true) }
        } else {
            report(force: false)
        }
        return nil
    }

    // MARK: - Loading

    private func load(from start: Int) {
        player.removeAllItems()
        items = [:]
        for i in start..<tracks.count {
            guard let url = url(for: tracks[i]) else { continue }
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 30
            items[ObjectIdentifier(item)] = i
            player.insert(item, after: nil)
        }
        index = player.currentItem.flatMap { items[ObjectIdentifier($0)] }
    }

    /// The file itself when AVFoundation opens it, else a 320k AAC transcode.
    /// Relay connections always transcode.
    private func url(for track: PlexMetadata) -> URL? {
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
            return components.url
        }
        guard let key = track.ratingKey else { return nil }
        return network.buildMusicTranscodeURL(serverURL: connection.serverURL, authToken: connection.token,
                                              ratingKey: key, sessionID: UUID().uuidString)
    }

    /// Codecs and containers AVFoundation opens on its own (as MacPlexSession).
    static func avFoundationPlays(_ media: PlexMedia?) -> Bool {
        guard let media else { return false }
        let codecs: Set<String> = ["mp3", "aac", "alac", "flac", "pcm", "ac3", "eac3"]
        let containers: Set<String> = ["mp3", "mp4", "m4a", "flac", "wav", "aiff", "aif", "aac", "caf"]
        return codecs.contains((media.audioCodec ?? "").lowercased())
            && containers.contains((media.container ?? "").lowercased())
    }

    /// "FLAC · 24-bit · 96 kHz", or the transcode it will be.
    func quality(of track: PlexMetadata) -> String {
        let media = track.Media?.first
        guard !connection.isRelay, Self.avFoundationPlays(media) else { return "AAC 320 (transcode)" }
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

    // MARK: - Plex reporting

    private func report(force: Bool) {
        guard let track = current, force || Date().timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = Date()
        let state = isPlaying ? "playing" : "paused"
        Task { await report(track, state: state) }
    }

    private func report(_ track: PlexMetadata, state: String) async {
        guard let key = track.ratingKey else { return }
        _ = try? await network.reportProgress(
            serverURL: connection.serverURL, authToken: connection.token, ratingKey: key,
            timeMs: Int(max(0, time) * 1000), state: state, duration: track.duration,
            sessionIdentifier: sessionID)
    }

    private func scrobble(_ track: PlexMetadata) {
        guard let key = track.ratingKey else { return }
        let connection = connection
        Task {
            try? await PlexNetworkManager.shared.markWatched(
                serverURL: connection.serverURL, authToken: connection.token, ratingKey: key)
        }
    }
}
