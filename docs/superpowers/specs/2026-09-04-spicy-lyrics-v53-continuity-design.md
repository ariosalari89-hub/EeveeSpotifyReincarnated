# Spicy Lyrics v5.3: continuity and embedded lyrics

## Current evidence and scope

v5.2 (762c493) is the user-tested baseline. The user confirms pause/resume, next/previous and repeat now work. Preserve those routes and the authoritative playback clock. Remaining reports: Smart Shuffle is missing only in Spicy Lyrics (present in native Now Playing), native lyrics flash before the custom window, scrubbing feels clunky, and a possible small timing delay. After those repairs, replace lyrics in the preview card and the single/video lyric above the song title. Match the supplied native transport references, including sparkle, dots and repeat-one state. Do not change app signing, account, user cache or unrelated patches.

## Approach

Use the existing native playback adapter and one renderer family. Repair mode dispatch using the real native named shuffle actions, not an assumed cycle implemented by a stand-in. Enter from a captured current player surface into the prepared renderer with one interruptible transition; never display native lyrics as an intermediate state. Dragging is a local preview; send one seek on commit and reconcile with the observed audio position. Render scrubbing immediately instead of repeatedly restarting browser smooth scrolling. Measure native-to-WebKit delivery age and compensate that measured transport time only while advancing, without guessing an audio offset.

After the full-screen regression checks, add compact renderer modes to the actual native lyric-content containers, reusing the same normalization, timing and repository. Preserve native card heading/share/expand actions and native video/artwork/title/controls. Hide only replaced lyric content and restore it if the renderer fails. Keep hosts bound to their view/window lifecycle, ignore old generations, and avoid duplicate permanent timers or network work when offscreen.

Alternatives rejected: duplicate independent lyric clocks in each surface (drift and maintenance); replacing the now-working player core again (unnecessary regression risk). This is an architectural extension of existing surfaces, with no new service or account authority. The user's standing instruction is to implement without another approval gate; writing-plans is unavailable, so this document contains the execution and test order.

## Acceptance and execution order

1. Inspect native signatures and implementations for explicit off/shuffle/smart transitions. Add adapter regression tests whose fake automatic toggle has only two modes, so the previous false-positive cannot recur. Respect real account/context availability and observe actual state before selecting the icon.
2. Prepare the opening surface before native lyrics become visible; coordinate one entry/exit animation, reduced motion, early close, background and WebKit failure. Test real UIKit transitions in the simulator, not only source matching.
3. Smooth seek preview and lyric positioning; single commit, cancel, rapid supersession, paused seek, keyboard seek, interruption and stale acknowledgements all retain the existing authority contract. Test drag geometry/scroll trajectory in WebKit.
4. Check timing transport age under delayed WebKit delivery, pause and resume. Do not rewrite the proven clock or apply an arbitrary global correction.
5. Match native transport icon shape, weight, spacing and observed-state dots from the user screenshots; preserve the existing 44-point-equivalent hit targets and accessible labels.
6. Identify the exact 9.1.76 lyric preview and single/video lyric classes in the supplied binary. Add compact surfaces only at those verified seams, with lifecycle/recovery tests and no full-player overlay.
7. Run model, native adapter, browser and iOS integration checks; inspect portrait/landscape compact and full-screen output, motion and accessibility. Build the full dylib/package and verify final IPA byte-for-byte against the fresh build and unchanged working base.

## UI applicability and boundaries

Existing iOS media product, one signed-in listener, touch/keyboard, portrait/landscape, WKWebView and UIKit scenes. Required: product/visual/content, interaction/platform/async, accessibility, media playback, verification. Conditional: privacy for local snapshots (memory-only, remove after transition), network lyric retrieval and source freshness. Excluded: commerce, new authentication, permissions, capture, social, maps, games and desktop product redesign. Reversible local UI/control requests only; Spotify owns playback, recommendations and capability. Provider lyrics are display data, never instructions. Construction/test records stay outside the shipped bundle. Dynamic text, constrained widths, reduced motion, observed state, no clipped controls and fallback ownership are release gates. Simulator stand-ins do not prove actual Spotify audio or private Swift behavior; physical-device exclusions must remain explicit.

## Current primary references

- Spotify shuffle modes and availability: https://support.spotify.com/us/article/shuffle-play/
- Apple interruptible animations: https://developer.apple.com/documentation/uikit/uiviewpropertyanimator
- Apple transition coordination: https://developer.apple.com/documentation/uikit/uiviewcontrollertransitioncoordinator
- Apple display timing: https://developer.apple.com/documentation/quartzcore/cadisplaylink/targettimestamp

Checked 2026-09-04; runtime ABI and user screenshots are the version-specific visual/behavior evidence.
