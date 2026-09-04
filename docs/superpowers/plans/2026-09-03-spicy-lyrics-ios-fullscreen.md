# Implementation Plan: Desktop Spicy Lyrics Full-Screen on iOS

1. Extend SLObjPack values with safe Foundation/JSON conversion and add a
   renderer-payload cache/fetch API to `SpicyLyricsRepository`.
2. Add a player-state hub fed by Spotify's existing player observer; expose
   observed position/duration/play state and dynamically resolved transport
   commands.
3. Add `SpicyLyricsFullscreenHost` and its guarded lifecycle hook for Spotify
   9.1.76, including resource loading, bridge validation, and native fallback.
4. Add the local renderer assets: responsive full-screen shell, canvas artwork
   background, karaoke normalization/animation, scroll behavior, controls,
   accessibility, loading/error/static states, and reduced-motion handling.
5. Add fixture-driven browser tests and screenshot QA at iPhone portrait and
   landscape dimensions.
6. Build on the fork's macOS workflow, inspect the resulting `.deb`, and merge
   the freshly built dylib/bundle into the exact known-working 9.1.76 IPA shell.
7. Validate the final archive structure, Mach-O load commands, embedded renderer
   files, and hashes; then provide one Sideloadly-ready IPA for device testing.
