# Reprise Terminal

Your Plex music library, played in a terminal window.

A full-screen, keyboard-driven player for macOS: browse your music library by artist, album
and track, or just ask for what you want, and play it, gaplessly and in its original quality,
without leaving the terminal. The Now Playing screen draws the album cover as falling
Matrix-style text in the cover's own colours.
It is the terminal sibling of [Reprise for Mac](https://github.com/andrew-snape/Reprise-Mac)
and shares its Plex code.

![Now Playing: the album cover as Matrix-style text in its own colours](docs/now-playing.png)

![Browsing the library, with the now-playing bar](docs/browse.png)

## Requirements

- An Apple silicon Mac running macOS 27 or later
- Swift 6.2 or later (comes with Xcode)
- A Plex Media Server with a music library

## Install

```sh
git clone https://github.com/andrew-snape/Reprise-Terminal.git
cd Reprise-Terminal
scripts/install.sh        # builds a release build and links ~/.local/bin/reprise
reprise
```

Or build it yourself with `swift build -c release` and run `.build/release/reprise`.

## First run

Reprise shows a four-letter code. Go to **plex.tv/link**, enter it, and Reprise signs in.
If your account has more than one server, it asks which one to use. It remembers both.

```
reprise              browse and play
reprise --server     choose a different server
reprise --sign-out   forget this Mac's Plex sign-in
```

## Keys

| Key | Action |
|---|---|
| ↑ ↓ or j k | Move |
| ⏎, → or l | Open, or play from this track |
| ←, esc or h | Back |
| / | Filter the list as you type (⏎ opens the selection, esc clears) |
| : | Ask: "play ghosteen", "some mellow 90s rock", "queue ok computer" |
| a / s | Play / shuffle the selection, or the track list showing |
| r | Radio: similar music from the selection (or what's playing) |
| + / = | Play the selection next / add it to the end of the queue |
| x | Remove from the queue (on the queue page) |
| space | Pause or resume |
| n / p | Next / previous track (p restarts the track after 3 s) |
| , / . | Seek back / forward 10 s |
| v | Now Playing screen, with the album cover |
| tab | Show the queue |
| P | Playlists |
| L | Loudness levelling on or off |
| PgUp PgDn, g G | Page, jump to top or bottom |
| q | Quit (music stops) |

## How it plays

- Files AVFoundation can open (MP3, AAC, ALAC, FLAC, WAV, AIFF) play as the original file.
  Anything else (Opus, Vorbis, WMA, DSD), and every track over a Plex relay connection,
  plays as a 320 kbps AAC transcode. The bottom bar shows which.
- An album plays gaplessly.
- Ask uses Apple Intelligence on the Mac to understand the request, and Plex to find the
  music; without Apple Intelligence it is a keyword search. Nothing leaves the Mac but the
  search itself, sent to your Plex server.
- Loudness levelling uses Plex's own loudness analysis, so quiet and loud albums sit
  together. It only ever turns music down.
- The queue is saved when you quit and comes back, paused, next time.
- The playing track shows in Control Centre, and the keyboard's media keys work.
- Plex hears what you play, so play counts and history work the same as in other Plex apps.

## Privacy and your sign-in

- Your Plex token is saved in `~/Library/Application Support/reprise-cli/config.json`,
  readable only by you. `reprise --sign-out` deletes it.
- Reprise Terminal never reads or writes the Keychain. If macOS ever asks whether
  "reprise" may use the `com.rivulet.plex` keychain item (Reprise for Mac's), click **Deny**.
- Nothing is sent anywhere except your Plex server and plex.tv.

## If it ever gets stuck

Close the tab, or run `pkill -9 reprise` from another tab, then `reset` to restore the terminal.

## Licence

PolyForm Noncommercial 1.0.0. See [LICENSE](LICENSE). The Plex code in
`Sources/reprise/RivuletCore` comes from Reprise for Mac, a port of Rivulet by Bain Gurley.
