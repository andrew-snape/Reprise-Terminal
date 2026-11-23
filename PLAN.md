# Reprise Terminal: plan

In order. Each step ships on its own.

## Done (Nov 2026)

- **Ask** (`:`): natural-language play with Apple Intelligence, keyword search without it.
- **Slow start on big lossless files**: whole-file download and swap.
- **Playlists page** (`P`), **radio** (`r`), **queue editing** (`+` next, `=` end, `x` remove
  on the queue page), **saved queue** on launch, **Now Playing and media keys**,
  **loudness levelling** (`L`).
- **Now Playing screen** (`v`) with the cover as Matrix-style text in its own colours, and rain; the cover in Control Centre.
- **Skips fixed**: AVPlayer holds two items, `n` advances onto the queued one, a refused
  file is retried quietly before "Lost <server>".

- **Terminal modes**: synchronized output, bracketed paste into the prompts, light
  backgrounds (OSC 11, asked again on focus in).
- **Ask, more**: artist plus genre, mood or years ("mellow radiohead"); "more like this",
  "this album", "this artist" from the playing track; request history (↑ ↓, kept between
  runs); `reprise <request>` starts the app playing it; everyday mood words ("chill",
  "upbeat"). Radio or an album from the playing track keeps it playing (tested Nov 2026).
- **Next album** (`A`): when a whole album reaches its last track, the artist's next album
  by release date is queued.
- **Cache**: 4 GB of whole files, the next two tracks read ahead; a restored queue's track
  downloads while paused (heard: space starts at once, 24 Nov 2026).
- **Updates**: `reprise update` and a daily notice from GitHub releases;
  `scripts/release.sh` bumps, tags and publishes. 0.1.4 → 0.1.5 updated itself (24 Nov 2026).

## Next

- **Cache**: check in a real queue that downloads beside AVPlayer cause no refusals or
  stalls, the follow-on swap is gapless, and relay plays cached originals.

- Verify in a real terminal: Now Playing from a bare CLI, the slow-start swap, levelling.
- Ask: "recent" and "classic" don't become years yet; artists split across names
  ("Nick Cave" and "Nick Cave & the Bad Seeds") are searched as one only by luck.
- Playlists come back twice when the account has two music libraries: show the section.

## Decided

- `avFoundationPlays` and the direct-play URL building stay copied here, not moved into
  RivuletCore (Nov 2026). Keep them in step with `MacPlexSession+Music.swift` by hand.
