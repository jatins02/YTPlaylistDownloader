# Stage 0/1 code review

Date: 2026-10-12. Scope: implemented Stage 0 feasibility harness and Stage 1 Flutter foundation, their tests, setup and baseline CI. The project remains a zero-budget independent-device downloader with device-only saves. This review does not implement the later media/review/export stages.

## Findings fixed

| Area | Problem and resulting behavior |
| --- | --- |
| Startup | Retry returned a Future from setState, triggering an assertion, and rapid presses could open competing storage sessions. Retry now updates state synchronously, permits one open at a time and shows pending startup. The failure screen scrolls at large text/landscape sizes. |
| Cancellation/failure | A cancelled track's worker still updated checkpoints, and failed jobs retained active workers. Terminal transitions retire the affected tokens; unaffected peers continue. |
| Recovery | Each interrupted attempt changed the same job again and reset ready tracks to queued. Recovery groups work by track/job, updates each revision once, preserves unambiguous playable audio and keeps terminal records terminal. |
| Retry history | Historical retryable attempts stayed eligible after a newer retry completed and could block finalization. Starting a retry retires the prior row while preserving its valid non-export checkpoint. |
| Export checkpoints | A new snapshot inherited the previous export's published checkpoint. Every new export attempt starts pending. Leaving an unfinished export retires its worker and marks the abandoned snapshot failed. |
| Export contents | All audio manifests for a selected track were frozen, leaving the worker to guess. Finalization requires one verified audio manifest per selected track, records its immutable asset ID and refuses pending processing. |
| Export reuse | An old completed snapshot could be returned after edits; stored snapshot hashes were not checked on reuse. Reuse now checks the unchanged review state and verifies the stored hash. |
| Metadata history | User edits overwrote the only structured metadata copy. Schema v3 stores an immutable original copy for new tracks. Legacy originals remain null; edited fields are never falsely labeled original. Historical migration phase lists no longer depend on changing runtime enums. |
| Checkpoint ownership | Checkpoints accepted references to another job/track's asset. References must now identify an existing asset owned by that attempt's job/track. |
| UI state races | Delayed key reads could undo a completed save; delayed lists could discard a new draft. Generation/revision checks protect newer state, and draft lists merge by stable identity/revision. A successful committed draft no longer becomes a reported save failure because a subsequent list query fails. |
| Storage cleanup | Secondary close failures could prevent lock cleanup and mask the startup error. Cleanup now always attempts to release ownership and preserves the original safe error. |
| Subprocess output | A command finishing between polls bypassed the output limit and returned silently truncated data. Completed output is now checked too. Windows timeout/quota termination requests the process tree rather than only the parent. |
| Audio verification | NaN durations passed bounds, and partly corrupt MP3s could decode with logged errors but exit zero. Finite durations and strict FFmpeg error exit are required. The corrupt-MP3 test reproduces the original false pass. [FFmpeg error-exit option](https://ffmpeg.org/ffmpeg.html) |
| ZIP publication | Archive construction bypassed scratch limits and replace() could overwrite a concurrent winner. Size planning/runtime checks, unique private temporary files, manifest/checksum readback and atomic no-overwrite publication now protect the output. Failed partial files are removed. |
| Source input | Empty duplicate list parameters were discarded by parsing. They are now preserved and rejected. Malformed playlist identities/title/uploader types cannot silently break collection of valid peers. |
| AI input | Whole report records, including extra private fields, were sent to the provider without caller-side bounds. Naming inputs now allowlist bounded identity/title/uploader/duration, reject duplicates and exclude unrelated report fields before making a request. Output text rejects control/blank semantic fields. |
| Cover identity | Unknown albums chose the first release, and primary-only matching missed known featured credits. Matching now requires a unique exact recording, known album or unambiguous release, and the complete known artist credits. Uncertainty withholds the cover. |
| Provider resources | Groq/artwork sessions were not scoped; a private-link write failure left uploaded objects without rollback. Clients close after use, streaming reads enforce byte/deadline checks, and optional storage rollback includes local link publication failure. Tests use mocks only. |
| Evidence/runtime | CPU totals included earlier runs in the same process, and basic live media required unused cloud/AI packages. Metrics subtract the current-process baseline and stop in finally; dependencies are required only for requested integrations. |
| SDK reproducibility | Checking SDK HEAD alone accepted modified tracked source. Bootstrap also rejects tracked modifications before invoking Flutter. |

## Verification

- Python: `python -m unittest discover -s tests -v` — **30 passed, zero skipped**, including actual synthetic media, tags/cover/ZIP and intentionally corrupted MP3 decoding.
- Native: `flutter test --no-pub` — **48 passed, zero skipped** on Linux, including real SQLite v1/v2 migrations and widget/controller regressions.
- Native plugins: `python3 scripts/test_linux_native.py` — **1 passed**, real keyring/path-provider/SQLite and draft close/reopen in a disposable session.
- `flutter analyze --no-pub` — no issues; Dart format check passed.
- Linux release build and native integration debug build passed; release scan checked **14 files**, with no dotenv asset or literal Groq key.
- The **3 retained live sample full-length MP3s** passed the stricter decoder without downloading again.

Six new native regressions were observed failing against the pre-fix code, and the initial Python regressions reproduced the corresponding failures or missing guards. Additional tests cover migration, privacy, rollback and startup behavior. Mock provider responses do not establish live account quality or device support.

The isolated review reused the existing SQLite download cache because upstream DNS failed; the pinned dependency checks that cached binary's expected hash. No dependency version changed. Existing repository edits, DOT., credentials and exported media were preserved.

## Compatibility and limits

Schema v3 is append-only. Older v1/v2 databases migrate without losing saved edits; original source titles remain available, but previously overwritten structured originals cannot be recovered. Older app versions must not downgrade the database. New snapshots include audio_asset_id; adapters must respect that identity and snapshot hash.

The foundation deliberately rejects multiple audio assets for a selected track. Stage 3 must define active audio selection and retention before a retry keeps several converted derivatives; it must not export an arbitrary one or every historical one. File verification still belongs to the native adapter before registering a manifest, and actual ZIP/device-transfer completion remains Stage 6 work.

Atomic Stage 0 ZIP publication requires a local filesystem supporting hard links; unsupported filesystems produce a safe publication error. Windows process-tree handling is implemented but not executed here. Linux is the verified foundation platform; Windows/GitHub CI, live Groq/artwork/storage checks and actual Android/iPhone execution/distribution remain open gates. This review does not mark those checks passed.
