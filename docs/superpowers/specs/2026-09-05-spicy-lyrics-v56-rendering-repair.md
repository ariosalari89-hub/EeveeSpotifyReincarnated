# Spicy Lyrics v5.6: bounded rendering repair

## User outcome and scope

Repair the reported above-title caption returning to an earlier lyric, a brief
2x zoom of Now Playing before fullscreen, and unnecessary work contributing to
fullscreen stutter. Keep the existing full-screen design, controls, preview,
inline replacement and landscape layout. This is an existing-product media
interaction repair, not a new interface or a change to account/signing behavior.
The user has already authorized implementation and prefers a simple update-over-
current Sideloadly handoff. No new approval, uninstall or cache reset is needed.

The UI/test-first workflow separates public boundary regression evidence,
actual UIKit geometry and rendering-cost measurements from physical-device
claims. No new private Spotify selectors or dynamic invocations are introduced.
The previous native Swift-root reflection crash repair is left unchanged.

## Decisions and regression contracts

| Report / risk | Repair | Required evidence |
| --- | --- | --- |
| Caption jumps to intro in a later short timing gap | Keep the most recent lead, while retaining active interludes | Model edge cases and production inline renderer at a known later gap |
| Whole-player snapshot briefly doubles in size | Size the root before adding autoresizing cover and snapshot children | Actual UIKit window/cover/snapshot must all be 393x852 before reveal; old code reproduced 786x1704 children |
| Paused and hidden pages keep rendering unchanged state | Cache lyric states and painted values; skip unchanged/hidden work | Zero steady idle/hidden mutations, without stopping advancing playback |
| Preview and caption consume work behind fullscreen | Recognize our own higher window in the same scene as occlusion | One visible playback consumer while covered; two fresh embedded consumers after close |
| Same artwork and labels rebuilt on every observation | Cache the presentation values independently of the playback session | Eight unchanged observations create no Images or label mutations; real metadata/color/artwork changes still update |
| Foreground timers wake a still-covered surface | Emit visible only after successful fresh publication | Inactive/active notifications must produce zero visible messages on covered renderers; normal close still resumes them |

## Verification surface and exclusions

Production JavaScript is exercised in the local browser with deterministic
fixtures. Production UIKit/WKWebView host/coordinator and embedded hooks are
exercised in the iOS simulator with simulated Spotify objects and playback.
Native control, playback-clock, bundle/model and shared request tests remain
required. The image cache has no impact on session acceptance, generation,
transport commands or timestamp normalization.

The browser performance comparison uses 80 synthetic lines, ten timed tokens
per line, a 393x852 viewport and distinct paused/playing/hidden intervals.
The measured reduction is callback CPU/DOM work in desktop Chromium, not a
physical iPhone FPS figure. The hidden-native-consumer regression independently
checks the production host boundary. These are E2 fixtures/integration evidence;
they are not E3 confirmation inside the user's Spotify installation.

No phone app/data, credentials, saves or caches are changed by build/test work.
No physical media or phone logs are uploaded to CI. Synthetic artwork and
lyrics are used in all automated evidence. Account/security/payments/design
systems and unrelated product changes are out of scope.

## Build and handoff

Production source is frozen at `7894fd15f7ed4790f713f673fda29fad92d43aaf`.
The final full-build dispatch is pinned to that exact commit (not a mutable
branch): https://github.com/ariosalari89-hub/EeveeSpotifyReincarnated/actions/runs/33952117380.
Documentation changes after that commit do not alter the compiled source.
Do not ship a failed or unchecked artifact. The adjacent local v5.6 Evidence
folder records the final outcome, hashes, test transcripts and screenshots.

Package the freshly built Eevee payload into the proven corrected Spotify
9.1.76 base without reinjecting its executable. Require byte equality for all
payload files and all untouched base files, exact tested renderer bytes, ZIP
integrity/uniqueness, ARM64 and one load command for each injected library.
Preserve prior versioned artifacts. Sideloadly must update over the current app
using the existing identity and installation settings; do not delete Spotify.

The final phone check is limited and explicit: affected captions between
phrases, repeated preview expansion, continuous fullscreen playback/seek/pause,
leaving and returning to the app, and closing fullscreen at a later position.
Do not call perceived phone smoothness verified until it is actually tested.
