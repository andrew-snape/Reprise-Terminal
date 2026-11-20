# Reprise Terminal: plan

In order. Each step ships on its own.

## 1. Ask: natural-language play (Apple Intelligence)

Type `:` and then a request, for example `green day album saviours`,
`shuffle radiohead`, `something mellow from the 90s` or `play bohemian rhapsody`.
The bottom line becomes the prompt, Enter runs it, and Esc cancels.

### Step 0: spike (everything else depends on it)

- Confirm `SystemLanguageModel.default.availability == .available` from this unsigned
  SwiftPM binary (no bundle, no entitlements), and measure first-response latency.
- Add a hidden `--ask "<text>"` flag. It signs in, parses, resolves, and prints the
  request as the app read it plus the titles it found. It never prints URLs. This lets
  the whole feature be tested without a TTY.

### Reading the request

A fresh `LanguageModelSession` per request (the context window is small, about 4k
tokens), prewarmed when `:` opens. The model only reads; Plex finds the music.

```swift
@Generable struct PlayRequest {
    var action: Action          // play, shuffle, radio, addToQueue
    var target: Target          // artist, album, track, playlist, anything
    var artist: String?         // names exactly as typed
    var album: String?
    var track: String?
    var playlist: String?
    var genres: [String]        // descriptive words, matched afterwards
    var moods: [String]
    var fromYear: Int?
    var toYear: Int?
}
```

Don't put the library's 279 moods and 266 styles in the instructions. Match the model's
words against the library's own lists (`/genre`, `/mood`, `/style` with `?type=10`)
afterwards and drop anything that doesn't match, as `MacSmartSearch` does.

### Finding it: two paths

**Named** (any of artist, album, track or playlist is set). This is a lookup, not a filter.

1. Resolve the artist with Plex search, then fuzzy-match the album or track among
   `getChildren(artist)`.
2. Fuzzy means: fold case and diacritics, drop punctuation and a leading "The", and allow a
   small edit distance. The example needs it: Green Day's album is titled **"Saviors"**
   (US spelling), so `saviours` has to match.
3. Exactly one clear winner plays straight away. Otherwise a results page opens with the
   candidates. Never guess.

**Descriptive** (genres, moods, years). Use `getRandomTracks(filters:)` with the matched
genre and mood ids and the years. Still to verify (see CLAUDE.md): `type=10&genre=<id>`,
`mood=<id>`, and whether years need `album.year`.

### Always

- Show how the request was read: `▶ Album · Saviors — Green Day`, or
  `Shuffle · Rock · 1990–1999`.
- No Apple Intelligence, or the model declines: run plain keyword search and open a
  results page. That page is also useful on its own as a `/`-style search across the whole
  library, not just the page showing.
- Run keyword search alongside the model. If the search alone finds an exact
  artist and album pair, it can win before the model answers.

## 2. Slow start on big lossless files

As in CLAUDE.md (known issue 1): while a direct-play item waits more than about 1.5 s,
download the whole file and swap to the `file://` copy at the same position. This now
fits with `switchConnection`'s reload-at-position and `pendingSeek`.

## 3. Smaller features, roughly by value

- **Playlists page** (`getAudioPlaylists`), reached from the libraries page.
- **Artist and track radio** from the selection (`getSonicallySimilarTracks`, `/nearest`).
  Key `r`.
- **Queue editing**: add next / add to end from any list (`+` / `=`), and remove on the
  queue page. The player already rebuilds from an index.
- **Resume the last queue** on launch, paused, as the Mac app's `MacMusicQueueStore` does.
- **Now Playing and media keys** (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`).
  Unverified whether a bare CLI process shows in Control Centre. Spike before building.
- **Loudness levelling** (Plex `gain` / `albumGain`, RivuletCore `LoudnessLevelling`).

## Decided

- `avFoundationPlays` and the direct-play URL building stay copied here, not moved into
  RivuletCore (Nov 2026). Keep them in step with `MacPlexSession+Music.swift` by hand.
