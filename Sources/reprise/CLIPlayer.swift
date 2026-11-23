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
//  Also here: queue editing, loudness levelling from Plex's gain analysis, the
//  read-ahead into the disk cache (`CLICache`), the whole-file download that
//  rescues a big lossless track stuck starting, and the saved queue that comes
//  back on the next launch.
//

import AVFoundation
import Foundation

final class CLIPlayer {
    /// The server address everything plays from. Changed only by `switchConnection`.
    private(set) var connection: CLIConnection
    private let network = PlexNetworkManager.shared
    private let player = AVQueuePlayer()
    private let sessionID = UUID().uuidString
    /// Cache downloads read under their own session id: a read still open on
    /// `sessionID` makes Plex refuse AVPlayer's request for the same file.
    private let downloadSessionID = UUID().uuidString
    private let cache = CLICache()
    /// On a metered or constrained network nothing is read ahead.
    var metered = false

    /// An item in the queue, held until it is left so its identity is never reused.
    private struct Entry {
        let item: AVPlayerItem
        /// Index into `tracks`; shifted when the queue is edited.
        var index: Int
        /// The transcoder's session, when the item is a transcode.
        let transcode: String?
        /// The cached file it plays from.
        var file: URL?
        var isLocal: Bool { file != nil }
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
    /// Full metadata by rating key: stream details for the quality text and the
    /// loudness gain (lists lack both).
    private var details: [String: PlexMetadata] = [:]
    private var fetching: Set<String> = []
    /// The current item failed to reach the server; it is retried after a reconnect.
    private(set) var needsReconnect = false
    /// A restored queue's place, loaded only when play is pressed: AVPlayer reads
    /// ahead even when paused, and a read left open makes Plex refuse the next
    /// request for the same file on this session.
    private var restoredAt: Double?
    /// The track a refused file was retried for; a second refusal skips it.
    private var refusedRetry: Int?
    /// A refused track is held, with nothing in AVPlayer, until it is loaded again.
    private var retrying = false
    /// Bumped by every `load`; a retry scheduled before one is dropped.
    private var generation = 0

    /// Loudness levelling (Plex's gain analysis), on unless turned off.
    var levelling = true { didSet { applyVolume() } }
    /// An album played in order keeps its album gain; anything else uses track gain.
    private var prefersAlbumGain = false

    /// When the current direct-play item started waiting, and the download rescuing it.
    private var waitingSince: Date?
    private var download: (index: Int, task: Task<Void, Never>)?
    private var endObserver: NSObjectProtocol?

    init(connection: CLIConnection) {
        self.connection = connection
        player.actionAtItemEnd = .advance
        // The next item's level is set the moment the last one ends, not a tick later.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let ended = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemEnded(ended) }
        }
    }

    var current: PlexMetadata? { index.map { tracks[$0] } }
    var isPlaying: Bool { player.timeControlStatus != .paused || playAfterSeek || retrying }
    var isWaiting: Bool { needsReconnect || retrying || player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
    var time: Double { restoredAt ?? pendingSeek ?? player.currentTime().seconds }
    var duration: Double {
        if restoredAt == nil, let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { return d }
        return Double(current?.duration ?? 0) / 1000
    }

    // MARK: - Transport

    func play(_ list: [PlexMetadata], from start: Int) {
        tracks = list
        prefersAlbumGain = Set(list.map { $0.parentRatingKey ?? "" }).count == 1
        load(from: start)
        player.play()
        saveState()
    }

    /// The queue from last time, paused where it stopped.
    func restore(_ list: [PlexMetadata], index start: Int, at time: Double) {
        load(from: tracks.count)  // Clears anything loaded.
        tracks = list
        prefersAlbumGain = Set(list.map { $0.parentRatingKey ?? "" }).count == 1
        index = start
        restoredAt = time
    }

    func togglePause() {
        if let at = restoredAt, let index {
            // The restored queue is loaded now, at its place.
            load(from: index)
            if at > 1 {
                pendingSeek = at
                playAfterSeek = true
            } else {
                player.play()
            }
            report(force: true)
            return
        }
        if isPlaying {
            player.pause()
            playAfterSeek = false
        } else {
            player.play()
        }
        report(force: true)
        saveState()
    }

    func play() { if !isPlaying { togglePause() } }
    func pause() { if isPlaying { togglePause() } }

    func next() {
        guard let index, index + 1 < tracks.count else { return }
        // The next track is already queued, its file already open: move onto it.
        // Loading it afresh would ask Plex for a file this session is still
        // reading, which it refuses for a moment.
        if restoredAt == nil, let playing = followed, playing.item === player.currentItem,
           let upcoming = entries.first(where: { $0.index == index + 1 && $0.item.status != .failed }) {
            player.volume = volume(for: tracks[upcoming.index])
            forget(playing)  // Left, not played out: no scrobble.
            player.advanceToNextItem()
            followed = nil   // `tick` takes it from here without counting a play.
            self.index = upcoming.index
            player.play()
            return
        }
        restoredAt = nil
        load(from: index + 1)
        player.play()
    }

    func previous() {
        guard let index else { return }
        if time > 3 || index == 0 {
            seek(to: 0)
        } else {
            restoredAt = nil
            load(from: index - 1)
            player.play()
        }
    }

    func seek(by seconds: Double) {
        seek(to: time + seconds)
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration - 1))
        if restoredAt != nil {
            restoredAt = target
            return
        }
        if pendingSeek != nil {
            pendingSeek = target
        } else {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }
        report(force: true)
    }

    /// Ends playback: the queue is saved for next time, Plex hears "stopped"
    /// and every transcoder is freed.
    func stop() async {
        saveState()
        player.pause()
        // A restored queue never played: Plex has nothing to hear about.
        let track = restoredAt == nil ? current : nil
        let time = time
        let left = entries
        player.removeAllItems()
        entries = []
        followed = nil
        tracks = []
        index = nil
        download?.task.cancel()
        cache.cancel(except: [])
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

    // MARK: - Queue editing

    /// Adds tracks after the current one (`next`) or at the end. With nothing
    /// playing, they simply play.
    func enqueue(_ list: [PlexMetadata], next: Bool) {
        guard !list.isEmpty else { return }
        guard let index else {
            play(list, from: 0)
            return
        }
        let at = next ? index + 1 : tracks.count
        tracks.insert(contentsOf: list, at: at)
        shift(from: at, by: list.count)
        prefersAlbumGain = false
        // A restored queue isn't loaded yet; the new tracks load with it.
        if restoredAt != nil {
            saveState()
            return
        }
        // Playing next replaces the queued follow-on; anything later is queued in its turn.
        if next { dropQueued() }
        topUp()
        saveState()
    }

    /// Keeps the current track playing and puts `list` after it in place of the
    /// rest (radio from what is playing). Loading the playing track afresh would
    /// ask Plex for a file this session is already reading. With nothing playing,
    /// the list simply plays.
    func replaceUpcoming(with list: [PlexMetadata]) {
        guard let index else {
            play(list, from: 0)
            return
        }
        tracks = Array(tracks[...index]) + list
        prefersAlbumGain = false
        if restoredAt == nil {
            dropQueued()
            topUp()
        }
        saveState()
    }

    /// Takes a track out of the queue; removing the playing one moves to the next.
    func remove(at i: Int) {
        guard tracks.indices.contains(i) else { return }
        if i == index {
            let wasPlaying = isPlaying
            tracks.remove(at: i)
            if i < tracks.count {
                load(from: i)
                if wasPlaying { player.play() }
            } else {
                let left = entries
                player.removeAllItems()
                entries = []
                followed = nil
                index = nil
                for entry in left.prefix(1) { Task { await stopTranscode(entry) } }
            }
        } else {
            if let entry = entries.first(where: { $0.index == i }) {
                player.remove(entry.item)
                forget(entry)
            }
            tracks.remove(at: i)
            shift(from: i + 1, by: -1)
            topUp()
        }
        saveState()
    }

    /// Moves every index at or after `from` by `delta`.
    private func shift(from: Int, by delta: Int) {
        for i in entries.indices where entries[i].index >= from { entries[i].index += delta }
        if let f = followed?.index, f >= from { followed?.index = f + delta }
        if let i = index, i >= from { index = i + delta }
        if let r = retriedIndex, r >= from { retriedIndex = r + delta }
        if let d = download, d.index >= from { download = (d.index + delta, d.task) }
    }

    // MARK: - Tick

    /// Call often: follows AVPlayer onto the next item and keeps Plex told.
    /// Returns a message when a track could not be played.
    func tick() -> String? {
        var message: String?
        if !needsReconnect, !retrying, let item = player.currentItem, item.status == .failed {
            let entry = entry(for: item)
            let title = entry.map { tracks[$0.index].title ?? "A track" } ?? "A track"
            if let error = item.error, CLISignIn.isNetworkError(error), retriedIndex != entry?.index,
               entry?.isLocal != true {
                if let entry, refusedRetry != entry.index {
                    // Usually not the network: Plex refuses a file for a moment while an
                    // earlier read of it on this session closes (-1008). One quiet retry.
                    holdAndRetry(entry.index, at: player.currentTime().seconds)
                    return nil
                }
                // Refused twice: the server went away, not the file. Hold here and reconnect.
                needsReconnect = true
                return "Lost \(connection.serverName). Reconnecting…"
            }
            player.advanceToNextItem()
            if let entry {
                // A cached file that won't play is fetched afresh next time.
                if entry.isLocal, let name = cacheName(tracks[entry.index]) { cache.remove(name) }
                forget(entry)
                if player.currentItem == nil {
                    // It was the last track: the queue is done.
                    let track = tracks[entry.index]
                    Task { await report(track, time: 0, state: "stopped") }
                    Self.clearState()
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
            if let old = followed, old.item.status == .failed {
                // AVQueuePlayer skipped a failed item on its own: it didn't play out.
                // Plex refuses a file for a moment while an earlier read of it on
                // this session closes, so it gets one retry before it is skipped.
                if refusedRetry != old.index {
                    holdAndRetry(old.index, at: 0)
                    return message
                }
                if old.isLocal, let name = cacheName(tracks[old.index]) { cache.remove(name) }
                forget(old)
                refusedRetry = nil
                message = "\(tracks[old.index].title ?? "A track") wouldn't play, skipped."
            } else if let old = followed {
                // AVPlayer moved on by itself: the previous track played out.
                scrobble(tracks[old.index])
                forget(old)
                if now == nil, old.index + 1 < tracks.count {
                    // Its follow-on wasn't queued (or was dropped): load it now.
                    load(from: old.index + 1)
                    player.play()
                    return message
                }
                if now == nil {
                    let track = tracks[old.index]
                    Task { await report(track, time: 0, state: "stopped") }
                    Self.clearState()
                }
            }
            followed = now
            index = now?.index
            if index != retriedIndex { retriedIndex = nil }
            if index != refusedRetry { refusedRetry = nil }
            waitingSince = nil
            // A download for the track just left is no use now.
            if let d = download, d.index != index {
                d.task.cancel()
                download = nil
            }
            applyVolume()
            if now != nil {
                topUp()
                saveState()
            }
        }
        if let index {
            fetchDetails(tracks[index])
            if index + 1 < tracks.count { fetchDetails(tracks[index + 1]) }
        }
        rescueSlowStart()
        readAhead()
        report(force: player.currentItem != nil && player.currentItem !== reportedItem)
        return message
    }

    // MARK: - Cache: read-ahead and slow start

    /// The cache name of a track's file, when it can be played as a file at all.
    private func cacheName(_ track: PlexMetadata) -> String? {
        guard Self.avFoundationPlays(track.Media?.first) else { return nil }
        return CLICache.name(for: track, serverID: connection.serverID)
    }

    func isCached(_ track: PlexMetadata) -> Bool {
        cacheName(track).map(cache.contains) ?? false
    }

    /// Keeps the next two direct-play tracks downloading into the cache, one
    /// read at a time beside AVPlayer's. When the queued follow-on lands before
    /// it starts, it is swapped for the file. Never on relay or a metered network.
    private func readAhead() {
        guard restoredAt == nil, let index else {
            cache.cancel(except: [])
            return
        }
        var keep: Set<String> = []
        var wanted: Set<String> = []
        for i in index..<min(index + 3, tracks.count) {
            guard let name = cacheName(tracks[i]) else { continue }
            keep.insert(name)
            guard i > index, !connection.isRelay, !metered, !cache.contains(name),
                  let url = directURL(for: tracks[i], session: downloadSessionID) else { continue }
            wanted.insert(name)
            // One download at a time: the nearer track first.
            if wanted.count == 1 { _ = cache.fetch(name, from: url, size: tracks[i].Media?.first?.Part?.first?.size) }
        }
        if let d = download, let name = cacheName(tracks[d.index]) { wanted.insert(name) }
        cache.protected = keep
        cache.cancel(except: wanted)

        // The follow-on is queued streaming; with its file here, play that instead.
        if let playing = followed, playing.item === player.currentItem,
           let queued = entries.first(where: { $0.index == index + 1 }), !queued.isLocal,
           let name = cacheName(tracks[queued.index]), cache.contains(name),
           duration - time > 10 {
            dropQueued()
            topUp()
        }
    }

    /// AVPlayer's own progressive read of a big lossless file can sit waiting for
    /// 20 to 30 s. While the current direct-play item has waited more than 1.5 s,
    /// the whole file is downloaded into the cache; if the track is still waiting
    /// when it lands, it carries on from the file at the same place (as Reprise for
    /// Mac's `playCurrentFromFile`). Never on relay, never for a transcode.
    private func rescueSlowStart() {
        guard let entry = followed, entry.transcode == nil, !entry.isLocal, !connection.isRelay,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            waitingSince = nil
            return
        }
        let since = waitingSince ?? Date()
        waitingSince = since
        let track = tracks[entry.index]
        guard Date().timeIntervalSince(since) > 1.5, download?.index != entry.index,
              let name = cacheName(track),
              let url = directURL(for: track, session: downloadSessionID) else { return }
        download?.task.cancel()
        let index = entry.index
        let fetch = cache.fetch(name, from: url, size: track.Media?.first?.Part?.first?.size)
        let task = Task { [weak self] in
            guard let file = await fetch.value, let self, !Task.isCancelled else { return }
            self.swapToFile(file, index: index)
        }
        download = (index, task)
    }

    private func swapToFile(_ file: URL, index: Int) {
        download = nil
        // It started (or moved on) without the file: it stays cached for next time.
        guard let old = followed, old.index == index,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        let at = time
        let item = makeItem(file)
        let entry = Entry(item: item, index: index, transcode: nil, file: file)
        entries.append(entry)
        player.insert(item, after: old.item)
        entries.removeAll { $0.item === old.item }
        followed = entry
        player.advanceToNextItem()
        pendingSeek = at > 1 ? at : nil
        playAfterSeek = pendingSeek != nil
        if pendingSeek == nil { player.play() }
        reportedItem = item
    }

    // MARK: - Loading

    /// Plays from `start`: the track and the one after it go into AVPlayer, the
    /// rest are queued in turn as each starts (as Reprise for Mac does). With the
    /// whole list in AVPlayer, one refused file made it run on through the rest.
    private func load(from start: Int) {
        generation += 1
        retrying = false
        restoredAt = nil
        // The old queue is left. AVPlayer only reads the current item and the next,
        // so only those two can have a transcoder running.
        for entry in entries.prefix(2) { Task { await stopTranscode(entry) } }
        download?.task.cancel()
        download = nil
        waitingSince = nil
        player.removeAllItems()
        entries = []
        pendingSeek = nil
        playAfterSeek = false
        guard start < tracks.count else {
            followed = nil
            index = nil
            return
        }
        for i in start..<tracks.count {
            guard let (url, transcode) = source(for: tracks[i]) else { continue }
            let item = makeItem(url)
            entries.append(Entry(item: item, index: i, transcode: transcode, file: url.isFileURL ? url : nil))
            player.insert(item, after: nil)
            break
        }
        followed = player.currentItem.flatMap { entry(for: $0) }
        index = followed?.index
        applyVolume()
        topUp()
    }

    /// Queues the track after the current one, if it isn't queued already.
    private func topUp() {
        guard restoredAt == nil, let current = followed, current.item === player.currentItem,
              !entries.contains(where: { $0.index > current.index }) else { return }
        for i in (current.index + 1)..<max(current.index + 1, tracks.count) {
            guard let (url, transcode) = source(for: tracks[i]) else { continue }
            let item = makeItem(url)
            entries.append(Entry(item: item, index: i, transcode: transcode, file: url.isFileURL ? url : nil))
            player.insert(item, after: current.item)
            return
        }
    }

    /// Takes the queued follow-on out, so a different track can follow.
    private func dropQueued() {
        guard let current = followed else { return }
        for entry in entries where entry.index > current.index && entry.item !== current.item {
            player.remove(entry.item)
            forget(entry)
        }
    }

    /// Holds a refused track with nothing in AVPlayer (so it can't run on to the
    /// next) and loads it again a second later, once. A load in between cancels it.
    private func holdAndRetry(_ wanted: Int, at seconds: Double) {
        refusedRetry = wanted
        let left = entries
        player.removeAllItems()
        for entry in left.prefix(2) { Task { await stopTranscode(entry) } }
        entries = []
        followed = nil
        index = wanted
        download?.task.cancel()
        download = nil
        retrying = true
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.retrying,
                      self.tracks.indices.contains(wanted) else { return }
                self.load(from: wanted)
                if seconds.isFinite, seconds > 1 {
                    self.pendingSeek = seconds
                    self.playAfterSeek = true
                } else {
                    self.player.play()
                }
            }
        }
    }

    private func makeItem(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        return item
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

    /// The cached file when there is one (even on relay), else the file itself
    /// when AVFoundation opens it, else a 320k AAC transcode (with its
    /// transcoder session). Relay connections otherwise always transcode.
    private func source(for track: PlexMetadata) -> (URL, String?)? {
        if let name = cacheName(track), let file = cache.file(for: name) { return (file, nil) }
        if !connection.isRelay, let url = directURL(for: track, session: sessionID) { return (url, nil) }
        guard let key = track.ratingKey else { return nil }
        let transcode = UUID().uuidString
        return network.buildMusicTranscodeURL(serverURL: connection.serverURL, authToken: connection.token,
                                              ratingKey: key, sessionID: transcode).map { ($0, transcode) }
    }

    /// The track's file on the server, read under `session`; nil when AVFoundation can't open it.
    private func directURL(for track: PlexMetadata, session: String) -> URL? {
        let media = track.Media?.first
        guard Self.avFoundationPlays(media), let partKey = media?.Part?.first?.key,
              let base = URL(string: connection.serverURL),
              var components = URLComponents(url: base.appending(path: partKey), resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "X-Plex-Token", value: connection.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: session)
        ]
        return components.url
    }

    /// Codecs and containers AVFoundation opens on its own (as MacPlexSession).
    static func avFoundationPlays(_ media: PlexMedia?) -> Bool {
        guard let media else { return false }
        let codecs: Set<String> = ["mp3", "aac", "alac", "flac", "pcm", "ac3", "eac3"]
        let containers: Set<String> = ["mp3", "mp4", "m4a", "flac", "wav", "aiff", "aif", "aac", "caf"]
        return codecs.contains((media.audioCodec ?? "").lowercased())
            && containers.contains((media.container ?? "").lowercased())
    }

    // MARK: - Loudness

    private func itemEnded(_ item: AVPlayerItem?) {
        // AVPlayer is about to start the item after this one: level it now.
        guard let item, let ended = entry(for: item) else { return }
        let next = entries.filter { $0.index > ended.index }.min { $0.index < $1.index }
        player.volume = volume(for: next.map { tracks[$0.index] })
    }

    private func applyVolume() {
        player.volume = volume(for: current)
    }

    private func volume(for track: PlexMetadata?) -> Float {
        guard levelling, let key = track?.ratingKey, let full = details[key] else { return 1 }
        return LoudnessLevelling.volume(for: full.audioStream, preferAlbum: prefersAlbumGain)
    }

    // MARK: - Quality

    /// "FLAC · 24-bit · 96 kHz", or the transcode it will be. Stream details
    /// come from the track's full metadata once it has been fetched.
    func quality(of track: PlexMetadata) -> String {
        let cached = isCached(track)
        guard cached || !connection.isRelay, Self.avFoundationPlays(track.Media?.first) else { return "AAC 320 (transcode)" }
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
        if cached { parts.append("cached") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func fetchDetails(_ track: PlexMetadata) {
        guard let key = track.ratingKey, details[key] == nil, !fetching.contains(key) else { return }
        fetching.insert(key)
        let connection = connection
        Task {
            let full = try? await network.getMetadata(serverURL: connection.serverURL, authToken: connection.token,
                                                      ratingKey: key)
            guard let full else { return }  // Left in `fetching`: the list's own details stand.
            details[key] = full
            if current?.ratingKey == key { applyVolume() }
        }
    }

    // MARK: - Saved queue

    private struct SavedQueue: Codable {
        var serverID: String
        var keys: [String]
        var index: Int
        var time: Double
    }

    nonisolated private static var stateFile: URL {
        URL.applicationSupportDirectory.appending(path: "reprise-cli/queue.json")
    }

    private func saveState() {
        guard let index, !tracks.isEmpty else { return }
        let keys = tracks.compactMap(\.ratingKey)
        guard keys.count == tracks.count else { return }
        let state = SavedQueue(serverID: connection.serverID, keys: keys, index: index,
                               time: max(0, time.isFinite ? time : 0))
        guard let data = try? JSONEncoder().encode(state) else { return }
        FileManager.default.createFile(atPath: Self.stateFile.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    nonisolated static func clearState() {
        try? FileManager.default.removeItem(at: stateFile)
    }

    /// The saved queue's tracks for this server, fetched in batches, with where it was.
    static func savedQueue(connection: CLIConnection) async -> (tracks: [PlexMetadata], index: Int, time: Double)? {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(SavedQueue.self, from: data),
              state.serverID == connection.serverID, state.keys.indices.contains(state.index) else { return nil }
        let network = PlexNetworkManager.shared
        var found: [String: PlexMetadata] = [:]
        for start in stride(from: 0, to: state.keys.count, by: 100) {
            let batch = state.keys[start..<min(start + 100, state.keys.count)].joined(separator: ",")
            guard let url = URL(string: "\(connection.serverURL)/library/metadata/\(batch)"),
                  let container: PlexMediaContainerWrapper = try? await network.request(
                    url, headers: network.plexHeaders(authToken: connection.token)) else { return nil }
            for item in container.MediaContainer.Metadata ?? [] {
                if let key = item.ratingKey { found[key] = item }
            }
        }
        // Tracks deleted since are left out; the saved place follows its track.
        var tracks: [PlexMetadata] = []
        var index = 0
        for (i, key) in state.keys.enumerated() {
            guard let track = found[key] else { continue }
            if i == state.index { index = tracks.count }
            tracks.append(track)
        }
        guard !tracks.isEmpty, found[state.keys[state.index]] != nil else { return nil }
        return (tracks, index, state.time)
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
