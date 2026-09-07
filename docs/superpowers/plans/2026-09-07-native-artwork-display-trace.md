# Native local artwork: display-boundary trace

## Scope and evidence

The device report confirms that the local cover is visible on the lock screen
but not in Spotify's player. The v5.20 trace confirms installed adapters and
successful local image loads; it does not connect those loads to the cover view.
This is a diagnostic continuation, not a verified artwork fix. The existing
artwork reader, ownership checks, metadata values, renderer and gradient stay
unchanged. The user's advance approval covers this bounded continuation.

Read-only inspection of the supplied Spotify 9.1.76 ARM64 executable
(`8ec29afac67d2a068e3b47f8fe6727c055f65472e1a96b0b9171fd29e9db05bd`)
establishes these boundaries:

- Native cover models call `metadata`, then NSDictionary's
  `spt_metadata_coverArtURL`, `spt_metadata_coverArtURLLarge`, or
  `spt_metadata_coverArtURLXLarge`. These read `image_url`, `image_large_url`,
  and `image_xlarge_url`, respectively. The current keys are not a demonstrated
  cause of the failure.
- The TrackArtwork provider feeds a URL into an Encore image component.
  Encore's image loader bridges through the image-loader kit delegate.
- Both native cover-cell variants expose `coverArtView` as an Objective-C
  getter. Their providers are Swift existentials; do not read or patch their
  private storage or witness tables.

## Implementation

1. Observe the three native cover-URL getters and the image-loader kit's
   success/error callbacks, with exact method-encoding gates. Preserve each
   original call and return value. Tag local metadata dictionaries and image
   URLs with bounded session-local integer identifiers, not hashes or raw text.
2. Connect the existing remote-load trace to the same identifiers. Associate
   successful image objects with their trace identifier for a best-effort
   connection to the displayed UIImage. A newly transformed image can have an
   unknown identifier; never infer that it is another track's image.
3. Observe native cover roots and the mini-player's view, using public UIKit
   getters only. Record bounded counts and visibility/geometry flags, not UI
   text or screenshots. Do not create an overlay, change hidden/alpha/image,
   force layout, read Swift ivars, or load extra artwork.
4. Keep observers optional: a missing class/signature disables only that
   observer. Retain the existing bounded, redacted diagnostic export.

## Agreed verification boundaries

Use the existing native-adapter installation and diagnostic-export interfaces.
System-boundary fixtures reproduce independently extracted vendor selector
encodings; they are not evidence of Spotify's physical-device rendering.

- Selected URL and callback share a trace ID; distinct URLs do not.
- Native URL results and callback arguments remain unchanged, including nil
  images, errors, catalog requests and unsupported observer signatures.
- Snapshots distinguish empty, populated, hidden and zero-sized cover views
  without changing the view or retaining it after reuse.
- Export excludes raw URLs, paths, title/artist/album, context, cache keys and
  error descriptions. Per-session bounds still hold.
- Run the full existing package checks before delivering a diagnostic IPA.

## Device handoff and acceptance

The next device capture must include the blank native Now Playing cover and
the same session's artwork log. Interpret getter, loader, callback and view
observations together. The unresolved cover defect remains open until the
real in-app cover is shown for the reported local track and stays correct
across track switching. Passing fixtures and packaging checks do not close it.
