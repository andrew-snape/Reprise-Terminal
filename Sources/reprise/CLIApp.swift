// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLIApp.swift
//  reprise (terminal)
//
//  The full-screen browser: libraries → artists → albums → tracks, a queue
//  page, and the now-playing bar. Everything runs on the main actor; the
//  screen is redrawn whole after every key and twice a second.
//

import Foundation

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

    private let connection: CLIConnection
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

    init(connection: CLIConnection) {
        self.connection = connection
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
                if let message = self?.player.tick() { self?.flash(message) }
                self?.spinner += 1
                self?.draw()
            }
        }
        timer.resume()
        self.timer = timer

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

    // MARK: - Loading

    private func load(_ work: @escaping () async throws -> Void) {
        loading = true
        draw()
        Task {
            do { try await work() } catch { flash("Plex didn't answer: \(SensitiveDataRedactor.redact(error.localizedDescription))") }
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
        let crumbWidth = max(0, width - 12 - server.count - 3)
        out += TTY.move(row: 1) + TTY.clearLine + badge + "  " + TTY.dim + crumbs.fitted(crumbWidth).padded(crumbWidth)
            + TTY.reset + " " + TTY.dim + server + TTY.reset
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
                let detailWidth = row.detail.count
                let titleWidth = max(4, width - 6 - detailWidth)
                let title = row.title.fitted(titleWidth)
                let titlePad = String(repeating: " ", count: max(0, titleWidth - visibleLength(title)))
                if isSelected {
                    out += " \(TTY.accent)❯\(TTY.reset)\(marker) \(TTY.bold)\(title)\(TTY.reset)\(titlePad) \(TTY.dim)\(row.detail)\(TTY.reset)"
                } else {
                    out += "  \(marker) \(title)\(TTY.reset)\(titlePad) \(TTY.dim)\(row.detail)\(TTY.reset)"
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
            let left = max(0, width - quality.count - 6)
            let titleText = line.fitted(left)
            let subText = sub.isEmpty ? "" : (" — " + sub).fitted(max(0, left - titleText.count))
            let pad = String(repeating: " ", count: max(0, left - titleText.count - subText.count))
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
        } else {
            out += TTY.move(row: rows - 3) + "   \(TTY.dim)Nothing playing\(TTY.reset)"
        }

        // Help, filter or status.
        out += TTY.move(row: rows - 1) + TTY.clearLine
        out += TTY.move(row: rows) + TTY.clearLine
        if filtering, let page = stack.last {
            out += " \(TTY.accent)/\(TTY.reset) \(page.filter)\(TTY.accent)▏\(TTY.reset)  \(TTY.dim)⏎ open  esc clear\(TTY.reset)"
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

    /// Length without ANSI escape sequences.
    private func visibleLength(_ s: String) -> Int {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    }
}
