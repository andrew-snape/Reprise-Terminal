# Reprise Terminal: plan

In order. Each step ships on its own.

## Done (Nov 2026)

- **Ask** (`:`): natural-language play with Apple Intelligence, keyword search without it.
- **Slow start on big lossless files**: whole-file download and swap.
- **Playlists page** (`P`), **radio** (`r`), **queue editing** (`+` next, `=` end, `x` remove
  on the queue page), **saved queue** on launch, **Now Playing and media keys**,
  **loudness levelling** (`L`).

## Next

- Verify in a real terminal: Now Playing from a bare CLI, the slow-start swap, levelling.
- Ask: artist plus genre or mood ("mellow radiohead"), "more like this" from the playing
  track, and remembering the last few requests (up arrow in the prompt).
- Playlists come back twice when the account has two music libraries: show the section.
- Artwork in Now Playing (Plex photo transcode, small).

## Decided

- `avFoundationPlays` and the direct-play URL building stay copied here, not moved into
  RivuletCore (Nov 2026). Keep them in step with `MacPlexSession+Music.swift` by hand.
