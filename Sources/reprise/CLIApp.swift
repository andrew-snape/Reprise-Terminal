// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLIApp.swift
//  reprise (terminal)
//
//  The full-screen browser: libraries → artists → albums → tracks, a queue
//  page, and the now-playing bar. Everything runs on the main actor; the
//  screen is redrawn whole after every key and twice a second. When the
//  network changes or the server stops answering, the server is probed again
//  and playback moves to the new address.
//

import Foundation
import Network

final class CLIApp {
    private enum Kind {
        case libraries, artists, albums, tracks, queue
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

    /// The player owns the connection, so a reconnect changes it in one place.
    private var connection: CLIConnection { player.connection }

    init(connection: CLIConnection) {
        self.player = CLIPlayer(connection: connection)
    }

    // MARK: - Run

    func run() async {
        TTY.enter(onResize: { [weak self] in self?.draw() },
                  onQuit: { [weak self] in self?.quit() })
        draw()

        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                var buffer = [UInt8](repeating: 0, count: 64)
                let n = read(STDIN_FILENO, &buffer, buffer.count)
                guard n > 0 else { return }
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
                self.spinner += 1
                self.draw()
            }
        }
        timer.resume()
        self.timer = timer

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.pathChanged(online: path.status == .satisfied) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor

        await loadLibraries()
    }

    private func quit() {
        guard !quitting else { return }
        quitting = true
        Task {
            // Up to two seconds for Plex to hear "stopped".
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.player.stop() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
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

    private func load(_ work: @escaping () async throws -> Void) {
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
            if libraries.count == 1 {
                try await openLibrary(libraries[0])
            } else if libraries.isEmpty {
                flash("No music libraries on \(connection.serverName).")
            } else {
                stack = [Page(kind: .libraries, title: "Music",
                              rows: libraries.map { Row(title: $0.title, library: $0) })]
            }
        }
    }

    private func openLibrary(_ library: PlexLibrary) async throws {
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
        if filtering {
            handleFilter(key)
            return
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
        case .char("s"): playSelection(shuffled: true)
        case .char("a"): playSelection(shuffled: false)
        case .tab: toggleQueue()
        default: break
        }
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
        case .queue:
            player.play(player.tracks, from: index)
        }
    }

    /// `a` plays, `s` shuffles: the selected album, or the track list showing.
    private func playSelection(shuffled: Bool) {
        guard !loading, let (page, row, _) = selectedRow else { return }
        switch page.kind {
        case .albums:
            guard let album = row.item else { return }
            load { [self] in
                let tracks = try await children(of: album)
                player.play(shuffled ? tracks.shuffled() : tracks, from: 0)
            }
        case .tracks:
            let tracks = page.rows.compactMap(\.item)
            player.play(shuffled ? tracks.shuffled() : tracks, from: 0)
        default:
            break
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

    private var listHeight: Int { max(1, TTY.size.rows - 7) }

    private func draw() {
        guard !quitting else { return }
        let (rows, cols) = TTY.size
        let width = max(20, cols)
        var out = "\u{1B}[?25l"

        // Header: badge, breadcrumb, server.
        let badge = "\(TTY.accentBG)\(TTY.bold) ◆ REPRISE \(TTY.reset)"
        let crumbs = stack.map(\.title).joined(separator: " › ")
        let server = connection.serverName + (connection.isRelay ? " (relay)" : "")
        let crumbWidth = max(0, width - 13 - server.columns - 1)
        out += TTY.move(row: 1) + TTY.clearLine + badge + "  " + TTY.dim + crumbs.fitted(crumbWidth).padded(crumbWidth)
            + TTY.reset + " " + TTY.dim + server.fitted(max(0, width - 14)) + TTY.reset
        out += TTY.move(row: 2) + TTY.clearLine

        // List.
        let height = max(1, rows - 7)
        if var page = stack.last {
            let visible = page.visible
            if page.selected < page.top { page.top = page.selected }
            if page.selected >= page.top + height { page.top = page.selected - height + 1 }
            page.top = max(0, min(page.top, max(0, visible.count - height)))
            stack[stack.count - 1].top = page.top
            let playingKey = player.current?.ratingKey
            for line in 0..<height {
                out += TTY.move(row: 3 + line) + TTY.clearLine
                let v = page.top + line
                guard visible.indices.contains(v) else { continue }
                let row = page.rows[visible[v]]
                let isSelected = v == page.selected
                let isPlaying = playingKey != nil && row.item?.ratingKey == playingKey
                let marker = isPlaying ? "\(TTY.pink)♪\(TTY.reset)" : " "
                let detail = row.detail.fitted(max(0, width / 3))
                let detailWidth = detail.columns
                let titleWidth = max(4, width - 6 - detailWidth)
                let title = row.title.fitted(titleWidth)
                let titlePad = String(repeating: " ", count: max(0, titleWidth - title.columns))
                if isSelected {
                    out += " \(TTY.accent)❯\(TTY.reset)\(marker) \(TTY.bold)\(title)\(TTY.reset)\(titlePad) \(TTY.dim)\(detail)\(TTY.reset)"
                } else {
                    out += "  \(marker) \(title)\(TTY.reset)\(titlePad) \(TTY.dim)\(detail)\(TTY.reset)"
                }
            }
            if visible.isEmpty, !loading {
                out += TTY.move(row: 3) + "   \(TTY.dim)Nothing here\(page.filter.isEmpty ? "" : " matches “\(page.filter)”").\(TTY.reset)"
            }
        } else {
            for line in 0..<height { out += TTY.move(row: 3 + line) + TTY.clearLine }
        }

        // Now playing.
        let rule = TTY.dim + String(repeating: "─", count: width) + TTY.reset
        out += TTY.move(row: rows - 4) + TTY.clearLine + rule
        out += TTY.move(row: rows - 3) + TTY.clearLine
        out += TTY.move(row: rows - 2) + TTY.clearLine
        if let track = player.current {
            let quality = player.quality(of: track)
            let line = "\(track.title ?? "Untitled")"
            let sub = [track.grandparentTitle, track.parentTitle].compactMap { $0 }.joined(separator: " · ")
            let left = max(0, width - quality.columns - 6)
            let titleText = line.fitted(left)
            let subText = sub.isEmpty ? "" : (" — " + sub).fitted(max(0, left - titleText.columns))
            let pad = String(repeating: " ", count: max(0, left - titleText.columns - subText.columns))
            out += TTY.move(row: rows - 3) + " \(TTY.pink)♪\(TTY.reset) \(TTY.bold)\(titleText)\(TTY.reset)\(TTY.dim)\(subText)\(TTY.reset)\(pad)  \(TTY.dim)\(quality)\(TTY.reset)"

            let spin = ["◐", "◓", "◑", "◒"][spinner % 4]
            let icon = player.isWaiting ? spin : player.isPlaying ? "▶" : "⏸"
            let elapsed = formatTime(player.time), total = formatTime(player.duration)
            let barWidth = max(4, width - elapsed.count - total.count - 9)
            let fraction = player.duration > 0 ? min(1, max(0, player.time / player.duration)) : 0
            let filled = Int(Double(barWidth) * fraction)
            let bar = TTY.accent + String(repeating: "━", count: filled) + (filled < barWidth ? "╸" : "")
                + TTY.reset + TTY.dim + String(repeating: "─", count: max(0, barWidth - filled - 1)) + TTY.reset
            out += TTY.move(row: rows - 2) + " \(TTY.accent)\(icon)\(TTY.reset) \(elapsed) \(bar) \(total)"
            TTY.setTitle("\(player.isPlaying ? "♪" : "⏸") \(track.title ?? "Untitled")" + (track.grandparentTitle.map { " — \($0)" } ?? ""))
        } else {
            TTY.setTitle("Reprise")
            out += TTY.move(row: rows - 3) + "   \(TTY.dim)Nothing playing\(TTY.reset)"
        }

        // Help, filter or status.
        out += TTY.move(row: rows - 1) + TTY.clearLine
        out += TTY.move(row: rows) + TTY.clearLine
        if filtering, let page = stack.last {
            out += " \(TTY.accent)/\(TTY.reset) \(page.filter.fitted(max(1, width - 20)))\(TTY.accent)▏\(TTY.reset)  \(TTY.dim)⏎ open  esc clear\(TTY.reset)"
        } else if let status, Date() < statusUntil {
            out += " \(TTY.pink)\(status.fitted(width - 2))\(TTY.reset)"
        } else if loading {
            out += " \(TTY.accent)\(["◐", "◓", "◑", "◒"][spinner % 4])\(TTY.reset) \(TTY.dim)Loading…\(TTY.reset)"
        } else {
            let help = "⏎ open  ← back  / filter  a play  s shuffle  space pause  n/p next/prev  ,/. seek  tab queue  q quit"
            out += " " + TTY.dim + help.fitted(width - 2) + TTY.reset
        }
        TTY.write(out)
    }
}
