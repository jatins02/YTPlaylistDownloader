# Review of implemented Stages 5 and 6

Date: 2026-10-16. Reviewed baseline: `728d5d1` (Stage 5 implementation
`c768a10`, with the locally committed Stage 6 implementation).

## Scope and findings

Reviewed playback/controller lifecycle, the persistent editor/cover/selection
route, export snapshots/publication/delivery, guarded native workers and cleanup,
with their repository, widget, native and real-media tests, against the plan and
product/state contracts. Dependency pins and shipped migrations are unchanged.

The following defects have reproducing regressions and targeted fixes:

- Version matching treated fragments inside ordinary words as complete markers,
  dropping Live from titles such as Olive/Delivery. Names, filename previews and
  embedded titles now recognize complete Unicode markers, with escaped phrases
  and existing parenthesized versions retained without duplication. Completed
  publications stay immutable; a new review revision applies naming corrections.
- A seek-to-end awaiting Stop could overwrite a newer resume request's position.
  Its completion now requires the same playback generation.
- A late pause failure could add an obsolete error to successful newer playback.
  Pause failure publication now uses the current generation too.
- Persistent player Play/seek controls remained enabled during export, processing
  and cancellation. Both player and row actions use the same review/capability/
  busy-state guard. Stop remains available.
- Retention could cancel an open editor and remove its media while the user was
  typing. The expiry transaction now preserves running review tokens. Explicit
  user Pause/Cancel still fences them; Save/Cancel releases the retention hold.
- Cancelling an already completed export was ignored by the older media stop
  contract. The desktop adapter now stops/fences active delivery, then performs
  the permitted cancellation transition for a completed publication. Discard
  removes only private files; exported MP3/ZIP copies remain intact.
- Export orphan cleanup recreated discarded job directories. It now checks for
  existing export storage before allocating any private directories.
- A foreign FIFO replacing a staging file or private input could block the
  worker before its regular-file check. Nonblocking opens reject/leave special
  files immediately, retaining inode/nonce ownership checks and existing copies.

Stop also queues its media database fence before preliminary state reads and
waits only for the job's own active export. Existing provider-wait pause/cancel
regressions verify that released late results cannot slip through this boundary.
Destination directory descriptors close even when staging cleanup fails. The
read-only worker helper no longer has an unused read/write mode branch.

Export state fixtures use native paths under their test-owned temporary root.
Windows foundation execution now passes CI; native media/export execution remains unverified.

## Regression and acceptance evidence

Eight new behavior tests failed against the original behavior, then passed with
the fixes: version-marker matching, two playback races, one busy-player widget
case, discarded-job orphan cleanup, real open-editor retention, cancellation of
a completed export, and special-file recovery. The focused Flutter run passes 39 cases. The native
export acceptance now calls the actual cancellation adapter instead of manually
transitioning through review to cancellation.

Final source commands/results (Linux, zero skipped):

| Command/check | Actual result |
| --- | --- |
| `flutter pub get --enforce-lockfile` | Pass; no pin/lockfile changes |
| `dart format --output=none --set-exit-if-changed lib test integration_test tool` | 92 files unchanged |
| `flutter analyze --no-pub` | No issues |
| `STAGE3_TEST_RUNTIME=<pinned manifest> flutter test --no-pub` | 233 passed (208 ordinary + 25 opt-in real-media cases) |
| Ordinary `flutter test --no-pub` without the runtime variable | 208 passed |
| `PATH=<project codec bin> .venv-stage0/bin/python -m unittest discover -s tests -v` | 78 passed |
| `scripts/test_linux_native.py --test export_test.dart` | 1 actual native integration case passed |
| Same helper with `foundation_test.dart`, `pipeline_test.dart`, `enrichment_test.dart` | 1 case each passed |
| `scripts/test_stage5_audio.py` with isolated PulseAudio 17.0 | 1 actual native playback/review case passed |
| `flutter build linux --release --no-pub` | Pass |
| `scripts/check_native_bundle.py apps/native/build/linux/x64/release/bundle` | 18 files; no dotenv asset or literal Groq key |

The native helper commands use the project Python environment and the exact
Linux prerequisites/runtime from the stage guides. Existing source/tag/artwork,
transaction/rollback, recovery, collision/ZIP and native byte-transfer checks
remain part of these suites.

Actual media is generated fictional audio: equal-title distinguishable tones,
full 65-second MP3s, bounded previews, fictional metadata and verified cover bytes.
Native checks use disposable SQLite/keyring sessions and an isolated local audio
sink. No live source/provider call or owner `.env` was used. No system compiler
packages, normal desktop audio service, sibling DOT. files or credentials were
changed. Existing Stage 3 runtime pins and Flutter 3.47.5/Dart 3.13.4 are retained.

## Publication and remaining gates

The complete reviewed change was published through [PR #2](https://github.com/jatins02/YTPlaylistDownloader/pull/2)
and squash-merged into `main` as `10164cadc77490efa202a68304477556a3fbc3fa`.
The branch and merged tree exactly equal tested local commit `4ccb02c`
(tree `2cc8c8ed649d01ff6b0e8d66acd34792a5963158`). The signed-in browser
performed authorized publication; local commits remain on
`backup/stage56-local-4ccb02c`.

[Branch run #57](https://github.com/jatins02/YTPlaylistDownloader/actions/runs/38913338077)
and [PR run #58](https://github.com/jatins02/YTPlaylistDownloader/actions/runs/38913473773)
passed all six checks before merge: 208 ordinary Linux tests, 199 Windows tests
with one privilege-dependent symlink skip, 78 Python tests, native desktop
foundation/restart integration, release builds, formatting, analysis and secret
scans. The merged main commit independently passed all three jobs in
[Foundation run #59](https://github.com/jatins02/YTPlaylistDownloader/actions/runs/38961141438).
CI does not run the opt-in real-media/private-audio/export suites;
their separate local Linux evidence is recorded above.

Manual Linux save-panel/physical-player checks and Windows/Android/iPhone
media/export execution remain unverified. Native destination acceptance injects
test-owned chooser paths while performing actual tagged-file/ZIP byte transfer.
No desktop/mock result closes another platform's gate. The configured Linux
filesystem requirement (hard links and user extended attributes) is unchanged.
