# v5.18: exact desktop gradient engine and native repairs

## Request, approval, and evidence

The September 6 follow-up reports missing local covers, muted/different gradient
motion, and filename selection dismissing the rename alert. Continue the user's
advance approval. Preserve imports, originals, playback, preferences, and lyrics;
deliver a distinct IPA. This supersedes v5.17's approximate gradient design.

The supplied MP3 was inspected locally without modification or upload. It has a
valid 1280x720 PNG front cover; missing embedded art is not its explanation. Do not
commit the audio, artwork, or its personal tags to the repository or CI.

The extracted Spotify 9.1.76 executable (SHA-256
`8ec29afac67d2a068e3b47f8fe6727c055f65472e1a96b0b9171fd29e9db05bd`)
defines `SPTLocalAVAssetImageLoaderRequest.dispatchError:` as `v24@0:8@16`
at `0x109746fd8`. v5.17 instead requires a zero-argument `dispatchError`, causing
its all-or-nothing ABI guard to reject installation. Its fixture duplicated that
incorrect signature. The success callback is confirmed to forward NSData to
`imageLoaderRequest:didLoadImageData:`. Correct the fixture from the independent
binary contract and preserve the resulting red installation failure before fixing.

The desktop source at `4576d022b39e98291d71c75b0d4d355bcc332ced` uses
`@kawarp/core` 1.2.0 (locked tarball SHA-1
`5bbec5eec4dbf3498aa9f54eec059060839525b5`, MIT). It blurs and warps the entire
artwork texture with WebGL, rather than animating sampled palette regions.
Default options: warp 1, 8 blur passes, saturation 1.5, dithering .008, no tint,
scale 1. Fullscreen CSS applies `saturate(2.5) brightness(.65)` in that order.
The playing speed without audio analysis is 1; initial speed is .1 with the
engine's own smoothing. Initial transition is 500 ms, later transitions 1000 ms.

The same desktop source optionally obtains Spotify audio analysis from its
first-party `spclient.wg.spotify.com/audio-attributes/v1/audio-analysis/{id}`
endpoint. Its section/track tempo and loudness plus confident beat pulses set
the target speed (clamped .1–3). Carry over that calculation in a bounded native
current-track provider using the already captured Spotify authorization. Never
send the token or the analysis request through WebKit. Missing, failed, local,
stale or malformed analysis uses 1. No analysis is inferred from lyrics or audio
and no user file is uploaded. Test the numerical contract and URLSession boundary
independently; the speed preference multiplies this PC target without resetting
phase. Only the current track can accept a result.

## Alternatives and selected boundaries

1. Gradient: tuning the existing palette field cannot reproduce the PC spatial
   motion. Reimplementing its shaders risks further drift. Vendor the pinned MIT
   engine, retain its algorithms unchanged, and add a thin mobile lifecycle/image
   adapter. A mechanical compatibility build for supported WebKit is allowed, with
   the upstream source, license, provenance, and reproducible transform retained.
2. Artwork: patching individual image views would bypass native request ownership.
   Correct the verified callback ABI in the isolated adapter, keep native dispatch,
   full-track/file identity, cancellation, scope limits and catalog fallthrough.
   Capture all required observed signatures so a fixture cannot silently invent one.
3. Rename: further alert callbacks cannot provide a stable long-text editing surface.
   Use a dedicated native editor inside a modal navigation controller, explicit
   Save/Cancel, a selectable multiline filename, fixed extension, and inline errors.
   No text-selection, editing-end, Return, Cut, Paste, or IME event commits a rename.
   Prevent interactive modal dismissal. Dismiss only after explicit Cancel or an
   authoritative successful save; failures preserve the same controller and draft.

## Contracts and tests (approved in advance)

- The gradient adapter accepts decoded artwork and effective motion/speed; it does
  not own player state. Default playing uses the PC rate and smoothing. Existing
  pause/hidden/inline/reduced-motion controls freeze phase. Resume has no catch-up
  jump. Context loss restores from the current artwork only. Cover-art mode stays
  unchanged. Missing/tainted artwork has an honest static fallback, not invented art.
- Compare fixed-time pixels using the unmodified desktop engine as a separate
  oracle with identical source image, dimensions and settings. Inspect actual
  coloured and dark covers and sustained animation. Remove the legacy gradient's
  extra shade/veil; do not change the PC colour pipeline merely to satisfy v5.17
  palette coverage thresholds. Verify text/control legibility independently, using
  local text treatment or the explicit accessibility setting where needed.
- The native artwork fixture reproduces the extracted selector/type table. The
  production installer must succeed, real imported cover bytes must reach native
  success, and absent covers must deliver an NSError through `dispatchError:`.
  Unsupported ABI, catalog routes, cancellation, stale requests and ambiguous
  identities remain protected. No physical Spotify success is inferred from a shim.
- Rename is tested through visible native UI controls and public UITextInput
  operations: select a large range, cut/delete, paste, select all, replace, newline,
  finish editing, cancel, double Save, invalid names, collisions and retry. Files
  remain byte-identical; only explicit Save can request a filename change. Inline
  errors retain the same editor. Check narrow/landscape and Dynamic Type layouts.

## Implementation sequence

1. Commit this design; correct native contract fixture, record red CI, then fix ABI
   and verify green core/native artwork checks.
2. Add failing native persistent-editor interaction checks, replace the alert, and
   run native lifecycle/editing/recovery and layout checks.
3. Establish pinned desktop fixed-time reference images and a failing parity check;
   integrate the engine and correct gradient-only compositing; run parity, motion,
   fallback, lifecycle, browser and real WKWebView checks.
4. Run existing regression suites, build, inspect packaged payload, assemble and
   checksum the separate v5.18 IPA. Preserve all first-failure evidence and clearly
   state simulator/browser versus physical-device verification limits.

## UI applicability

Existing-product repair: native platform conventions, keyboard and selection,
focus, error persistence, accessibility, lifecycle, motion, visual quality and
media artwork apply (RT-00 through RT-11, RT-16A, RT-17). Finance, generated-AI
content, maps, social, games and creator-workbench composition are not introduced.
The UI standard requires visible-state evidence, not implementation-only claims.
