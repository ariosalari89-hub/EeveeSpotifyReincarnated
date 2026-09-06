# v5.17: fluid gradient and local-file management

## Scope and approval

This existing-product change continues the user's advance approval, including the
September 6 additions. The replacement goal includes every item below. A finished
gradient alone does not complete the release.

- Strong, substantial artwork-derived color regions, including accents in dark covers.
- Gradient motion resembling stirred paint, with changing curved boundaries and
  identifiable colors that never converge to a single mixed color.
- Embedded artwork in Local Files, Liked Songs, the mini-player, and Now Playing.
- In-app rename and remove for imported local audio only; preserve catalog tracks and
  external originals. Rename changes the imported filename, not embedded title tags.
- Preserve v5.16 imports/playback and all existing lyric behavior; deliver a separate
  Sideloadly IPA with scoped verification evidence.

## Observations and uncertainties

The present gradient is a rigidly transformed CSS image. Its old palette discarded
small colorful regions in predominantly gray/dark covers. Rendered four-color fixtures
also showed that one source color could be entirely hidden by the other layers.

The user screenshots show some local-list and Liked Songs thumbnails while the native
mini-player and Now Playing cover are absent. Missing tags may explain an individual
file, but cannot explain all surfaces showing different results for the same file.
The 9.1.76 player track image URL comes from its metadata. A native local image loader
reads AVFoundation metadata but its observed extraction filters to ID3. Neither this
loader's involvement in every failing view nor the user's audio containers is proven.
The fix must be established at the native artwork seam, not inferred from a web view.

v5.16 places complete imported copies in Spotify's Documents local-song source. It has
no durable per-file import manifest. Migration must not claim historical provenance
that was never stored. Files considered for management must be regular audio copies
inside that native import directory, never recursively discovered outside it. New
imports should retain stable file identity for subsequent rename/remove operations.

## Architecture and alternatives

### Gradient

Use a small canvas-backed color-field module driven by the existing preferences and
lifecycle owner. Its interface takes a palette and effective motion state/speed; it
does not own playback or settings. Smoothly deform material coordinates with curved
vortices and evaluate the same distinct palette at those coordinates on each frame.
Do not accumulate previous frames, which would progressively muddy the colors. Limit
internal raster size and cadence, preserve phase on pause and speed changes, and keep
the static CSS palette as a fallback when canvas is unavailable.

Alternatives considered: independent CSS blobs have low cost but insufficient curved
flow; importing the PC WebGL pipeline offers direct parity but introduces a larger
graphics/runtime dependency. The bounded canvas field is the initial implementation,
subject to real WKWebView rendering/performance checks. Cover-art mode remains unchanged.

### Imported files

Extend the existing Local Files settings owner with a persistent inventory and per-file
actions. A file is identified independently from its display name using filesystem
identity and a current generation. Listing, rename, removal, and metadata work happen
off the UI thread and publish authoritative outcomes. Revalidate the selected file's
identity, regular-file type, and directory containment immediately before mutation.
Reject symlinks, traversal names, unsupported types, collisions and stale/replaced
targets. Keep the extension fixed during rename and never replace another file.

Use native row actions, a filename editing alert, and a destructive confirmation naming
the exact imported copy. Preserve the proposed name on failure. Removal affects only
the selected local copy, with the original outside Spotify left intact. Spotify owns
its library indexing and playlist propagation; do not claim a scan or playlist update
merely because a filesystem operation succeeded. Do not rewrite embedded title tags.

### Native artwork

Isolate metadata extraction/cache from the version-guarded native adapter. Read actual
embedded artwork through AVFoundation across supported containers, with decoded-image
and size limits, deterministic selection, cancellation and stale-result rejection.
Resolve files by full local-track identity, not title alone; ambiguous matches do not
borrow another song's artwork. Prefer native local-file image requests and callbacks
over patching UIKit image views. Scope runtime hooks to validated classes/selectors and
local audio; normal catalog artwork and unsupported native versions fall through.
Invalidate artwork/file associations on rename, remove, replacement and rescan.

The 9.1.76 trace additionally establishes that the native player reads `image_url`,
`thumbnail_image_url`, `image_large_url`, and `image_xlarge_url`. Its v1
`spotify:localfileimage:<percent-encoded path>` requests use the AVAsset image loader;
that loader excludes non-ID3 artwork and rejects image data lacking a separate MIME
attribute. Both native cache-prevention methods return true.

Use a marked local-image request carrying the full local URI for player metadata.
The guarded native loader resolves that request asynchronously against imported
copies, so a main-thread metadata getter never scans audio or waits for artwork.
Native requests for actual imported file paths use the same bounded extraction.
Unrecognized requests fall through, and ambiguous local identities return no artwork.
The adapter invokes the native success/error dispatch path, preserving request
context, delegates and cancellation. No synchronous player getter mutates audio,
playlist identity, another track, or native view instances.

## States and constraints

Gradient supports ready, absent/invalid artwork, CORS/native-color fallback, playing,
paused, hidden, inline, disabled and reduced-motion states. Speed changes alter the
ongoing phase rate without a jump. Color changes never alter the lyric document or clock.

The local inventory supports loading, empty, available, stale, refreshing and failed.
Operations support editing/review, running, succeeded, failed and cancelled-before-commit.
Failures retain the original file and enough context to retry. No optimistic deletion.
Do not scan or upload personal audio outside the imported-copy scope. No network art
lookup and no generated replacement for absent embedded artwork.

## Applicability and evidence

Required UI modules: RT-00 through RT-11, RT-16A, and RT-17. This is an existing iOS
media product with a web-rendered lyrics surface, native settings, local private audio,
and durable file mutations. RT-12 through RT-15 and RT-16B through RT-16G are excluded:
no analytics/editor/commerce/AI/high-stakes/maps/social/learning/game work is introduced.

Use the existing native control language, Dynamic Type, safe-area layout and localized
message fallback. New optional helper copy defaults absent. Deletion consequence and
actionable filename errors are necessary; construction rationale never ships as UI.

Evidence floor: E1-E2 for rendering and local operations; available simulator/native
adapter checks for E3. Browser pixels do not prove Spotify device integration. State the
physical-device, screen-reader/human-task and signed Spotify-runtime limits explicitly.

## Completion checklist and public test seams

- [ ] Public playback/preferences messages produce broad, vivid two-/four-color regions
      with dark, gray, bright, monochrome, invalid and changing artwork.
- [ ] Rendered frames prove nonrigid internal color deformation and sustained distinct
      colors; slow/default/fast motion is visible, continuous and bounded in frame cost.
- [ ] Pause, background/visibility, inline, disabled and reduced-motion stop all gradient
      frame work; resume and speed changes preserve continuity.
- [ ] Pixel contrast, actual mobile/card/landscape geometry and automated accessibility
      checks pass for the changed background, including the bright-artwork extremes.
- [ ] The imported-file interface lists the supported scope after restart and reports
      actual rename/remove outcomes; exact-target confirmation and retained edits work.
- [ ] Real temporary audio fixtures cover collision, Unicode, traversal, symlink,
      replacement, disappearance, cancellation, re-entry and permission/write failures.
- [ ] Actual MP3/MP4 embedded art, absent art, corrupt/oversized art, duplicate identities
      and stale requests exercise the public artwork/native adapter seam.
- [ ] Native UI and WKWebView tests pass with scoped integration limitations recorded.
- [ ] Existing renderer, import, playback, lyrics and package checks remain green.
- [ ] A fresh build is inspected and assembled into a distinct v5.17 IPA; exact injected
      payloads and the final archive are checked and delivered with evidence.

## Implementation sequence

The writing-plans skill is unavailable in this installation; this explicit sequence
serves as the implementation plan under the user's advance approval.

1. Preserve first failures for rendered gradient color and deformation. Implement the
   field behind the existing background owner, then test lifecycle/contrast/performance.
2. Build one imported-file listing/rename vertical slice with filesystem fixtures and
   native UI. Add confirmed removal and adverse states using the same identity checks.
3. Complete native source-to-artwork tracing, implement extraction/resolution and a
   narrowly guarded adapter. Verify real metadata containers and callback lifecycle.
4. Run the full affected browser/native suites, inspect actual screenshots and motion,
   fix defects at their owner, and perform fresh repeats before release packaging.
5. Build and inspect the injected artifacts, package a separate IPA, verify its contents,
   and report only observed results with remaining device-only checks.

Self-review: scope, ownership, destructive target, renamed value, lifecycle, fallbacks,
test seams and release limits are explicit. No additional approval gate is introduced.
