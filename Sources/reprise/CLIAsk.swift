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
    /// Said instead of "nothing found" when there is nothing to act on.
    var note: String?
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

    /// `playing` is the current track, for requests about it ("more like this").
    static func run(_ text: String, session: LanguageModelSession?, connection: CLIConnection,
                    section: String, playing: PlexMetadata? = nil) async throws -> AskResult {
        let text = text.trimmingCharacters(in: .whitespaces)
        // Read here, not by the model: it works without Apple Intelligence, and a
        // title such as "This Is Acting" is never taken for the playing track.
        if let reference = PlayingReference(text) {
            return try await aboutPlaying(reference, playing: playing, connection: connection, section: section)
        }
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
        // A mood or genre the model also took for a title, with an artist named: "sad
        // nick cave songs" (song "sad") is a mood, "play happy by pharrell" a song. Said
        // of songs in general it is the mood; otherwise the title is tried first.
        var asMood: PlayRequest?
        if request.artist.nonBlank != nil {
            let tags = request.moods + request.genres
            func isTag(_ name: String?) -> Bool {
                guard let name = name.nonBlank else { return false }
                return tags.contains { similarity($0, name) >= 0.85 }
            }
            if isTag(request.track) || isTag(request.album) {
                var mood = request
                if isTag(mood.track) { mood.track = nil }
                if isTag(mood.album) { mood.album = nil }
                if mood.track.nonBlank == nil, mood.album.nonBlank == nil { mood.kind = .artist }
                let general: Set<String> = ["songs", "tracks", "music", "stuff", "tunes"]
                if normalized(text).split(separator: " ").contains(where: { general.contains(String($0)) }) {
                    request = mood
                } else {
                    asMood = mood
                }
            }
        }

        let named = [request.artist, request.album, request.track, request.playlist].contains { !($0 ?? "").isBlank }
        if named {
            var found = try await byName(request, text: text, connection: connection, section: section)
            if found.tracks.isEmpty, let asMood {
                let mood = try await byName(asMood, text: text, connection: connection, section: section)
                if !mood.tracks.isEmpty { found = mood }
            }
            // A name split badly ("kid a" read as song "a") finds nothing at all: the plain words may.
            if found.tracks.isEmpty, found.choices.isEmpty {
                let plain = try await keywordSearch(text, action: request.action, connection: connection, section: section)
                if !plain.tracks.isEmpty || !plain.choices.isEmpty { return plain }
            }
            return found
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
            "mellow radiohead": action play, kind artist, artist "radiohead", moods ["Laid-Back/Mellow"].
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
        // An artist with a genre, mood or time ("mellow radiohead", "green day from the
        // 90s"): that artist's tracks that fit. Words of the names don't count as
        // genres or moods ("kid rock" is not rock).
        if winner.type == "artist", let key = winner.ratingKey {
            let nameWords = Set([request.artist, request.album, request.track].compactMap { $0 }
                .flatMap { normalized($0).split(separator: " ").map(String.init) })
            let rest = normalized(text).split(separator: " ").map(String.init).filter { !nameWords.contains($0) }
            var wanted = await wanted(request, text: rest.joined(separator: " "), connection: connection, section: section)
            // Only the name and command words ("play radiohead"): a mood the model
            // implied comes from what it knows of the artist, not the request.
            let command: Set<String> = ["play", "shuffle", "radio", "queue", "add", "some", "me", "my", "by",
                                        "songs", "song", "tracks", "music", "artist", "band", "please", "next"]
            if rest.allSatisfy(command.contains) { wanted.moods = []; wanted.groups = [] }
            if !wanted.isEmpty {
                let asked = wanted.parts
                let found = try await filteredTracks(&wanted, artist: key, connection: connection, section: section)
                if !found.isEmpty {
                    result.tracks = found
                    if !wanted.isEmpty { result.label += " · " + wanted.parts.joined(separator: " · ") }
                    let dropped = asked.filter { !wanted.parts.contains($0) }
                    if !dropped.isEmpty { result.label += " (none \(dropped.joined(separator: ", ")))" }
                    return try await finish(result, connection: connection)
                }
                result.label += " (none \(asked.joined(separator: ", ")))"
            } else if !wanted.unknown.isEmpty {
                result.label += " (no “\(wanted.unknown.joined(separator: ", ").lowercased())” in this library)"
            }
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

    /// The genres, moods and years a request asks for, as the library's own tags.
    private struct Wanted {
        var genres: [PlexGenre] = []
        var moods: [PlexGenre] = []
        var from: Int?
        var to: Int?
        /// Typed words the model took for a mood or genre this library doesn't have.
        var unknown: [String] = []
        /// Everyday words standing for several moods ("chill"), shown as typed.
        var groups: [(word: String, moods: [PlexGenre])] = []

        var isEmpty: Bool { genres.isEmpty && moods.isEmpty && from == nil && to == nil }

        /// For labels: "Pop/Rock · Laid-Back/Mellow · 1990–1999".
        var parts: [String] {
            let grouped = Set(groups.flatMap { $0.moods.map(\.key) })
            var parts = genres.map(\.title) + moods.filter { !grouped.contains($0.key) }.map(\.title)
                + groups.map(\.word)
            switch (from, to) {
            case let (from?, to?): parts.append(from == to ? "\(from)" : "\(from)–\(to)")
            case let (from?, nil): parts.append("From \(from)")
            case let (nil, to?): parts.append("Up to \(to)")
            case (nil, nil): break
            }
            return parts
        }
    }

    /// Genres must be named in `text` ("90s rock"); moods may be implied ("chill").
    /// Words the model made up are dropped, so the filter stays honest; a tag the
    /// model missed but the words name plainly ("mellow") is added.
    private static func wanted(_ request: PlayRequest, text: String, connection: CLIConnection,
                               section: String) async -> Wanted {
        let (genres, moods) = await libraryTags(connection: connection, section: section)
        let typedWords = Set(normalized(text).split(separator: " ").map(String.init))
        func named(_ tag: PlexGenre) -> Bool {
            tag.title.split(separator: "/").contains { typedWords.contains(normalized(String($0))) }
        }
        var wanted = Wanted()
        wanted.genres = unique(request.genres.compactMap { tag($0, in: genres) }
            .filter { genre in genre.title.split(separator: "/").contains { grounded(String($0), in: text) != nil } })
        if wanted.genres.isEmpty {
            wanted.genres = genres.values.filter(named).sorted { $0.title < $1.title }
        }
        wanted.moods = unique(request.moods.compactMap { tag($0, in: moods) })
        wanted.unknown = (request.moods.filter { tag($0, in: moods) == nil }
                          + request.genres.filter { tag($0, in: genres) == nil })
            .filter { grounded($0, in: text) != nil }
        if wanted.moods.isEmpty {
            wanted.moods = moods.values.filter(named).sorted { $0.title < $1.title }
        }
        // Everyday words that aren't the library's moods ("chill", "upbeat").
        let everyday = Set(request.moods.map { normalized($0) } + typedWords).filter { moodWords[$0] != nil }
        for word in everyday.sorted() {
            let found = unique(moodWords[word]!.compactMap { moods[$0.lowercased()] })
            guard !found.isEmpty else { continue }
            wanted.groups.append((word, found))
            wanted.moods = unique(wanted.moods + found)
            wanted.unknown.removeAll { normalized($0) == word }
        }
        // The model sometimes fills in this year unasked ("something chill": 2026).
        if mentionsTime(text) {
            wanted.from = request.fromYear
            wanted.to = request.toYear
        }
        if wanted.from == nil, wanted.to == nil, let decade = decade(in: text) {
            wanted.from = decade
            wanted.to = decade + 9
        }
        return wanted
    }

    /// Everyday words for moods, as the AllMusic moods Plex libraries carry; those a
    /// library lacks are skipped. Plex reads a list of moods as any of them.
    private static let moodWords: [String: [String]] = [
        // Track moods are sparse, so the plain ones reach their neighbours too.
        "sad": ["Sad", "Melancholy", "Somber", "Bleak", "Gloomy", "Regretful"],
        "happy": ["Happy", "Cheerful", "Joyous", "Gleeful", "Optimistic"],
        "angry": ["Angry", "Aggressive", "Hostile", "Outraged"],
        "dark": ["Dark", "Brooding", "Ominous", "Menacing"],
        "mellow": ["Laid-Back/Mellow", "Relaxed", "Calm/Peaceful"],
        "calm": ["Calm/Peaceful", "Relaxed", "Soothing"],
        "chill": ["Laid-Back/Mellow", "Relaxed", "Calm/Peaceful"],
        "chilled": ["Laid-Back/Mellow", "Relaxed", "Calm/Peaceful"],
        "relaxing": ["Relaxed", "Calm/Peaceful", "Soothing"],
        "upbeat": ["Lively", "Energetic", "Cheerful", "Bouncy"],
        "party": ["Fun", "Celebratory", "Exuberant", "Rowdy"],
        "workout": ["Energetic", "Driving", "Powerful"],
        "sleep": ["Soothing", "Calm/Peaceful", "Soft/Quiet"],
        "focus": ["Meditative", "Calm/Peaceful", "Atmospheric"],
        "moody": ["Brooding", "Melancholy"],
        "depressing": ["Melancholy", "Bleak", "Gloomy"],
        "love": ["Romantic", "Tender"],
        "loud": ["Aggressive", "Raucous", "Explosive"],
        "quiet": ["Soft/Quiet", "Gentle", "Delicate"],
    ]

    /// Random tracks that fit, loosening `wanted` until some do. Moods are the
    /// softest part of a request, so they go first, then years. For one artist
    /// (`artist`, its key) the artist is the anchor, so genres may go too.
    private static func filteredTracks(_ wanted: inout Wanted, artist: String? = nil, connection: CLIConnection,
                                       section: String) async throws -> [PlexMetadata] {
        let extra = artist.map { [URLQueryItem(name: "artist.id", value: $0)] } ?? []
        while true {
            let tracks = try await randomTracks(genres: wanted.genres, moods: wanted.moods, from: wanted.from,
                                                to: wanted.to, extra: extra, connection: connection, section: section)
            if !tracks.isEmpty { return tracks }
            let hasYears = wanted.from != nil || wanted.to != nil
            if !wanted.moods.isEmpty, artist != nil || !wanted.genres.isEmpty || hasYears {
                wanted.moods = []
                wanted.groups = []
            } else if hasYears, artist != nil || !wanted.genres.isEmpty {
                wanted.from = nil
                wanted.to = nil
            } else if !wanted.genres.isEmpty, artist != nil {
                wanted.genres = []
            } else {
                return []
            }
        }
    }

    private static func byDescription(_ request: PlayRequest, text: String, connection: CLIConnection,
                                      section: String) async throws -> AskResult? {
        var wanted = await wanted(request, text: text, connection: connection, section: section)
        guard !wanted.isEmpty else { return nil }
        let asked = wanted.parts
        let tracks = try await filteredTracks(&wanted, connection: connection, section: section)
        // Random tracks are already a shuffle; radio and play read the same here.
        let action: AskAction = request.action == .queue ? .queue : .play
        let verb = request.action == .queue ? "Queue" : "Shuffle"
        guard !tracks.isEmpty else {
            return AskResult(label: "", action: action,
                             note: "Nothing matches \(asked.joined(separator: " · ")).")
        }
        var label = "\(verb) · " + wanted.parts.joined(separator: " · ")
        let dropped = asked.filter { !wanted.parts.contains($0) }
        if !dropped.isEmpty { label += " (none \(dropped.joined(separator: ", ")))" }
        return AskResult(label: label, action: action, tracks: tracks)
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

    /// The words say something about when: a number, a decade or an era word.
    static func mentionsTime(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains(/\d\d/) || decade(in: text) != nil { return true }
        let words: Set<String> = ["recent", "new", "newer", "newest", "latest", "old", "older", "oldest", "oldies",
                                  "classic", "classics", "decade", "century", "year", "years", "era"]
        return lower.split(whereSeparator: { !$0.isLetter }).contains { words.contains(String($0)) }
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

    // MARK: - What is playing

    /// A request about the playing track: "more like this" (radio from it),
    /// "this album", "more by this artist".
    enum PlayingReference {
        case track, album(AskAction), artist(AskAction)

        init?(_ text: String) {
            let t = CLIAsk.normalized(text)
            let words = Set(t.split(separator: " ").map(String.init))
            let action: AskAction = words.contains("shuffle") ? .shuffle : words.contains("radio") ? .radio
                : words.contains("queue") || words.contains("add") ? .queue : .play
            if t.contains(/\b(this|current|playing) (album|record)\b/) {
                self = .album(action)
            } else if t.contains(/\b(this|current|playing) (artist|band|singer)\b/) {
                self = .artist(action)
            } else if t.contains(/\b(like|similar to|more of) this( (one|song|track))?$/)
                        || t.contains(/^(radio|more) (from|of) (this|current|playing)( (one|song|track))?$/)
                        || t.contains(/\b(this|current|playing) (song|track)\b/) && words.contains("radio") {
                self = .track
            } else {
                return nil
            }
        }
    }

    private static func aboutPlaying(_ reference: PlayingReference, playing: PlexMetadata?,
                                     connection: CLIConnection, section: String) async throws -> AskResult {
        guard let playing else {
            return AskResult(label: "", action: .play, note: "Nothing is playing to go on.")
        }
        switch reference {
        case .track:
            let result = AskResult(label: label(for: playing), action: .radio, tracks: [playing])
            return try await finish(result, connection: connection)
        case .album(let action):
            guard let key = playing.parentRatingKey else { break }
            var result = AskResult(label: "Album · \(playing.parentTitle ?? "Untitled")"
                                   + (playing.grandparentTitle.map { " — \($0)" } ?? ""), action: action)
            result.tracks = try await network.getChildren(serverURL: connection.serverURL,
                                                          authToken: connection.token, ratingKey: key)
            return try await finish(result, connection: connection)
        case .artist(let action):
            guard let key = playing.grandparentRatingKey else { break }
            let artist = try await network.getMetadata(serverURL: connection.serverURL,
                                                       authToken: connection.token, ratingKey: key)
            var result = AskResult(label: label(for: artist), action: action)
            result.tracks = try await tracks(of: artist, action: action, connection: connection, section: section)
            return try await finish(result, connection: connection)
        }
        return AskResult(label: "", action: .play, note: "Plex doesn't say where this song is from.")
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

// MARK: - History

/// The last few requests, oldest first, for up and down in the prompt; kept
/// between runs in `reprise-cli/asks.json` (0600).
enum AskHistory {
    private static let limit = 20
    private static var file: URL {
        URL.applicationSupportDirectory.appending(path: "reprise-cli/asks.json")
    }

    static func load() -> [String] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    /// Adds a request (moving it to the end if it was asked before) and saves.
    static func add(_ text: String, to list: inout [String]) {
        list.removeAll { $0 == text }
        list.append(text)
        if list.count > limit { list.removeFirst(list.count - limit) }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
