// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLIAsk.swift
//  reprise (terminal)
//
//  "Ask": a typed request ("green day album saviours", "shuffle something
//  mellow from the 90s") becomes music to play. The on-device model only
//  reads the request into a form; Plex finds the music, either by name
//  (fuzzy hub search, then a fuzzy match here) or by the library's own genre,
//  mood and year filters. Without Apple Intelligence it is a keyword search.
//  Modelled on Reprise for Mac's MacSmartSearch.
//

import Foundation
import FoundationModels

// MARK: - What the model reads

@Generable
nonisolated struct PlayRequest {
    @Guide(description: "shuffle for shuffle or random, radio for radio or music like or similar to something, queue for add, queue or play next, otherwise play")
    var action: AskAction

    @Guide(description: "What the request names most specifically: an artist, album, track or playlist, or anything when it only describes music")
    var kind: AskKind

    @Guide(description: "The artist's name exactly as written, or nil")
    var artist: String?

    @Guide(description: "The album's name exactly as written, or nil")
    var album: String?

    @Guide(description: "The song's name exactly as written, or nil")
    var track: String?

    @Guide(description: "The playlist's name exactly as written, or nil")
    var playlist: String?

    @Guide(description: "Genres asked for or clearly implied, only from the genre list. Empty if none.")
    var genres: [String]

    @Guide(description: "Moods asked for or clearly implied, only from the mood list. Empty if none.")
    var moods: [String]

    @Guide(description: "Earliest year, only if a year, decade or era is mentioned")
    var fromYear: Int?

    @Guide(description: "Latest year, only if a year, decade or era is mentioned")
    var toYear: Int?
}

@Generable
nonisolated enum AskAction {
    case play, shuffle, radio, queue
}

@Generable
nonisolated enum AskKind {
    case artist, album, track, playlist, anything
}

// MARK: - What comes back

struct AskResult {
    /// How the request was read, shown so a match is never a mystery.
    var label: String
    var action: AskAction
    /// Music to act on straight away.
    var tracks: [PlexMetadata] = []
    /// Candidates to pick from when nothing clearly won.
    var choices: [PlexMetadata] = []
}

// MARK: - Ask

enum CLIAsk {
    private static let network = PlexNetworkManager.shared
    /// How the model read the last request, for `--ask`.
    private(set) static var lastRequest: PlayRequest?

    /// Apple Intelligence is on, the model is ready, and it reads this language.
    static var isAvailable: Bool {
        let model = SystemLanguageModel.default
        return model.isAvailable && model.supportsLocale()
    }

    /// The library's track genres and moods, by lowercased title, fetched once per run.
    private static var tags: (section: String, genres: [String: PlexGenre], moods: [String: PlexGenre])?

    /// A session for one request, made (and warmed up) when the prompt opens.
    static func session(connection: CLIConnection, section: String) async -> LanguageModelSession? {
        guard isAvailable else { return nil }
        let (genres, moods) = await libraryTags(connection: connection, section: section)
        let session = LanguageModelSession(instructions: instructions(
            genres: genres.values.map(\.title).sorted(), moods: moods.values.map(\.title).sorted()))
        session.prewarm()
        return session
    }

    static func run(_ text: String, session: LanguageModelSession?, connection: CLIConnection,
                    section: String) async throws -> AskResult {
        let text = text.trimmingCharacters(in: .whitespaces)
        var request: PlayRequest?
        if let session {
            request = try? await session.respond(
                to: text, generating: PlayRequest.self,
                options: GenerationOptions(samplingMode: .greedy)).content
        }
        lastRequest = request
        guard var request else { return try await keywordSearch(text, action: nil, connection: connection, section: section) }
        // The small model fills gaps with names it knows ("Queen" for "bohemian rhapsody")
        // or placeholders ("No artist specified"): keep only names that were typed.
        request.artist = grounded(request.artist, in: text)
        request.album = grounded(request.album, in: text)
        request.track = grounded(request.track, in: text)
        request.playlist = grounded(request.playlist, in: text)

        let named = [request.artist, request.album, request.track, request.playlist].contains { !($0 ?? "").isBlank }
        if named {
            return try await byName(request, text: text, connection: connection, section: section)
        }
        if let result = try await byDescription(request, text: text, connection: connection, section: section) {
            return result
        }
        return try await keywordSearch(text, action: request.action, connection: connection, section: section)
    }

    private static func instructions(genres: [String], moods: [String]) -> String {
        let year = Calendar.current.component(.year, from: .now)
        return """
            You read a request to play music from the listener's own library and fill in a form. \
            Copy artist, album, song and playlist names exactly as written, keeping their spelling. \
            Fill in only what the request says; leave everything else nil or empty. \
            Genres must come from this list: \(genres.joined(separator: ", ")). \
            Moods must come from this list: \(moods.joined(separator: ", ")). \
            The current year is \(year). Examples:
            "green day album saviours": action play, kind album, artist "green day", album "saviours".
            "shuffle radiohead": action shuffle, kind artist, artist "radiohead".
            "play bohemian rhapsody": action play, kind track, track "bohemian rhapsody".
            "something mellow from the 90s": action play, kind anything, moods ["Laid-Back/Mellow"], fromYear 1990, toYear 1999.
            "90s rock": action play, kind anything, genres ["Pop/Rock"], fromYear 1990, toYear 1999.
            "queue my road trip playlist": action queue, kind playlist, playlist "road trip".
            "radio like ok computer": action radio, kind album, album "ok computer".
            """
    }

    // MARK: - By name

    private static func byName(_ request: PlayRequest, text: String, connection: CLIConnection,
                               section: String) async throws -> AskResult {
        let artist = request.artist.nonBlank
        var result = AskResult(label: "", action: request.action)

        if let name = request.playlist.nonBlank {
            let playlists = try await network.getAudioPlaylists(serverURL: connection.serverURL, authToken: connection.token)
            let ranked = rank(playlists, title: name, artist: nil)
            result.label = "Playlist · “\(name)”"
            if let winner = winner(ranked), let key = winner.ratingKey {
                result.label = "Playlist · \(winner.title ?? name)"
                result.tracks = try await network.getPlaylistItems(serverURL: connection.serverURL,
                                                                   authToken: connection.token, ratingKey: key)
                return try await finish(result, connection: connection)
            }
            // Not a playlist after all ("queue kid a"): look for it as anything else.
            if request.album.nonBlank == nil, request.track.nonBlank == nil, request.artist.nonBlank == nil {
                var other = request
                other.playlist = nil
                other.album = name
                other.kind = .anything
                let found = try await byName(other, text: text, connection: connection, section: section)
                if !found.tracks.isEmpty { return found }
            }
            result.choices = ranked.prefix(12).map(\.item)
            return result
        }

        // The most specific name asked for; an album or song may be either, so both are looked for.
        let title = request.album.nonBlank ?? request.track.nonBlank
        let types: Set<String>
        switch request.kind {
        case .album: types = ["album"]
        case .track: types = ["track"]
        case .artist where title == nil: types = ["artist"]
        case .anything where title != nil && artist == nil: types = ["artist", "album", "track"]
        default: types = title == nil ? ["artist"] : ["album", "track"]
        }

        var candidates: [String: PlexMetadata] = [:]
        let queries = [[artist, title].compactMap { $0 }.joined(separator: " "), title, artist]
            .compactMap { $0 }.filter { !$0.isBlank }
        for query in Set(queries) {
            for item in try await hubSearch(query, connection: connection, section: section) {
                if let key = item.ratingKey { candidates[key] = item }
            }
        }
        // Hub search can miss an album it would find by browsing: add the artist's own albums.
        if let artist, types.contains("album") || types.contains("track"),
           let found = winner(rank(candidates.values.filter { $0.type == "artist" }, title: artist, artist: nil)),
           let key = found.ratingKey {
            let albums = try await network.getChildren(serverURL: connection.serverURL, authToken: connection.token,
                                                       ratingKey: key)
            for album in albums { if let k = album.ratingKey { candidates[k] = album } }
        }

        let pool = candidates.values.filter { types.contains($0.type ?? "") }
        let ranked = rank(pool, title: title ?? artist ?? text, artist: title == nil ? nil : artist)
        let kindName = types == ["artist"] ? "Artist" : types == ["album"] ? "Album" : types == ["track"] ? "Song" : "Music"
        result.label = "\(kindName) · " + ([title.map { "“\($0)”" }, artist].compactMap { $0 }.joined(separator: " — "))

        guard let winner = winner(ranked) else {
            result.choices = ranked.prefix(12).map(\.item)
            return result
        }
        result.label = "\(label(for: winner))"
        // An artist and a time ("green day from the 90s"): that artist's tracks from then.
        let years = request.fromYear != nil || request.toYear != nil ? (request.fromYear, request.toYear)
            : decade(in: text).map { (Optional($0), Optional($0 + 9)) } ?? (nil, nil)
        if winner.type == "artist", years.0 != nil || years.1 != nil, let key = winner.ratingKey {
            result.tracks = try await randomTracks(genres: [], moods: [], from: years.0, to: years.1,
                                                   extra: [URLQueryItem(name: "artist.id", value: key)],
                                                   connection: connection, section: section)
            result.label += " · " + [years.0.map(String.init), years.1.map(String.init)].compactMap { $0 }.joined(separator: "–")
            return try await finish(result, connection: connection)
        }
        result.tracks = try await tracks(of: winner, action: request.action, connection: connection, section: section)
        return try await finish(result, connection: connection)
    }

    /// What to play for an item that was picked or matched.
    static func tracks(of item: PlexMetadata, action: AskAction, connection: CLIConnection,
                       section: String) async throws -> [PlexMetadata] {
        guard let key = item.ratingKey else { return [] }
        switch item.type {
        case "artist":
            switch action {
            case .shuffle, .radio:
                return try await network.getRandomTracks(serverURL: connection.serverURL, authToken: connection.token,
                                                         sectionId: section,
                                                         filters: [URLQueryItem(name: "artist.id", value: key)], count: 100)
            case .play, .queue:
                // The same song from several albums (a hit and its live and best-of copies) plays once.
                var seen = Set<String>()
                return try await network.getPopularTracks(serverURL: connection.serverURL, authToken: connection.token,
                                                          sectionId: section, artistKey: key, count: 80)
                    .filter { seen.insert(normalized($0.title ?? "")).inserted }
            }
        case "album":
            return try await network.getChildren(serverURL: connection.serverURL, authToken: connection.token, ratingKey: key)
        case "playlist":
            return try await network.getPlaylistItems(serverURL: connection.serverURL, authToken: connection.token,
                                                      ratingKey: key)
        case "track":
            return [item]
        default:
            return []
        }
    }

    /// Shuffle and radio applied to what was found.
    static func finish(_ result: AskResult, connection: CLIConnection) async throws -> AskResult {
        var result = result
        guard !result.tracks.isEmpty else { return result }
        switch result.action {
        case .shuffle:
            result.tracks.shuffle()
        case .radio:
            let seed = result.tracks.randomElement()!
            if let key = seed.ratingKey {
                let similar = (try? await network.getSonicallySimilarTracks(
                    serverURL: connection.serverURL, authToken: connection.token, ratingKey: key)) ?? []
                result.tracks = [seed] + similar.filter { $0.ratingKey != key }.shuffled()
            }
            result.label = "Radio · " + result.label
        case .play, .queue:
            break
        }
        return result
    }

    static func label(for item: PlexMetadata) -> String {
        let title = item.title ?? "Untitled"
        switch item.type {
        case "artist": return "Artist · \(title)"
        case "album": return "Album · \(title)" + (item.parentTitle.map { " — \($0)" } ?? "")
        case "track": return "Song · \(title)" + (item.grandparentTitle.map { " — \($0)" } ?? "")
        case "playlist": return "Playlist · \(title)"
        default: return title
        }
    }

    // MARK: - By description

    private static func byDescription(_ request: PlayRequest, text: String, connection: CLIConnection,
                                      section: String) async throws -> AskResult? {
        let (genres, moods) = await libraryTags(connection: connection, section: section)
        let typedWords = Set(normalized(text).split(separator: " ").map(String.init))
        // Genres must also be named in the request ("90s rock"); moods may be implied
        // ("chill"). Words the model made up are dropped, so the filter stays honest.
        var wantedGenres = unique(request.genres.compactMap { tag($0, in: genres) }
            .filter { genre in genre.title.split(separator: "/").contains { grounded(String($0), in: text) != nil } })
        if wantedGenres.isEmpty {
            // What the model missed but the words say plainly: a genre's own name.
            wantedGenres = genres.values.filter { genre in
                genre.title.split(separator: "/").contains { typedWords.contains(normalized(String($0))) }
            }.sorted { $0.title < $1.title }
        }
        var wantedMoods = unique(request.moods.compactMap { tag($0, in: moods) })
        var fromYear = request.fromYear, toYear = request.toYear
        if fromYear == nil, toYear == nil, let decade = decade(in: text) {
            fromYear = decade
            toYear = decade + 9
        }
        guard !wantedGenres.isEmpty || !wantedMoods.isEmpty || fromYear != nil || toYear != nil else { return nil }

        // Moods are the softest part of a request: dropped first when nothing matches, then years.
        var tracks: [PlexMetadata] = []
        while true {
            tracks = try await randomTracks(genres: wantedGenres, moods: wantedMoods, from: fromYear, to: toYear,
                                            connection: connection, section: section)
            if !tracks.isEmpty { break }
            if !wantedMoods.isEmpty, !(wantedGenres.isEmpty && fromYear == nil && toYear == nil) {
                wantedMoods = []
            } else if fromYear != nil || toYear != nil, !wantedGenres.isEmpty {
                fromYear = nil
                toYear = nil
            } else {
                break
            }
        }

        var parts = wantedGenres.map(\.title) + wantedMoods.map(\.title)
        switch (fromYear, toYear) {
        case let (from?, to?): parts.append(from == to ? "\(from)" : "\(from)–\(to)")
        case let (from?, nil): parts.append("From \(from)")
        case let (nil, to?): parts.append("Up to \(to)")
        case (nil, nil): break
        }
        // Random tracks are already a shuffle; radio and play read the same here.
        let action: AskAction = request.action == .queue ? .queue : .play
        let verb = request.action == .queue ? "Queue" : "Shuffle"
        let label = "\(verb) · " + parts.joined(separator: " · ")
        return AskResult(label: tracks.isEmpty ? label + ": nothing matches" : label, action: action, tracks: tracks)
    }

    private static func randomTracks(genres: [PlexGenre], moods: [PlexGenre], from: Int?, to: Int?,
                                     extra: [URLQueryItem] = [],
                                     connection: CLIConnection, section: String) async throws -> [PlexMetadata] {
        var filters = extra
        if !genres.isEmpty { filters.append(URLQueryItem(name: "genre", value: genres.map(\.key).joined(separator: ","))) }
        if !moods.isEmpty { filters.append(URLQueryItem(name: "mood", value: moods.map(\.key).joined(separator: ","))) }
        // `>>=` is "greater than" and `<<=` "less than"; tracks take the album's year.
        if let from { filters.append(URLQueryItem(name: "album.year>>", value: "\(from - 1)")) }
        if let to { filters.append(URLQueryItem(name: "album.year<<", value: "\(to + 1)")) }
        return try await network.getRandomTracks(serverURL: connection.serverURL, authToken: connection.token,
                                                 sectionId: section, filters: filters, count: 100)
    }

    /// "90s", "1990s", "the eighties" → 1990 / 1980. Two-digit decades read as 1900s
    /// from 30 up, else 2000s ("00s", "10s", "20s").
    static func decade(in text: String) -> Int? {
        let lower = text.lowercased()
        let names = ["twenties": 1920, "thirties": 1930, "forties": 1940, "fifties": 1950, "sixties": 1960,
                     "seventies": 1970, "eighties": 1980, "nineties": 1990]
        for (name, year) in names where lower.contains(name) { return year }
        guard let match = lower.firstMatch(of: /\b(19|20)?(\d)0'?s\b/) else { return nil }
        let digit = Int(match.2)!
        if let century = match.1 { return Int(century)! * 100 + digit * 10 }
        return digit >= 3 ? 1900 + digit * 10 : 2000 + digit * 10
    }

    /// The library's tag for a word: its own title, one part of it ("Mellow" for
    /// "Laid-Back/Mellow", "Rock" for "Pop/Rock"), or a near spelling.
    private static func tag(_ word: String, in tags: [String: PlexGenre]) -> PlexGenre? {
        let key = word.lowercased()
        if let exact = tags[key] { return exact }
        if let part = tags.first(where: { $0.key.split(separator: "/").contains { $0.trimmingCharacters(in: .whitespaces) == key } }) {
            return part.value
        }
        return tags.values.max { similarity(word, $0.title) < similarity(word, $1.title) }
            .flatMap { similarity(word, $0.title) >= 0.85 ? $0 : nil }
    }

    private static func unique(_ tags: [PlexGenre]) -> [PlexGenre] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0.key).inserted }
    }

    private static func libraryTags(connection: CLIConnection,
                                    section: String) async -> ([String: PlexGenre], [String: PlexGenre]) {
        if let tags, tags.section == section { return (tags.genres, tags.moods) }
        async let genres = tagList("genre", connection: connection, section: section)
        async let moods = tagList("mood", connection: connection, section: section)
        let found = (await genres, await moods)
        tags = (section, found.0, found.1)
        return found
    }

    /// `/library/sections/{key}/{genre|mood}?type=10`: the tags tracks carry, by lowercased title.
    private static func tagList(_ kind: String, connection: CLIConnection, section: String) async -> [String: PlexGenre] {
        guard var components = URLComponents(string: "\(connection.serverURL)/library/sections/\(section)/\(kind)") else { return [:] }
        components.queryItems = [URLQueryItem(name: "type", value: "10")]
        guard let url = components.url,
              let container: PlexGenreContainer = try? await network.request(url, headers: network.plexHeaders(authToken: connection.token))
        else { return [:] }
        return Dictionary((container.MediaContainer.Directory ?? []).map { ($0.title.lowercased(), $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Keyword search

    /// Plex search on the request without its command words. A clear match is
    /// acted on; otherwise the results are offered.
    static func keywordSearch(_ text: String, action: AskAction?, connection: CLIConnection,
                              section: String) async throws -> AskResult {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let action = action ?? (words.contains("shuffle") ? .shuffle : words.contains("radio") ? .radio
            : words.contains("queue") || words.contains("add") ? .queue : .play)
        let command: Set<String> = ["play", "shuffle", "radio", "queue", "add", "album", "song", "track",
                                    "artist", "playlist", "by", "some", "me", "my", "please", "next"]
        let query = words.filter { !command.contains($0) }.joined(separator: " ")
        guard !query.isEmpty else { return AskResult(label: "Nothing to look for", action: action) }
        let items = try await hubSearch(query, connection: connection, section: section)
        let ranked = rank(items, title: query, artist: nil)
        if let winner = winner(ranked) {
            var result = AskResult(label: label(for: winner), action: action)
            result.tracks = try await tracks(of: winner, action: action, connection: connection, section: section)
            return try await finish(result, connection: connection)
        }
        return AskResult(label: "Search · “\(query)”", action: action, choices: items)
    }

    /// Plex's own search: fuzzy (it finds "Saviors" for "saviours", "Radiohead" for
    /// "radiohed"). Music from this section only, artists first.
    static func hubSearch(_ query: String, connection: CLIConnection, section: String) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(connection.serverURL)/hubs/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "sectionId", value: section),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else { return [] }
        let container: HubSearchContainer = try await network.request(url, headers: network.plexHeaders(authToken: connection.token))
        let order = ["artist", "album", "track", "playlist"]
        return (container.MediaContainer.Hub ?? [])
            .filter { order.contains($0.type ?? "") }
            .sorted { order.firstIndex(of: $0.type ?? "")! < order.firstIndex(of: $1.type ?? "")! }
            .flatMap { $0.Metadata ?? [] }
            .filter { item in item.type == "playlist" || item.librarySectionID.map { "\($0)" == section } ?? true }
    }

    private nonisolated struct HubSearchContainer: Decodable, Sendable {
        nonisolated struct Container: Decodable, Sendable { let Hub: [PlexHub]? }
        let MediaContainer: Container
    }

    // MARK: - Matching

    struct Ranked {
        let item: PlexMetadata
        let score: Double
    }

    /// Items scored against a title and (for albums and songs) an artist, best first.
    static func rank(_ items: [PlexMetadata], title: String, artist: String?) -> [Ranked] {
        items.map { item in
            let titleScore = similarity(title, item.title ?? "")
            guard let artist else { return Ranked(item: item, score: titleScore) }
            let by = item.type == "album" ? item.parentTitle : item.type == "track" ? item.grandparentTitle : item.title
            return Ranked(item: item, score: 0.65 * titleScore + 0.35 * similarity(artist, by ?? ""))
        }
        .sorted { $0.score > $1.score }
    }

    /// The clear best match, or nil when it is weak or too close to the next
    /// (two copies of the same title by the same artist count as one).
    static func winner(_ ranked: [Ranked]) -> PlexMetadata? {
        guard let top = ranked.first, top.score >= 0.75 else { return nil }
        let close = ranked.filter { top.score - $0.score < 0.08 }
        // Copies of one title by one artist (an album and its deluxe edition, a song on
        // several albums) count as one.
        if Set(close.map { identity($0.item) }).count == 1 { return top.item }
        // An album and songs of the same name: the album (it holds the song).
        let albums = close.filter { $0.item.type == "album" }
        if !albums.isEmpty, Set(albums.map { identity($0.item) }).count == 1,
           close.allSatisfy({ normalized($0.item.title ?? "") == normalized(albums[0].item.title ?? "") }) {
            return albums[0].item
        }
        return nil
    }

    private static func identity(_ item: PlexMetadata) -> String {
        let by = item.type == "album" ? item.parentTitle : item.type == "track" ? item.grandparentTitle : nil
        return [item.type ?? "", normalized(item.title ?? ""), normalized(by ?? "")].joined(separator: "|")
    }

    /// The name when every word of it was typed (allowing one slip in longer
    /// words), else nil.
    static func grounded(_ name: String?, in text: String) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let typed = normalized(text).split(separator: " ").map(Array.init)
        let words = normalized(name).split(separator: " ").map(Array.init)
        guard !words.isEmpty else { return nil }
        let allTyped = words.allSatisfy { word in
            typed.contains { $0 == word || (word.count >= 5 && editDistance($0, word) <= 1) }
        }
        return allTyped ? name : nil
    }

    /// 1 for the same words, 0.9 when one contains the other, else by edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalized(a), y = normalized(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }
        if x.contains(y) || y.contains(x) { return 0.9 }
        let distance = editDistance(Array(x), Array(y))
        return max(0, 1 - Double(distance) / Double(max(x.count, y.count)))
    }

    /// Lowercased, accents folded, bracketed extras ("(Deluxe)") and punctuation dropped, no leading "the".
    static func normalized(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = String(t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        var words = t.split(separator: " ")
        if words.first == "the", words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }
}

private extension Optional where Wrapped == String {
    /// The text, trimmed, or nil when empty.
    var nonBlank: String? {
        guard let s = self?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}
