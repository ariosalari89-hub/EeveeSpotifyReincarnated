# Local audio import — follow-up to v5.15

## Outcome and approval

Add an in-app option to choose audio files and copy them into Spotify's native local-song source. Deliver this only in a separate follow-up IPA, provisionally v5.16. The completed v5.15 IPA remains unchanged.

The user requested the sequence on September 6, then explicitly approved the plan and implementation in advance and asked not to pause for further plan approval. This is an architectural addition: existing settings navigation and native local-file playback exist, but this repository has no file-import workflow. Design and implementation proceed under that advance approval.

## Evidence and alternatives

Spotify's current [local-files documentation](https://support.spotify.com/na-en/article/local-files/) says that iOS reads audio copied into the app's Files folder when Local audio files is enabled. The setting is owned by Spotify under Settings and privacy → Apps and devices; the resulting collection is in Your Library → Local Files. This is documented provider behavior, not proof of this sideloaded build's physical-device indexing.

The supplied 9.1.76 executable contains the `spotify:local-files` route, LocalFilesAPIService, LocalFilesSettingsModelImpl and `enableDocumentsFolderAccess`. Static inspection also shows that the latter is conditional on a native configuration value and has no success return. No new private hook, private ivar access, forced configuration flag or fabricated indexing acknowledgement is needed for the selected design.

Approaches considered:

1. **Selected:** system audio picker → app Documents folder → native Spotify Local Files. Preserves the existing library, playback and local-files toggle; adds only the missing on-phone copying workflow.
2. A separate local library/player would own decoding, queue, background audio and media controls independently. That expands the requested scope and duplicates native behavior.
3. Desktop transfer alone uses existing support but does not provide the requested in-app file option.

Apple's [document-picker contract](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller) provides user-selected access and optional copying. Use the real system picker, allow multiple audio files, and leave source originals unchanged. Release any security-scoped access actually acquired; coordinate external reads. Never retain external URLs as durable permissions.

## Product and ownership

- Add a Local Files destination to the existing Eevee settings list, using its current navigation, native grouped-list presentation, system text and green action color.
- The page owns an Import audio files command and an Open Local Files command. The latter navigates to the observed native route; it is not playback or an indexing-success receipt.
- The file picker owns provider browsing, downloading its selected copies, cancellation and permission UI. No fake permission dialog, broad folder scan, clipboard inspection or account changes.
- The import module owns validation, copying, filename collision handling, partial results and cancellation. Spotify owns metadata indexing, local-track identity, playlists, playback and its Local audio files setting.
- A compact necessary instruction identifies the native setting needed for indexing. Do not add a second toggle with a conflicting owner. A copied file is reported as copied, never as indexed or playing.
- Source names are user-provided display data. Do not put full source paths, audio contents or filenames in diagnostic logs or external requests.

## File operation

Use one small caller-facing import interface returning per-file results with stable identity, display name, outcome and the resulting local file URL when present. Keep validation/copying/naming details inside this module. All lengthy work runs away from the main thread.

The destination is the application's Documents directory, obtained from Foundation at runtime. Do not hard-code a sandbox UUID. Stage incomplete copies outside the scanned destination, then move a fully copied file into place without replacing an existing file. Source originals remain byte-for-byte unchanged.

Validate local regular audio files with platform audio-reading support. Reject missing, empty, non-audio, unreadable/protected, directory and symbolic-link inputs with per-file reasons. Do not promise formats beyond observed decoder support; do not transcode or strip DRM.

For a name collision, preserve the existing file. If the same destination name already has identical content, report it as already present. If content differs, select a distinct suffixed name and return that actual name. Bound filesystem-name length by encoded bytes without splitting Unicode characters. Containment and non-replacement must hold even if a competing writer creates the destination after the initial check.

Cancellation stops uncommitted work and retains files already copied. Cancellation of the picker has no import effect. Partial failure retains successful items and reports failures individually, with a route to select/retry files. Never use one success badge for an unsuccessful batch or interpret dismissal as cancellation.

Keep the operation alive across ordinary view navigation; a returning page observes its current state. Do not promise resumable external-provider access across process termination. Incomplete staging files must never look like playable imports; cleanup is limited to the import module's own staging area. No user-library deletion feature is added.

## Interface states and accessibility

Model idle, picker presented, importing with known item count, cancellation requested, and finished results including partial success. Progress reflects real file work, not an animated timer. Prevent duplicate import submission while keeping stop/navigation available. Results and errors remain reviewable.

Use native buttons, lists, file picker and status semantics. Support Dynamic Type, dark/light and increased contrast where applicable, short/narrow layouts, VoiceOver names/values, focus restoration and long/RTL filenames. Avoid redundant helper/status copy and construction-language exposure. Do not add a custom media player, decorative dashboard or a second inventory of Spotify's entire local library.

## Verification seams and evidence limits

Advance-approved test seams:

1. **Imported output file:** call the public import interface using isolated temporary input/destination directories; consume its returned file URL with the platform audio reader and compare output/original bytes. Cover collision, duplicate, malformed/empty/missing input, cancellation, partial batch and durable output. Do not assert private helper calls or query hidden state.
2. **Real native UI flow:** render the actual settings page in the iOS fixture, operate its import command, inspect the real document picker and exercise delegate completion/cancellation with isolated files. Observe visible result state and returned local file. Test the external route through a no-effect route adapter rather than launching another app during automated tests.

Use vertical TDD slices: one behavior failing at an agreed seam, minimal implementation, then repeat. Preserve the first failure. A compile-only failure is not evidence of an observed behavior defect; establish a runnable red control when appropriate.

Run focused Foundation/audio tests on macOS because this Windows workspace has no Swift/UIKit/AVFoundation compiler. Add native iOS integration to the existing CI verification path and inspect its screenshots at representative sizes/text scales. Use fresh complete regression/native/package checks for the final follow-up build. Existing Spicy Lyrics source should remain byte-identical to v5.15 unless a demonstrated import interaction requires a scoped repair.

The isolated simulator does not contain the proprietary Spotify app. It can verify picker presentation, files, audio readability, state and route requests, not real-account native indexing or end-to-end phone playback. Those limitations must remain explicit in the handoff. No user audio is uploaded as test data, and no test media or fixture code is packaged with the release.

## Applicability and non-goals

Required UI modules: RT-00–RT-11, RT-16A and RT-17, proportional to a native settings/file operation. Required seams include uploads × async/partial state, system picker × permission ownership, navigation × operation lifetime, localization × geometry, and media × effect truth.

Excluded: commerce, generated content/AI, maps, high-stakes decisions, collaboration, cross-device sync, social publishing, gaming and capture/conferencing. No new external service, credential, account operation, music downloader, transcoder, custom playback engine, library purge or unrelated refactor. Existing reset-all behavior is outside this feature and must not be invoked by tests or imports.

## Implementation sequence

The separate writing-plans skill is unavailable in this session. This direct plan is the fallback, under the user's explicit advance approval.

1. Establish a short focused macOS CI runner and one runnable failing import-output test. Add the minimal import module and pass that behavior.
2. Add one adverse behavior per red/green cycle: preserved originals, duplicate/collision handling, rejected inputs, cancellation and partial batches. Keep actual filesystem/audio operations in the isolated test seam.
3. Implement the operation model and native settings/picker flow through a failing native integration test, then verify native result/navigation/cancel and layout/accessibility states.
4. Integrate the focused checks with the normal build. Run regression/native suites and review generated/package drift.
5. Produce a new follow-up IPA from the fresh build, verify its exact intended archive changes and source hashes, retain v5.15, and hand off with the native setting path and physical-device limits.

Self-review: scope, source/destination ownership, copy versus indexing truth, cancellation, unknown external outcomes, testing seams and release limits are explicit. No unresolved user preference is needed to start the first slice. Supported codec details and native rendering remain evidence to collect, not guessed guarantees.
