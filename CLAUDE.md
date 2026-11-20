# Reprise Terminal - Claude Context

`reprise` is a full-screen terminal music player for Plex, on macOS (Apple silicon, macOS 27+).
It is the terminal sibling of **Reprise for Mac** (`andrew-snape/Reprise-Mac`, locally
`~/Developer/Reprise-Mac`), a separate repo. It started there as `CLI/` (Nov 2026) and moved here.
The goal is something lightweight that looks good in a terminal: music only, in the
foreground, stopping when the window closes.

## Quick reference

- **Build**: `swift build -c release` → `.build/release/reprise`; `scripts/install.sh` also
  links `~/.local/bin/reprise`. About 25 s for a release build, a ~1.2 MB binary.
- **Language**: Swift 6 language mode, default actor isolation `MainActor`, approachable
  concurrency (`NonisolatedNonsendingByDefault`, `InferIsolatedConformances`) and
  `MemberImportVisibility`: the same settings as the Mac app, so the vendored core compiles as is.
- **One module**: `Package.swift` has a single executable target holding the CLI files *and*
  `RivuletCore`, because RivuletCore's types are internal.
- **No dependencies.** AVFoundation plays; Foundation Models (planned) is a system framework.
- **Repo is private** for now. Keep commit messages short and plain.

## Layout

```
Sources/reprise/
├── RepriseCLI.swift    # @main: flags, PlexAPI identity, keeps CLIApp alive, dispatchMain()
├── CLISignIn.swift     # CLIConfig (token file), PIN sign-in, server choice, connection ranking
├── CLIApp.swift        # pages (libraries → artists → albums → tracks, queue), keys, drawing
├── CLIPlayer.swift     # AVQueuePlayer, direct/transcode URLs, quality text, Plex reporting
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
- **The terminal is always restored**: on `q`, Ctrl-C (0x03), SIGINT and SIGTERM (dispatch
  signal sources), and before printing a fatal error. SIGWINCH redraws.
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
- **A track that fails** (`AVPlayerItem.status == .failed`) is skipped with a message,
  unless the failure is a network error (see Connections). Plex hears "stopped" if it was
  the last track.
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
- **Never print or log URLs.** File and transcode URLs carry the token. Error text goes
  through `SensitiveDataRedactor.redact`.

## Vendored RivuletCore

`Sources/reprise/RivuletCore` is a straight copy of `RivuletCore/` from Reprise-Mac at commit
`3ec87511` (version 0.79). Leave it unedited so it can be re-synced:

```sh
rsync -a --delete ~/Developer/Reprise-Mac/RivuletCore/ Sources/reprise/RivuletCore/
```

Then `swift build`. If something here needs a core change, make it in Reprise-Mac first
(RivuletCore takes values by injection, never `#if os(...)`), then sync. Most of it (Live TV,
IPTV, watchlist) is unused here; it compiles, and the binary stays small.

## Known issues and next steps

The plan is in `PLAN.md`: natural-language "ask" with Apple Intelligence first, then the
slow start on big lossless files, then smaller features.

- **Slow start on big lossless files.** An ALAC 24/96 track takes 20 to 30 s to start.
  AVPlayer's own progressive stream of a large file sits waiting. Reprise for Mac fixed the
  same thing (commit `10cd8077`, `MacMusicPlayback.playCurrentFromFile`,
  `MacMusicPrecache`): while the track waits, download the whole file (through
  `PlexCertificateDelegate.session`, no URL cache) and reload from the `file://` copy at
  the same position. Skip on relay. Also try `automaticallyWaitsToMinimizeStalling = false`.
- **Plex facts for natural-language requests**, measured on the owner's server (PMS, music
  section key 1, Nov 2026):
  - `/library/sections/{key}/genre` returns 19 genres, `/mood` 279 moods and `/style`
    266 styles. Each entry is `{key, title}`, and the keys differ per library.
  - `?type=10` narrows the lists to tracks' own tags: 14 genres and 270 moods.
  - Not yet verified: the track filter syntax (`type=10&genre=<id>`, `mood=<id>`), and
    whether years need `album.year`.
  - Filter operators: `>>=` means "greater than" and `<<=` "less than", sent pre-encoded.
  - `X-Plex-Container-Size` is ignored unless `X-Plex-Container-Start` is sent with it.
  - Helpers already in RivuletCore: `getRandomTracks(filters:)`, `getPopularTracks`,
    `getSonicallySimilarTracks` (`/nearest`), `getAudioPlaylists`, `search`.
  - The Mac's model for it: `RivuletMac/Intelligence/MacSmartSearch.swift`.

## Testing

There are no automated tests. Build, then run `reprise` in a real terminal: it needs a TTY
and a Plex sign-in, so it cannot be exercised from a non-interactive shell beyond `--help`.

`TTY.swift` imports only Foundation, so the key decoder and column widths can be checked
alone: `swiftc -swift-version 5 Sources/reprise/TTY.swift main.swift`, with a `main.swift`
that feeds `TTY.decode` byte arrays (e.g. `1B 5B 31 3B 32 41`, shift-up) and prints
`fitted` / `padded` / `columns` for CJK and emoji titles.

## Design

Calm and fast: one screen, keyboard only, the icon's coral (`TTY.accent`) and pink as the
only colours, dim text for secondary information. No feature "just in case".
