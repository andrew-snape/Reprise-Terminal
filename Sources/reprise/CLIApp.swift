// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLIApp.swift
//  reprise (terminal)
//
//  The full-screen browser: libraries → artists → albums → tracks, playlists,
//  a queue page, "ask" results, the now-playing bar and a Now Playing screen
//  with the album cover. Everything runs on
//  the main actor; the screen is redrawn whole after every key and twice a
//  second. When the network changes or the server stops answering, the
//  server is probed again and playback moves to the new address.
//

import Foundation
import FoundationModels
import Network

final class CLIApp {
    private enum Kind {
        case libraries, artists, albums, tracks, queue, playlists, results
    }

    private struct Row {
        let title: String
        var detail = ""
        var library: PlexLibrary?
        var item: PlexMetadata?
    }

    private struct Page {
        let kind: Kind
        let title: String
        var rows: [Row]
        var selected = 0
        var top = 0
        var filter = ""
        /// What `a` does on a results page: how the request was read.
        var action: AskAction = .play

        /// Indices into `rows` that match the filter.
        var visible: [Int] {
            guard !filter.isEmpty else { return Array(rows.indices) }
            return rows.indices.filter { rows[$0].title.localizedStandardContains(filter) }
        }
    }

    private let network = PlexNetworkManager.shared
    private let player: CLIPlayer
    private var stack: [Page] = []
    private var filtering = false
    private var status: String?
    private var statusUntil = Date.distantPast
    private var loading = false
    private var spinner = 0
    private var timer: DispatchSourceTimer?
    private var input: DispatchSourceRead?
    private var quitting = false
    private var pathMonitor: NWPathMonitor?
    private var sawFirstPath = false
    private var pathChange: DispatchWorkItem?
    private var reconnecting = false
    private var lastReconnect = Date.distantPast
    private var loadingText = "Loading…"
    /// The music library being browsed (or the first), for ask, radio and filters.
    private var library: PlexLibrary?
    private var asking = false
    private var askText = ""
    /// The session being made (and warmed up) while the request is typed; awaited on Enter.
    private var askSession: Task<LanguageModelSession?, Never>?
    /// Earlier requests, oldest first; up and down in the prompt step through them.
    private var askHistory = AskHistory.load()
    /// Where up and down are in `askHistory` (its count: the text being typed).
    private var historyIndex = 0
    /// What was being typed before stepping back into the history.
    private var askDraft = ""
    /// A request given on the command line, asked once the library is known.
    private var launchRequest: String?
    private var nowPlaying: CLINowPlaying?
    private let artwork = CLIArtwork()
    /// The Now Playing screen (`v`) is showing instead of the list.
    private var showingNow = false
    /// What the cover area last drew; it is redrawn only when this changes.
    private var drawnArt: String?
    /// The Matrix rain's step, advanced while the Now Playing screen shows music playing.
    private var rainFrame = 1
    private var rainTimer: DispatchSourceTimer?

    /// The player owns the connection, so a reconnect changes it in one place.
    private var connection: CLIConnection { player.connection }

    init(connection: CLIConnection, request: String? = nil) {
        self.player = CLIPlayer(connection: connection)
        self.launchRequest = request
    }

    // MARK: - Run

    func run() async {
        CLIPlayer.clearCache()
        artwork.onChange = { [weak self] in
            self?.nowPlaying?.update()
            self?.draw()
        }
        nowPlaying = CLINowPlaying(player: player, artwork: artwork, onChange: { [weak self] in self?.draw() })
        TTY.enter(onResize: { [weak self] in
                      self?.drawnArt = nil
                      self?.draw()
                  },
                  onQuit: { [weak self] in self?.quit() })
        TTY.queryBackground()
        draw()

        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                var buffer = [UInt8](repeating: 0, count: 64)
                let n = read(STDIN_FILENO, &buffer, buffer.count)
                guard n > 0 else {
                    // The terminal went away (window closed): quit properly, don't spin on EOF.
                    if n == 0 || (errno != EAGAIN && errno != EINTR) { self?.quit() }
                    return
                }
                for key in TTY.decode(Array(buffer[0..<n])) { self?.handle(key) }
                self?.draw()
            }
        }
        input.resume()
        self.input = input

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let message = self.player.tick() { self.flash(message) }
                if self.player.needsReconnect, Date().timeIntervalSince(self.lastReconnect) > 10 { self.reconnect() }
                self.artwork.want(self.player.current, connection: self.connection)
                self.nowPlaying?.update()
                self.spinner += 1
                self.draw()
            }
        }
        timer.resume()
        self.timer = timer

        let rain = DispatchSource.makeTimerSource(queue: .main)
        rain.schedule(deadline: .now() + 0.12, repeating: 0.12)
        rain.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showingNow, self.artwork.isLoaded,
                      self.player.isPlaying, !self.player.isWaiting else { return }
                self.rainFrame += 1
                self.draw()
            }
        }
        rain.resume()
        rainTimer = rain

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.pathChanged(online: path.status == .satisfied) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor

        await loadLibraries()
    }

    /// The queue from last time, paused where it stopped.
    private func resumeQueue() {
        Task {
            guard let saved = await CLIPlayer.savedQueue(connection: connection), player.current == nil else { return }
            player.restore(saved.tracks, index: saved.index, at: saved.time)
            flash("Picked up where you left off. Space plays.")
        }
    }

    private func quit() {
        guard !quitting else { return }
        quitting = true
        input?.cancel()
        Task {
            // Up to two seconds for Plex to hear "stopped".
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.player.stop() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            CLIPlayer.clearCache()
            TTY.restore()
            exit(0)
        }
    }

    // MARK: - Reconnecting

    /// A network change (after the first report, which is just the current
    /// state): once it settles, see whether the server is now best reached elsewhere.
    private func pathChanged(online: Bool) {
        guard sawFirstPath else { sawFirstPath = true; return }
        guard online else { return }
        pathChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reconnect() }
        }
        pathChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Probes the server again; one probe at a time.
    private func reconnect() {
        guard !reconnecting, !quitting else { return }
        reconnecting = true
        lastReconnect = Date()
        let old = connection
        Task {
            let new = await CLISignIn.reprobe(old)
            reconnecting = false
            guard let new else {
                if player.needsReconnect { flash("Can't reach \(old.serverName). Trying again…") }
                return
            }
            let moved = new.serverURL != old.serverURL
            if moved || player.needsReconnect {
                player.switchConnection(new)
            }
            if moved { flash("Reconnected to \(new.serverName)\(new.isRelay ? " (relay)" : "").") }
        }
    }

    // MARK: - Loading

    private func load(_ text: String = "Loading…", _ work: @escaping () async throws -> Void) {
        loadingText = text
        loading = true
        draw()
        Task {
            do {
                try await work()
            } catch {
                flash("Plex didn't answer: \(SensitiveDataRedactor.redact(error.localizedDescription))")
                if CLISignIn.isNetworkError(error) { reconnect() }
            }
            loading = false
            draw()
        }
    }

    private func loadLibraries() async {
        load { [self] in
            let libraries = try await network.getLibraries(serverURL: connection.serverURL, authToken: connection.token)
                .filter { $0.type == "artist" }
            library = libraries.first
            // A request from the command line replaces the queue, so last time's isn't picked up.
            let request = launchRequest
            launchRequest = nil
            if libraries.count == 1 {
                try await openLibrary(libraries[0])
            } else if libraries.isEmpty {
                flash("No music libraries on \(connection.serverName).")
            } else {
                stack = [Page(kind: .libraries, title: "Music",
                              rows: libraries.map { Row(title: $0.title, library: $0) })]
            }
            if let request, let library {
                let connection = connection
                askSession = Task { await CLIAsk.session(connection: connection, section: library.key) }
                loadingText = CLIAsk.isAvailable ? "Thinking…" : "Searching…"
                draw()
                // Nothing played (a typo, or a page of choices): last time's queue is still there.
                if try await !ask(request) { resumeQueue() }
            } else {
                resumeQueue()
            }
        }
    }

    private func openLibrary(_ library: PlexLibrary) async throws {
        self.library = library
        var artists: [PlexMetadata] = []
        let size = 500
        while true {
            let batch = try await network.getLibraryItems(serverURL: connection.serverURL, authToken: connection.token,
                                                          sectionId: library.key, start: artists.count, size: size, type: 8)
            artists += batch
            if batch.count < size { break }
        }
        push(Page(kind: .artists, title: library.title, rows: artists.map {
            Row(title: $0.title ?? "Unknown Artist", item: $0)
        }))
    }

    private func children(of item: PlexMetadata) async throws -> [PlexMetadata] {
        guard let key = item.ratingKey else { return [] }
        return try await network.getChildren(serverURL: connection.serverURL, authToken: connection.token, ratingKey: key)
    }

    private func push(_ page: Page) {
        stack.append(page)
        filtering = false
    }

    private func trackRows(_ tracks: [PlexMetadata], numbered: Bool) -> [Row] {
        tracks.enumerated().map { i, t in
            let number = numbered ? String(format: "%2d  ", t.index ?? i + 1) : ""
            let artist = numbered ? "" : t.grandparentTitle.map { " · \($0)" } ?? ""
            return Row(title: number + (t.title ?? "Untitled") + artist,
                       detail: formatTime(Double(t.duration ?? 0) / 1000), item: t)
        }
    }

    // MARK: - Keys

    private func handle(_ key: Key) {
        switch key {
        case .focus(true):
            TTY.queryBackground()  // The appearance may have changed while away.
            return
        case .focus:
            return
        case .background(let light):
            if light != TTY.light {
                TTY.light = light
                drawnArt = nil
            }
            return
        default:
            break
        }
        if asking {
            handleAsk(key)
            return
        }
        if filtering {
            handleFilter(key)
            return
        }
        if showingNow {
            switch key {
            case .left, .backspace, .escape, .char("h"), .char("v"):
                showingNow = false
                return
            case .tab, .char(":"), .char("P"):
                showingNow = false  // And on to the queue, ask or playlists.
            case .up, .down, .pageUp, .pageDown, .home, .end, .enter, .right,
                 .char("j"), .char("k"), .char("l"), .char("g"), .char("G"), .char("/"),
                 .char("a"), .char("s"), .char("+"), .char("="), .char("x"):
                return  // List keys: there is no list here.
            default:
                break
            }
        }
        switch key {
        case .char("q"), .char("\u{03}"): quit()
        case .up, .char("k"): moveSelection(-1)
        case .down, .char("j"): moveSelection(1)
        case .pageUp: moveSelection(-listHeight)
        case .pageDown: moveSelection(listHeight)
        case .home, .char("g"): moveSelection(-Int.max / 2)
        case .end, .char("G"): moveSelection(Int.max / 2)
        case .enter, .right, .char("l"): open()
        case .left, .backspace, .escape, .char("h"): back()
        case .char("/"):
            guard !stack.isEmpty else { return }
            filtering = true
        case .char(" "): player.togglePause()
        case .char("n"), .char(">"): player.next()
        case .char("p"), .char("<"): player.previous()
        case .char("."), .char("]"): player.seek(by: 10)
        case .char(","), .char("["): player.seek(by: -10)
        case .char("s"): playSelection(.shuffle)
        case .char("a"): playSelection(.play)
        case .char("r"): playSelection(.radio)
        case .char("+"): enqueueSelection(next: true)
        case .char("="): enqueueSelection(next: false)
        case .char("x"): removeFromQueue()
        case .char(":"): startAsk()
        case .char("P"): openPlaylists()
        case .char("L"):
            player.levelling.toggle()
            flash(player.levelling ? "Loudness levelling on." : "Loudness levelling off.")
        case .tab: toggleQueue()
        case .char("v"):
            guard player.current != nil else { flash("Nothing playing yet."); return }
            showNowPlaying()
        default: break
        }
        artwork.want(player.current, connection: connection)
        nowPlaying?.update()
    }

    // MARK: - Ask

    private func startAsk() {
        guard let library else { flash("No music library to ask."); return }
        asking = true
        askText = ""
        askDraft = ""
        historyIndex = askHistory.count
        let connection = connection
        askSession = Task { await CLIAsk.session(connection: connection, section: library.key) }
    }

    private func handleAsk(_ key: Key) {
        switch key {
        case .escape:
            asking = false
        case .enter:
            asking = false
            let text = askText.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { runAsk(text) }
        case .backspace:
            if askText.isEmpty { asking = false } else { askText.removeLast() }
        case .up:
            guard historyIndex > 0 else { return }
            if historyIndex == askHistory.count { askDraft = askText }
            historyIndex -= 1
            askText = askHistory[historyIndex]
        case .down:
            guard historyIndex < askHistory.count else { return }
            historyIndex += 1
            askText = historyIndex == askHistory.count ? askDraft : askHistory[historyIndex]
        case .char("\u{03}"): quit()
        case .char(let c):
            askText.append(c)
        case .paste(let text):
            askText += text.pastedLine
        default:
            break
        }
    }

    private func runAsk(_ text: String) {
        load(CLIAsk.isAvailable ? "Thinking…" : "Searching…") { [self] in try await ask(text) }
    }

    /// Asks, then plays, queues or offers what was found. True when something played or was queued.
    @discardableResult
    private func ask(_ text: String) async throws -> Bool {
        guard let library else { return false }
        let pending = askSession
        askSession = nil
        AskHistory.add(text, to: &askHistory)
        // A fast Enter waits for the session rather than falling back to keyword search.
        let session = await pending?.value
        let result = try await CLIAsk.run(text, session: session, connection: connection, section: library.key,
                                          playing: player.current)
        if !result.tracks.isEmpty {
            act(on: result.tracks, action: result.action, label: result.label)
            return true
        } else if !result.choices.isEmpty {
            var page = Page(kind: .results, title: result.label, rows: result.choices.map(resultRow))
            page.action = result.action
            push(page)
        } else {
            flash(result.note ?? "Nothing found for “\(text)”.")
        }
        return false
    }

    private func resultRow(_ item: PlexMetadata) -> Row {
        let by = item.type == "album" ? item.parentTitle : item.type == "track" ? item.grandparentTitle : nil
        let kind = ["artist": "artist", "album": "album", "track": "song", "playlist": "playlist"][item.type ?? ""] ?? ""
        return Row(title: (item.title ?? "Untitled") + (by.map { " · \($0)" } ?? ""), detail: kind, item: item)
    }

    /// Plays or queues what was found, and says what it was.
    private func act(on tracks: [PlexMetadata], action: AskAction, label: String) {
        if action == .queue {
            player.enqueue(tracks, next: false)
            flash("Queued · \(label.replacingOccurrences(of: "Queue · ", with: "")) (\(tracks.count))")
            return
        }
        if let first = tracks.first?.ratingKey, first == player.current?.ratingKey {
            // Starting with what is playing (radio from it, or its album from the top while
            // the first song plays): it keeps playing, and the rest follows it. Loading it
            // afresh would ask Plex for a file this session is already reading.
            player.replaceUpcoming(with: Array(tracks.dropFirst()))
            player.play()  // Paused, or a restored queue not loaded yet: it starts, as asked.
        } else {
            player.play(tracks, from: 0)
        }
        showNowPlaying()
        flash("▶ \(label)")
    }

    /// Starting music opens the Now Playing screen; ← or v goes back to the list.
    private func showNowPlaying() {
        guard player.current != nil else { return }
        showingNow = true
        drawnArt = nil
    }

    // MARK: - Playlists, radio, queue

    private func openPlaylists() {
        guard !loading else { return }
        if stack.last?.kind == .playlists { return }
        load { [self] in
            let playlists = try await network.getAudioPlaylists(serverURL: connection.serverURL, authToken: connection.token)
            push(Page(kind: .playlists, title: "Playlists", rows: playlists.map {
                Row(title: $0.title ?? "Untitled", detail: $0.leafCount.map { "\($0) songs" } ?? "", item: $0)
            }))
        }
    }

    /// The music a row stands for: an artist's, album's or playlist's tracks, or the track itself.
    private func tracks(for item: PlexMetadata, action: AskAction) async throws -> [PlexMetadata] {
        try await CLIAsk.tracks(of: item, action: action, connection: connection, section: library?.key ?? "")
    }

    private func enqueueSelection(next: Bool) {
        guard !loading, let (_, row, _) = selectedRow, let item = row.item else { return }
        load { [self] in
            let tracks = try await tracks(for: item, action: .queue)
            guard !tracks.isEmpty else { return }
            let wasEmpty = player.current == nil
            player.enqueue(tracks, next: next)
            let what = tracks.count == 1 ? "“\(tracks[0].title ?? "Untitled")”" : "\(tracks.count) songs"
            flash(wasEmpty ? "Playing \(what)." : next ? "Up next: \(what)." : "Added \(what) to the end.")
        }
    }

    private func removeFromQueue() {
        guard stack.last?.kind == .queue, let (_, _, index) = selectedRow else { return }
        player.remove(at: index)
        refreshQueuePage()
        if player.tracks.isEmpty { stack.removeLast() }
    }

    private func refreshQueuePage() {
        guard let page = stack.last, page.kind == .queue else { return }
        stack[stack.count - 1].rows = trackRows(player.tracks, numbered: false)
        if page.selected >= player.tracks.count { stack[stack.count - 1].selected = max(0, player.tracks.count - 1) }
    }

    private func handleFilter(_ key: Key) {
        guard !stack.isEmpty else { return }
        switch key {
        case .escape:
            stack[stack.count - 1].filter = ""
            filtering = false
        case .enter:
            filtering = false
            open()
        case .up:
            moveSelection(-1)
            return
        case .down:
            moveSelection(1)
            return
        case .backspace:
            if stack[stack.count - 1].filter.isEmpty { filtering = false } else { stack[stack.count - 1].filter.removeLast() }
        case .char("\u{03}"): quit()
        case .char(let c):
            stack[stack.count - 1].filter.append(c)
        case .paste(let text):
            stack[stack.count - 1].filter += text.pastedLine
        default: return
        }
        // The matches changed: start again from the first.
        if !stack.isEmpty {
            stack[stack.count - 1].selected = 0
            stack[stack.count - 1].top = 0
        }
    }

    private func moveSelection(_ delta: Int) {
        guard var page = stack.last else { return }
        let count = page.visible.count
        guard count > 0 else { return }
        page.selected = max(0, min(count - 1, page.selected + delta))
        stack[stack.count - 1] = page
    }

    private var selectedRow: (page: Page, row: Row, index: Int)? {
        guard let page = stack.last else { return nil }
        let visible = page.visible
        guard visible.indices.contains(page.selected) else { return nil }
        let index = visible[page.selected]
        return (page, page.rows[index], index)
    }

    private func open() {
        guard !loading, let (page, row, index) = selectedRow else { return }
        switch page.kind {
        case .libraries:
            guard let library = row.library else { return }
            load { [self] in try await openLibrary(library) }
        case .artists:
            guard let artist = row.item else { return }
            load { [self] in
                let albums = try await children(of: artist)
                push(Page(kind: .albums, title: artist.title ?? "Artist", rows: albums.map {
                    Row(title: $0.title ?? "Untitled", detail: $0.year.map(String.init) ?? "", item: $0)
                }))
            }
        case .albums:
            guard let album = row.item else { return }
            load { [self] in
                let tracks = try await children(of: album)
                push(Page(kind: .tracks, title: album.title ?? "Album", rows: trackRows(tracks, numbered: true)))
            }
        case .tracks:
            player.play(page.rows.compactMap(\.item), from: index)
            showNowPlaying()
        case .queue:
            player.play(player.tracks, from: index)
            showNowPlaying()
        case .playlists:
            guard let playlist = row.item else { return }
            load { [self] in
                let tracks = try await tracks(for: playlist, action: .play)
                push(Page(kind: .tracks, title: playlist.title ?? "Playlist", rows: trackRows(tracks, numbered: false)))
            }
        case .results:
            guard let item = row.item else { return }
            switch item.type {
            case "artist":
                load { [self] in
                    let albums = try await children(of: item)
                    push(Page(kind: .albums, title: item.title ?? "Artist", rows: albums.map {
                        Row(title: $0.title ?? "Untitled", detail: $0.year.map(String.init) ?? "", item: $0)
                    }))
                }
            case "album", "playlist":
                load { [self] in
                    let tracks = try await tracks(for: item, action: .play)
                    push(Page(kind: .tracks, title: item.title ?? "Album", rows: trackRows(tracks, numbered: item.type == "album")))
                }
            default:
                playSelection(page.action)
            }
        }
    }

    /// `a` plays, `s` shuffles, `r` starts radio: from the selected row, or on a
    /// track list the whole list (radio seeds from the selected track). With no
    /// row (or on the Now Playing screen), radio seeds from what is playing.
    private func playSelection(_ action: AskAction) {
        guard !loading else { return }
        let selected = showingNow ? nil : selectedRow
        if let (page, _, index) = selected, page.kind == .tracks || page.kind == .queue, action != .radio {
            let tracks = page.kind == .queue ? player.tracks : page.rows.compactMap(\.item)
            if action == .shuffle {
                player.play(tracks.shuffled(), from: 0)
            } else {
                player.play(tracks, from: page.kind == .queue ? index : 0)
            }
            showNowPlaying()
            return
        }
        guard let item = selected?.row.item ?? (action == .radio ? player.current : nil) else { return }
        load(action == .radio ? "Tuning in…" : "Loading…") { [self] in
            var result = AskResult(label: CLIAsk.label(for: item), action: action)
            result.tracks = try await tracks(for: item, action: action)
            result = try await CLIAsk.finish(result, connection: connection)
            guard !result.tracks.isEmpty else { flash("Nothing to play there."); return }
            act(on: result.tracks, action: action, label: result.label)
        }
    }

    private func back() {
        if stack.last?.filter.isEmpty == false {
            stack[stack.count - 1].filter = ""
            return
        }
        // The first page (libraries, or the only library's artists) stays.
        if stack.count > 1 { stack.removeLast() }
    }

    private func toggleQueue() {
        if stack.last?.kind == .queue {
            stack.removeLast()
            return
        }
        guard !player.tracks.isEmpty else { flash("Nothing playing yet."); return }
        var page = Page(kind: .queue, title: "Queue", rows: trackRows(player.tracks, numbered: false))
        page.selected = player.index ?? 0
        push(page)
    }

    private func flash(_ message: String) {
        status = message
        statusUntil = Date().addingTimeInterval(4)
        draw()
    }

    // MARK: - Drawing

    /// Where the parts go for a window size. A tall window has room to breathe (a gap
    /// under the header, a rule over the track, a gap over the help); a short one drops
    /// those, then folds the progress into the track line, so the list keeps its rows.
    private struct Layout {
        let rows: Int, width: Int
        var roomy: Bool { rows >= 14 }
        var tiny: Bool { rows < 8 }
        var tooSmall: Bool { rows < 4 || width < 24 }
        var top: Int { roomy ? 3 : 2 }
        var ruleRow: Int? { roomy ? rows - 4 : nil }
        var trackRow: Int { tiny ? rows - 1 : roomy ? rows - 3 : rows - 2 }
        var progressRow: Int? { tiny ? nil : roomy ? rows - 2 : rows - 1 }
        var listHeight: Int { max(1, (ruleRow ?? trackRow) - top) }
        /// The last row the Now Playing screen may use; the help line is below.
        var bottom: Int { roomy ? rows - 2 : rows - 1 }
    }

    private var layout: Layout { Layout(rows: TTY.size.rows, width: TTY.size.cols) }
    private var listHeight: Int { layout.listHeight }

    private func draw() {
        guard !quitting else { return }
        let layout = self.layout
        let rows = layout.rows, width = layout.width
        var out = "\u{1B}[?25l"

        if layout.tooSmall {
            drawnArt = nil
            out += "\u{1B}[2J"
            let text = "Window too small".fitted(width)
            out += TTY.move(row: max(1, (rows + 1) / 2), col: max(1, (width - text.columns) / 2 + 1)) + TTY.dim + text + TTY.reset
            TTY.write(TTY.frame(out))
            return
        }

        // Header: badge, breadcrumb (its end kept), server when there's room.
        let badge = width >= 50 ? "\(TTY.accentBG)\(TTY.bold) ◆ REPRISE \(TTY.reset)" : "\(TTY.accentBG)\(TTY.bold) ◆ \(TTY.reset)"
        let badgeWidth = width >= 50 ? 11 : 3
        let crumbs = showingNow ? "Now Playing" : stack.map(\.title).joined(separator: " › ")
        let serverName = connection.serverName + (connection.isRelay ? " (relay)" : "")
        let server = width >= 60 ? serverName.fitted(width / 3) : ""
        let crumbWidth = max(0, width - badgeWidth - 2 - (server.isEmpty ? 0 : server.columns + 2))
        out += TTY.move(row: 1) + TTY.clearLine + badge + "  " + TTY.dim + crumbs.fittedTail(crumbWidth).padded(crumbWidth)
            + TTY.reset + (server.isEmpty ? "" : "  " + TTY.dim + server + TTY.reset)
        if layout.roomy { out += TTY.move(row: 2) + TTY.clearLine }

        if showingNow {
            drawNowPlaying(&out, layout: layout)
            drawFooter(&out, layout: layout)
            TTY.write(TTY.frame(out))
            return
        }
        drawnArt = nil

        // List. In a very wide window the rows stop at a readable width, so a
        // year or duration isn't far from its title.
        if stack.last?.kind == .queue, stack.last?.rows.count != player.tracks.count { refreshQueuePage() }
        let height = layout.listHeight
        let listWidth = min(width, 120)
        if var page = stack.last {
            let visible = page.visible
            if page.selected < page.top { page.top = page.selected }
            if page.selected >= page.top + height { page.top = page.selected - height + 1 }
            page.top = max(0, min(page.top, max(0, visible.count - height)))
            stack[stack.count - 1].top = page.top
            let playingKey = player.current?.ratingKey
            for line in 0..<height {
                out += TTY.move(row: layout.top + line) + TTY.clearLine
                let v = page.top + line
                guard visible.indices.contains(v) else { continue }
                let row = page.rows[visible[v]]
                let isSelected = v == page.selected
                let isPlaying = playingKey != nil && row.item?.ratingKey == playingKey
                let marker = isPlaying ? "\(TTY.pink)♪\(TTY.reset)" : " "
                let detail = listWidth >= 40 ? row.detail.fitted(listWidth / 3) : ""
                let detailWidth = detail.columns
                let titleWidth = max(4, listWidth - 6 - detailWidth)
                let title = row.title.fitted(titleWidth)
                let titlePad = String(repeating: " ", count: max(0, titleWidth - title.columns))
                if isSelected {
                    out += " \(TTY.accent)❯\(TTY.reset)\(marker) \(TTY.bold)\(title)\(TTY.reset)\(titlePad) \(TTY.dim)\(detail)\(TTY.reset)"
                } else {
                    out += "  \(marker) \(title)\(TTY.reset)\(titlePad) \(TTY.dim)\(detail)\(TTY.reset)"
                }
            }
            if visible.isEmpty, !loading {
                let note = "Nothing here" + (page.filter.isEmpty ? "" : " matches “\(page.filter)”") + "."
                out += TTY.move(row: layout.top) + "   \(TTY.dim)\(note.fitted(width - 4))\(TTY.reset)"
            }
        } else {
            for line in 0..<height { out += TTY.move(row: layout.top + line) + TTY.clearLine }
        }

        // Now playing.
        if let ruleRow = layout.ruleRow {
            out += TTY.move(row: ruleRow) + TTY.clearLine + TTY.dim + String(repeating: "─", count: width) + TTY.reset
        }
        for row in layout.trackRow..<rows { out += TTY.move(row: row) + TTY.clearLine }
        if let track = player.current {
            let spin = ["◐", "◓", "◑", "◒"][spinner % 4]
            let icon = player.isWaiting ? spin : player.isPlaying ? "▶" : "⏸"
            let elapsed = formatTime(player.time), total = formatTime(player.duration)
            let line = "\(track.title ?? "Untitled")"
            let sub = [track.grandparentTitle, track.parentTitle].compactMap { $0 }.joined(separator: " · ")
            if layout.tiny {
                // One line: state, time, then the track.
                let time = "\(elapsed) / \(total)"
                let left = max(0, width - time.count - 6)
                let titleText = line.fitted(left)
                let subText = sub.isEmpty ? "" : (" — " + sub).fitted(max(0, left - titleText.columns))
                out += TTY.move(row: layout.trackRow) + " \(TTY.accent)\(icon)\(TTY.reset) \(TTY.dim)\(time)\(TTY.reset)  \(TTY.bold)\(titleText)\(TTY.reset)\(TTY.dim)\(subText)\(TTY.reset)"
            } else {
                let quality = width >= 60 ? player.quality(of: track) : ""
                let left = max(0, width - quality.columns - 6)
                let titleText = line.fitted(left)
                let subText = sub.isEmpty ? "" : (" — " + sub).fitted(max(0, left - titleText.columns))
                let pad = String(repeating: " ", count: max(0, left - titleText.columns - subText.columns))
                out += TTY.move(row: layout.trackRow) + " \(TTY.pink)♪\(TTY.reset) \(TTY.bold)\(titleText)\(TTY.reset)\(TTY.dim)\(subText)\(TTY.reset)\(pad)  \(TTY.dim)\(quality)\(TTY.reset)"
                let bar = progressBar(width: max(4, width - elapsed.count - total.count - 9))
                out += TTY.move(row: layout.progressRow ?? rows - 1) + " \(TTY.accent)\(icon)\(TTY.reset) \(elapsed) \(bar) \(total)"
            }
        } else {
            out += TTY.move(row: layout.trackRow) + "   \(TTY.dim)Nothing playing\(TTY.reset)"
        }
        drawFooter(&out, layout: layout)
        TTY.write(TTY.frame(out))
    }

    /// The window title, and the last line: help, the ask or filter prompt, or a message.
    private func drawFooter(_ out: inout String, layout: Layout) {
        let rows = layout.rows, width = layout.width
        if let track = player.current {
            TTY.setTitle("\(player.isPlaying ? "♪" : "⏸") \(track.title ?? "Untitled")" + (track.grandparentTitle.map { " — \($0)" } ?? ""))
        } else {
            TTY.setTitle("Reprise")
        }

        // Help, filter or status. The key hints on the prompts go first when narrow.
        if layout.roomy { out += TTY.move(row: rows - 1) + TTY.clearLine }
        out += TTY.move(row: rows) + TTY.clearLine
        if asking {
            let name = CLIAsk.isAvailable ? "ask" : "search"
            let hints = width >= 50 ? "  \(TTY.dim)⏎ go  esc cancel\(TTY.reset)" : ""
            out += " \(TTY.accent)✦ \(name) ›\(TTY.reset) \(askText.fittedTail(max(1, width - name.count - 6 - hints.columns)))\(TTY.accent)▏\(TTY.reset)\(hints)"
        } else if filtering, let page = stack.last {
            let hints = width >= 40 ? "  \(TTY.dim)⏎ open  esc clear\(TTY.reset)" : ""
            out += " \(TTY.accent)/\(TTY.reset) \(page.filter.fittedTail(max(1, width - 5 - hints.columns)))\(TTY.accent)▏\(TTY.reset)\(hints)"
        } else if let status, Date() < statusUntil {
            out += " \(TTY.pink)\(status.fitted(width - 2))\(TTY.reset)"
        } else if loading {
            out += " \(TTY.accent)\(["◐", "◓", "◑", "◒"][spinner % 4])\(TTY.reset) \(TTY.dim)\(loadingText.fitted(width - 4))\(TTY.reset)"
        } else if showingNow {
            let help = ["space pause", "n/p next/prev", ",/. seek", "← back", ": ask", "r radio", "tab queue", "L levelling"]
            out += " " + TTY.dim + Self.hints(help, width: width - 2) + TTY.reset
        } else {
            var help = ["⏎ open", "← back", "space pause", ": ask", "/ filter", "n/p next/prev", "a play", "s shuffle",
                        "v now playing", "tab queue", "r radio", "+/= queue", ",/. seek", "P playlists", "L levelling"]
            if stack.last?.kind == .queue { help.insert("x remove", at: 3) }
            out += " " + TTY.dim + Self.hints(help, width: width - 2) + TTY.reset
        }
    }

    /// Whole key hints, most useful first, as many as fit, and always "q quit" last.
    private static func hints(_ items: [String], width: Int) -> String {
        let quit = "q quit"
        var shown: [String] = []
        var used = quit.columns
        for item in items {
            let cost = item.columns + 2
            guard used + cost <= width else { break }
            shown.append(item)
            used += cost
        }
        return (shown + [quit]).joined(separator: "  ").fitted(width)
    }

    private func progressBar(width barWidth: Int) -> String {
        let fraction = player.duration > 0 ? min(1, max(0, player.time / player.duration)) : 0
        let filled = Int(Double(barWidth) * fraction)
        return TTY.accent + String(repeating: "━", count: filled) + (filled < barWidth ? "╸" : "")
            + TTY.reset + TTY.dim + String(repeating: "─", count: max(0, barWidth - filled - 1)) + TTY.reset
    }

    // MARK: - Now Playing screen

    /// The cover, large, with the track under it (or beside it in a wide, short
    /// window). The cover is redrawn only when it, the layout or the rain's frame
    /// changes; paused, it isn't sent again.
    private func drawNowPlaying(_ out: inout String, layout: Layout) {
        let rows = layout.rows, width = layout.width
        let top = layout.top
        let available = max(0, layout.bottom - top + 1)  // The help line is below.
        let track = player.current
        let side = width >= 2 * available + 40
        func coverRows(_ textHeight: Int) -> Int {
            side ? available : max(0, min(available - textHeight - 1, (width - 4) / 2))
        }
        // A short window keeps just the title, artist and progress, if that buys a
        // usable cover (or the six lines don't fit at all).
        let fullCover = coverRows(6), shortCover = coverRows(3)
        let compact = side ? available < 6
            : shortCover >= 4 && fullCover < 8 && shortCover > fullCover ? true
            : fullCover < 4 && available < 6
        let textHeight = compact ? 3 : 6
        let artRows = compact ? shortCover : fullCover
        let showArt = track != nil && artRows >= 4
        let artCols = artRows * 2
        // Beside the words, the pair is centred across a very wide window.
        let artCol = side ? max(3, (width - artCols - 4 - 64) / 2 + 1) : max(1, (width - artCols) / 2 + 1)
        let block = showArt ? (side ? artRows : artRows + 1 + textHeight) : textHeight
        let artTop = top + max(0, (available - block) / 2)

        // The rain falls only while music plays; paused, the cover holds still.
        let frame = player.isPlaying && !player.isWaiting ? rainFrame : nil
        let artLayout = "\(TTY.light)|\(artwork.key ?? "-")|\(artwork.isLoaded)|\(showArt)|\(artRows)|\(artCol)|\(artTop)|\(rows)x\(width)"
        let key = artLayout + "|\(frame ?? 0)"
        if key != drawnArt {
            // A new layout clears the screen; a new frame just writes over the cover.
            if drawnArt?.hasPrefix(artLayout + "|") != true {
                for row in top...max(top, layout.bottom) { out += TTY.move(row: row) + TTY.clearLine }
            }
            drawnArt = key
            if showArt {
                if let lines = artwork.lines(cols: artCols, rows: artRows, frame: frame) {
                    for (i, line) in lines.enumerated() { out += TTY.move(row: artTop + i, col: artCol) + line }
                } else {
                    // Not fetched yet, or no cover: a frame with a note in it.
                    let inner = max(0, artCols - 2)
                    for i in 0..<artRows {
                        let line: String
                        if i == 0 {
                            line = "╭" + String(repeating: "─", count: inner) + "╮"
                        } else if i == artRows - 1 {
                            line = "╰" + String(repeating: "─", count: inner) + "╯"
                        } else if i == artRows / 2 {
                            let left = (inner - 1) / 2
                            line = "│" + String(repeating: " ", count: left) + "♪" + String(repeating: " ", count: inner - left - 1) + "│"
                        } else {
                            line = "│" + String(repeating: " ", count: inner) + "│"
                        }
                        out += TTY.move(row: artTop + i, col: artCol) + TTY.dim + line + TTY.reset
                    }
                }
            }
        }

        guard let track else {
            let text = "Nothing playing"
            out += TTY.move(row: top + available / 2, col: max(1, (width - text.columns) / 2 + 1)) + TTY.dim + text + TTY.reset
            return
        }

        // The words: centred under the cover, or left-aligned beside it.
        let textCol = side && showArt ? artCol + artCols + 4 : 1
        let textWidth = side && showArt ? max(10, width - textCol - 1) : max(10, width - 4)
        let textTop = side && showArt ? top + max(0, (available - textHeight) / 2)
            : showArt ? artTop + artRows + 1 : artTop
        let spin = ["◐", "◓", "◑", "◒"][spinner % 4]
        let icon = player.isWaiting ? spin : player.isPlaying ? "▶" : "⏸"
        let elapsed = formatTime(player.time), total = formatTime(player.duration)
        let barSpace = side && showArt ? min(textWidth, 64) : min(textWidth, max(artCols, 44))
        let bar = progressBar(width: max(4, barSpace - elapsed.count - total.count - 4))
        let upcoming = player.index.flatMap { $0 + 1 < player.tracks.count ? player.tracks[$0 + 1] : nil }
        let sub = [track.grandparentTitle, track.parentTitle].compactMap { $0 }.joined(separator: " · ")
        // (styled text, its width in columns)
        func plain(_ text: String, _ style: String) -> (String, Int) {
            let fit = text.fitted(textWidth)
            return (style + fit + TTY.reset, fit.columns)
        }
        let progressPlain = 2 + elapsed.count + 1 + max(4, barSpace - elapsed.count - total.count - 4) + 1 + total.count
        var lines: [(String, Int)] = [
            plain(track.title ?? "Untitled", TTY.bold),
            plain(sub, TTY.dim),
            ("", 0),
            ("\(TTY.accent)\(icon)\(TTY.reset) \(elapsed) \(bar) \(total)", progressPlain),
            plain(player.quality(of: track), TTY.dim),
            upcoming.map { next in
                plain("Next: " + (next.title ?? "Untitled") + (next.grandparentTitle.map { " · \($0)" } ?? ""), TTY.dim)
            } ?? ("", 0)
        ]
        if compact { lines = [lines[0], lines[1], lines[3]] }
        for (i, line) in lines.enumerated() {
            let row = textTop + i
            guard row <= layout.bottom else { break }
            if side && showArt {
                out += TTY.move(row: row, col: textCol) + "\u{1B}[K" + line.0
            } else {
                out += TTY.move(row: row) + TTY.clearLine
                    + TTY.move(row: row, col: max(1, (width - line.1) / 2 + 1)) + line.0
            }
        }
    }
}
