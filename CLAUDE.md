# Reprise Terminal - Claude Context

`reprise` is a full-screen terminal music player for Plex, on macOS (Apple silicon, macOS 27+).
It is the terminal sibling of **Reprise for Mac** (`andrew-snape/Reprise-Mac`, locally
`~/Developer/Reprise-Mac`), a separate repo. It started there as `CLI/` (Nov 2026) and moved here.
The goal is something lightweight that looks good in a terminal: music only, in the
foreground, stopping when the window closes.

## Quick reference

- **Build**: `swift build -c release` → `.build/release/reprise`; `scripts/install.sh` also
  links `~/.local/bin/reprise`. About 25 s for a release build, a ~2.1 MB binary.
- **Language**: Swift 6 language mode, default actor isolation `MainActor`, approachable
  concurrency (`NonisolatedNonsendingByDefault`, `InferIsolatedConformances`) and
  `MemberImportVisibility`: the same settings as the Mac app, so the vendored core compiles as is.
- **One module**: `Package.swift` has a single executable target holding the CLI files *and*
  `RivuletCore`, because RivuletCore's types are internal.
- **No dependencies.** AVFoundation plays; Foundation Models (ask), MediaPlayer (Now Playing)
  and Network (path changes) are system frameworks.
- **Repo is private** for now. Keep commit messages short and plain.

## Layout

```
Sources/reprise/
├── RepriseCLI.swift    # @main: flags, PlexAPI identity, keeps CLIApp alive, dispatchMain()
├── CLISignIn.swift     # CLIConfig (token file), PIN sign-in, server choice, connection ranking
├── CLIApp.swift        # pages (libraries → artists → albums → tracks, playlists, queue,
│                       #   ask results), Now Playing screen, keys, drawing, reconnects
├── CLIAsk.swift        # "ask": Foundation Models reads a request, Plex finds the music
├── CLIArtwork.swift    # album cover: Plex photo transcode, Matrix-style drawing
├── CLINowPlaying.swift # Control Centre Now Playing (with cover) and media keys
├── CLIPlayer.swift     # AVQueuePlayer, direct/transcode URLs, queue editing, levelling,
│                       #   slow-start download, saved queue, quality text, Plex reporting
├── TTY.swift           # raw mode, alternate screen, signals, key decoding, ANSI styles
└── RivuletCore/        # vendored from Reprise-Mac (see below); not edited here
```

## Rules that look wrong until you know them

- **Never touch `PlexAuthManager.shared` or `KeychainHelper`.** `PlexAuthManager.init` deletes
  the `com.rivulet.plex` Keychain vault when the `plexHasPersistedSession` UserDefaults flag is
  missing. This binary has its own, empty defaults domain, so creating it once would sign
  Reprise for Mac out. Call `PlexNetworkManager` directly (`requestPin`,
  `checkPinAuthentication`, `getServers`, …). Its static helpers (`isLoopbackAddress`,
  `looksLikeDockerBridge`) are safe: they don't create `shared`.
- **The token is a 0600 file**, `~/Library/Application Support/reprise-cli/config.json`
  (`authToken`, `serverID`, `serverName`), in a 0700 folder. Not the Keychain: an unsigned
  binary gets a cdhash keychain partition, so every rebuild would prompt.
- **Its own Plex client**: `PlexAPI.clientIdentifier` is a UUID in this binary's own
  UserDefaults; `PlexAPI.platform = "macOS"`, `deviceName = "<Mac name> (Terminal)"`.
- **`CLIApp` is held by `RepriseCLI.app`.** Its input source, timer and signal handlers
  capture it weakly, and `run()` returns as soon as they are set up. Without the static it is
  freed after the first page loads: the screen freezes and even Ctrl-C does nothing (ISIG is
  off, so Ctrl-C arrives as byte 0x03 on the dead input source).
- **The terminal is always restored**: on `q`, Ctrl-C (0x03), SIGINT, SIGTERM and SIGHUP
  (dispatch signal sources), on EOF or an error reading stdin (the window closed), and before
  printing a fatal error. Every quit goes through `CLIApp.quit`, so Plex hears "stopped" and
  the queue is saved. SIGWINCH redraws.
- **Connections** (`CLISignIn.bestConnection`): every candidate is probed at once
  (`/identity`, 5 s) and the best that answers wins: local plex.direct, remote
  plex.direct, local plain HTTP (never loopback or Docker bridge), then relay. Raw-IP HTTPS is
  skipped because AVPlayer here has no certificate trust delegate (the Mac app has
  `MacMusicTrust`). `CLIPlayer` owns the connection. It is probed again (fresh addresses
  from plex.tv, `CLISignIn.reprobe`) after a network change (`NWPathMonitor`, debounced),
  a network error while browsing, or a track failing with a network error. That
  track is held, not skipped, and is retried every 10 s; if it fails the same way
  again after a reconnect, it is skipped. If a different address wins, or a
  track is waiting, the queue is rebuilt from the same track and position.
- **Direct play vs transcode**: the same codec and container gate as the Mac app
  (`avFoundationPlays`). A relay connection always transcodes (AAC 320 over HLS, a fresh
  session id per track for the transcoder). Each transcoder session is stopped when its
  item is left: it plays out, fails, is replaced by `load()`, or the player stops (as
  the Mac app's `finishMusic`). On `load()` and stop only the first two remaining entries
  are stopped, since AVQueuePlayer reads only the current and next item.
- **Plex reporting**: one `X-Plex-Session-Identifier` for the whole run, on every file URL and
  timeline report. Timeline every 10 s and on every change. A track that plays out is
  scrobbled (`markWatched`). "stopped" is sent only when the queue runs out or on quit (waits
  up to 2 s). A new id per track, or a "stopped" mid-queue, makes Plex end the session whose
  file is still being read (-1005 / 503), and AVPlayer waits 29 s to retry.
- **AVPlayer holds two items**: the playing track and the next (`topUp` queues the next as
  each starts), as the Mac app does. With the whole list loaded, one refused file made
  AVQueuePlayer run on through the rest ("started Ghosteen at Night Raid"). `n` with the
  next item queued just advances onto it: loading it afresh asks Plex for a file this
  session is already reading, which it refuses for a moment.
- **A track that fails** (`AVPlayerItem.status == .failed`) with a network error is first
  held with nothing in AVPlayer and loaded again after 1 s (`holdAndRetry`), since a
  refusal (-1008) is a URL error too; only a second network failure means "Lost <server>"
  (see Connections). Any other failure is skipped with a message. Plex hears "stopped" if
  it was the last track.
- **Timeline reports** go out at once whenever the current `AVPlayerItem` differs from the
  last one reported, so manual skips and restarts are covered. The comparison is by item,
  not index.
- **Quality text** uses the track's full metadata (`getMetadata`, fetched lazily for the
  current track only): album `/children` lists lack stream details (bit depth, rate).
- **Text is measured in terminal columns** (`String.columns`: wide CJK and emoji count
  2), and `fitted` strips control characters, since metadata is untrusted.
- **Window title** is the playing track (OSC 2). The old title is pushed on enter
  (`CSI 22;0t`) and popped on restore (`CSI 23;0t`), after an empty title for terminals
  without a title stack.
- **The main run loop runs** (`RunLoop.main.run()`, not `dispatchMain()`): MediaPlayer's
  remote commands need it. The main dispatch queue is still drained by it.
- **Ask** (`:`, `CLIAsk`): a fresh `LanguageModelSession` per request, made and prewarmed
  when the prompt opens (the Task is awaited on Enter, so a fast Enter never falls back
  to keyword search), greedy sampling. The model only fills `PlayRequest`; names it
  returns are kept only if every word was typed (`grounded`), since the small model adds
  names it knows ("Queen") and placeholders ("No artist specified"). Named requests go
  through `/hubs/search` (fuzzy: "saviours" finds "Saviors") plus the artist's own
  albums, then a local fuzzy rank; a weak or close match opens a results page, never a
  guess. Descriptive ones become `getRandomTracks` filters: genre and mood ids from the
  library's `?type=10` lists, years as `album.year>>=` / `album.year<<=` (plain `year`
  matches nothing for tracks; verified Nov 2026). Moods are dropped first, then years,
  when nothing matches. Without Apple Intelligence it is a keyword search. Try requests
  with the hidden `reprise --ask "<text>"`.
- **Saved queue**: `reprise-cli/queue.json` (rating keys, index, time, server id), written
  on track change, pause, queue edits and quit, deleted when the queue plays out; on launch
  it comes back paused (batched `/library/metadata/k1,k2,…`) but **nothing is loaded into
  AVPlayer until play is pressed** (`restoredAt`). AVPlayer reads ahead even while paused,
  and while that read is open Plex refuses a new request for the same file on this session
  (-1008, CoreMedia -16849); AVQueuePlayer then skips the item by itself, which looked like
  "starts at a different song each time".
- **A failed item AVQueuePlayer skipped by itself** (the old item's status is `.failed` when
  `tick()` sees the change) is not scrobbled: it is held and retried once after 1 s, then
  skipped with a message. Two reads of one file on the session (a slow-start download
  beside AVPlayer's range reads) both complete: tested against the server, Nov 2026.
- **Slow start**: a direct-play item waiting over 1.5 s is downloaded whole into
  `$TMPDIR/reprise-cli` and swapped in at the same position if still waiting. A copy that
  isn't used, or whose item is left, is deleted at once; the folder is also cleared on
  launch and quit. Never on relay or for a transcode.
- **Levelling** (`L` toggles, on by default): `LoudnessLevelling.volume` from the track's full
  metadata (album gain when one album plays in order), set on the player when a track starts
  (the next item's on `didPlayToEndTime`, so no loud first moment).
- **Now Playing screen** (`v`): the cover as Matrix-style text, one cell a pixel (a square
  cover is `2 × rows` cells across): half-width katakana (one column each) and digits in
  the cover's own colour per cell, lifted by brightness (contrast stretched) since thin glyphs read darker; the one place outside coral and pink (contrast stretched), dark areas empty. While music
  plays a 0.12 s timer moves drops of light (whitening the colour) down the columns and flickers a few glyphs;
  paused, it holds still and isn't redrawn. (Colour half blocks were tried first and
  looked poor.) Stacked and centred, or beside the words when the window is wide and
  short. Covers come from `/photo/:/transcode` at 600 px, one fetch per album, and also
  go to Control Centre.
- **Never print or log URLs.** File and transcode URLs carry the token. Error text goes
  through `SensitiveDataRedactor.redact`.

## Vendored RivuletCore

`Sources/reprise/RivuletCore` is a straight copy of `RivuletCore/` from Reprise-Mac at commit
`62a16f52` (version 0.80). Leave it unedited so it can be re-synced:

```sh
rsync -a --delete ~/Developer/Reprise-Mac/RivuletCore/ Sources/reprise/RivuletCore/
```

Then `swift build`. If something here needs a core change, make it in Reprise-Mac first
(RivuletCore takes values by injection, never `#if os(...)`), then sync. Most of it (Live TV,
IPTV, watchlist) is unused here; it compiles, and the binary stays small.

## Known issues and next steps

See `PLAN.md`. Unverified so far (needs a real terminal and ears): Now Playing and media keys
from a bare CLI process, the slow-start swap on a real 24/96 file, levelling.

## Testing

There are no automated tests. Build, then run `reprise` in a real terminal: it needs a TTY
and a Plex sign-in. From a non-interactive shell:

- `reprise --ask "<request>"` signs in from the saved config and prints how the request was
  read and what it found (titles only).
- A Python `pty.fork()` driver can start the app, send keys and read the frames (each draw
  starts with `ESC [?25l`); avoid keys that start playback unless sound is wanted.

`TTY.swift` imports only Foundation, so the key decoder and column widths can be checked
alone: `swiftc -swift-version 5 Sources/reprise/TTY.swift main.swift`, with a `main.swift`
that feeds `TTY.decode` byte arrays (e.g. `1B 5B 31 3B 32 41`, shift-up) and prints
`fitted` / `padded` / `columns` for CJK and emoji titles.

## Design

Calm and fast: one screen, keyboard only, the icon's coral (`TTY.accent`) and pink as the
only colours (the cover aside), dim text for secondary information. No feature "just in case".
