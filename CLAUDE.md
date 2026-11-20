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
  `MacMusicTrust`). The connection is chosen once, at launch.
- **Direct play vs transcode**: the same codec and container gate as the Mac app
  (`avFoundationPlays`). A relay connection always transcodes (AAC 320 over HLS, a fresh
  session id per track for the transcoder).
- **Plex reporting**: one `X-Plex-Session-Identifier` for the whole run, on every file URL and
  timeline report. Timeline every 10 s and on every change. A track that plays out is
  scrobbled (`markWatched`). "stopped" is sent only when the queue runs out or on quit (waits
  up to 2 s). A new id per track, or a "stopped" mid-queue, makes Plex end the session whose
  file is still being read (-1005 / 503), and AVPlayer waits 29 s to retry.
- **A track that fails** (`AVPlayerItem.status == .failed`) is skipped with a message.
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

1. **Slow start on big lossless files.** An ALAC 24/96 track takes 20 to 30 s to start.
   AVPlayer's own progressive stream of a large file sits waiting. Reprise for Mac fixed the same
   thing (commit `10cd8077`, `MacMusicPlayback.playCurrentFromFile`, `MacMusicPrecache`). While
   the playing track is starting or stalled, download the whole file (through
   `PlexCertificateDelegate.session`, no URL cache), then reload the track from the `file://`
   copy at the same position. Plan here: in `CLIPlayer.tick()`, if the current direct-play item
   has been waiting for more than ~1.5 s, start the download into a temp folder; when it lands
   and the track is still waiting, insert a file item after the current one, advance, and seek.
   Clear the temp folder on launch and quit. Skip on relay. Also try
   `automaticallyWaitsToMinimizeStalling = false` and dropping `preferredForwardBufferDuration`.
2. **Natural-language requests with Apple Intelligence** ("play something mellow from the
   90s", "shuffle Radiohead"). Model it on the Mac app's `MacSmartSearch`
   (`RivuletMac/Intelligence/MacSmartSearch.swift`):
   - The on-device model (`SystemLanguageModel.default`, check `availability` and
     `supportsLocale()`) reads the request into a `@Generable` struct. It never picks tracks
     itself; Plex finds them through library filters. Use a fresh `LanguageModelSession` per
     request, since the context window is small.
   - Drop any genre, mood or style the model invents: match its answers against the library's own lists.
   - A key like `:` would open an "ask" prompt in the bottom line.
   - Measured on the owner's server (PMS, music section key 1, Nov 2026):
     - `/library/sections/{key}/genre` returns 19 genres, `/mood` 279 moods and `/style` 266 styles.
     - Each entry is `{key, title}`, and the keys differ per library.
     - Adding `?type=10` narrows the lists to tracks' own tags: 14 genres and 270 moods.
   - Not yet verified: the track filter syntax (`type=10&genre=<id>`, `mood=<id>`, and
     whether years need `album.year`).
   - Helpers already in RivuletCore: `getRandomTracks(filters:)`, `getPopularTracks`,
     `getSonicallySimilarTracks` (`/nearest`) and `getAudioPlaylists`.
   - Library filter operators: `>>=` means "greater than" and `<<=` "less than", sent
     pre-encoded. `X-Plex-Container-Size` is ignored unless `X-Plex-Container-Start` is sent
     with it.
3. Ideas, not commitments: playlists page, artist radio (`/nearest`), media keys and Now
   Playing (Control Centre), loudness levelling (Plex `gain` / `albumGain`, RivuletCore's
   `LoudnessLevelling`).

## Testing

There are no automated tests. Build, then run `reprise` in a real terminal: it needs a TTY
and a Plex sign-in, so it cannot be exercised from a non-interactive shell beyond `--help`.

## Design

Calm and fast: one screen, keyboard only, the icon's coral (`TTY.accent`) and pink as the
only colours, dim text for secondary information. No feature "just in case".
