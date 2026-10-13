# Project status

Updated: 2026-10-13.

## Current state

**Stage 0 is in progress.** The bounded CLI, tests, dependency pins and optional container/provider probes are implemented. The Stage 1 native foundation is implemented and accepted on the proven Linux platform; Windows build execution remains pending. Stage 2’s fictional interface journey is complete. The real downloader/review/export application is not implemented and no cloud resources have been provisioned.

| Stage | Status | Evidence |
| --- | --- | --- |
| 0 — Feasibility | In progress | 30 tests pass; 3 synthetic runs and 3 live local playlist runs pass; native/provider gates open |
| 1 — Native foundation | Implemented; Linux accepted, Windows verification pending | 48 behavior tests, static analysis, debug/release Linux builds and 1 native plugin/restart integration test pass |
| 2 — Design/fixture flow | Complete for fixture UI | Responsive journey; 80 native tests; rendered review; Linux integration/build pass |
| 3 — Device pipeline | Not started | Desktop CLI proof only |
| 4 — AI/artwork | Not started | Provider adapters written; real key/match checks pending |
| 5 — Review/edit | Not started | Written behavior |
| 6 — Device save | Not started | CLI ZIP verified; native picker/export untested |
| 7 — Device QA | Not started | No real phone evidence |
| 8 — Packaging | Not started | No installed application packages |
| 9 — Release | Not started | No release |

## Owner decisions from Stage 0

- Zero budget and no existing host/object-storage setup.
- Android and iPhone must work independently; laptop companion access is insufficient.
- No Mac or iPhone available for building/testing.
- Device downloads only, no permanent cloud music library.
- Stage 1 desktop priority: Windows and Linux.
- Create this project's .env for a new user-provided Groq key; do not reuse DOT.'s credentials.

The original hosted plan has been superseded as the default. Flutter is selected for the foundation; native media adapters remain provisional; iOS is still required but unproven. Independent Android/desktop work can progress without claiming both-phone completion.

## Initial Stage 0 evidence (before the code review)

Command: `python -m unittest discover -s tests -v` — **15 passed, zero skipped**, including actual FFmpeg conversion/decoding, ID3 tags/cover readback and ZIP verification.

Command: `python -m stage0 synthetic --runs 3` — all three runs passed, using fictional generated media. Duplicate final names and a Unicode title survived; the generated cover was embedded and read back.

Command: `python -m stage0 live --playlist <owner-supplied playlist> --host-label development-environment --host-region unspecified` — executed three fresh runs (one plus two), each downloading/decoding/tagging/exporting all three distinct tracks.

| Run ID | Wall time | Sampled peak process-tree RSS | Sampled peak scratch | ZIP bytes |
| --- | --- | --- | --- | --- |
| 0f139c940a054b2ab9fc4955c44eb65f | 20.524 s | 142032896 bytes | 91758715 bytes | 30118649 |
| cd2a2398e2164fd0b955e9bd70f9a191 | 19.434 s | 137121792 bytes | 91758715 bytes | 30118649 |
| d449500c0cbc45f9bc3eb294480514ee | 20.089 s | 137396224 bytes | 91758715 bytes | 30118649 |

Track durations: approximately 140.00, 292.80 and 319.08 seconds. All runs produced full-length MP3s, bounded previews and a checksum-verified ZIP. Reported artist values are fallback Unknown Artist because AI was not called; no online cover was embedded in the live playlist runs. The sample contains a verse-only and slowed/reverbed source, so preserving version/clip distinctions is a required naming check.

Measurements are local sampled observations, not phone capacity or hosting availability claims. Sanitized summaries are in STAGE0_RESULTS.json. Ignored stage0-runs contains all three local live reports and one representative run's media/ZIP for follow-up testing; duplicate media from the other runs are not retained in the project. Raw source/network logs and signed links are not included.

## Runtime exercised

Python 3.14.4; yt-dlp 2026.8.19; yt-dlp-ejs 0.8.0; Groq SDK 1.7.0; Mutagen 1.48.1; python-dotenv 1.2.4; FFmpeg/ffprobe n8.1.3-17-gc389840894-20261011; Deno 2.5.4. Other exact Python versions are in requirements-stage0.lock.

Dependencies/tools were first tested in isolated /tmp locations, then an ignored project-only .venv-stage0 and .tools-stage0/bin were prepared and checked from this folder. Activate .venv-stage0 to run the harness here. No system Python or DOT. environment was changed. Recreate clean-checkout setup using STAGE0_GUIDE.md. Docker, Java/ADB and Xcode are unavailable here. The Stage 1 work used an isolated Flutter 3.47.5 / Dart 3.13.4 SDK and Linux build toolchain; Linux native builds are now verified. No system compiler packages were installed and no Windows/phone build has been verified.

## Pending Stage 0 gates

- GROQ_API_KEY is empty at setup time; choose Groq's free plan, paste the key into .env and run metadata-check on a retained report. Account access, quota and song-identification quality remain unverified.
- MUSICBRAINZ_CONTACT needs a project URL/contact identifier before the known recording/release/cover check.
- Actual Android extraction/runtime/conversion/export spike and device evidence.
- iOS-compatible extraction/media adapter, Xcode/build access, real iPhone evidence and a viable distribution route. No Mac/iPhone is available; this is an unresolved feasibility requirement, not a passed or dropped feature.
- Laptop packaging and actual saved-file/player evidence beyond the CLI.
- Native device resource/battery/lifecycle limits and final capacity choices.

Public App Store distribution has membership requirements; zero-budget public iOS release is not promised. Optional hosted storage probes are not mandatory under the revised native baseline. No API key, cloud storage account or paid service was provisioned.

## Stage 1 implementation and acceptance

Implemented in apps/native: a minimal responsive lavenderblush draft/settings screen, canonical URL values, immutable identities, original/effective/suggested metadata, field overrides, SQLite v1/v2 migrations, optimistic revisions, generation-checked attempts/checkpoints/assets, frozen export snapshots, private per-job folders, OS session locking and secure personal-key storage. The native media adapter explicitly reports unavailable capabilities; no source downloads or preview/export success is fabricated.

Recorded toolchain: Flutter 3.47.5 revision 6a19cca56475dbfba1478ee68d7bd0c2ef891da1; Dart 3.13.4; Linux x64 Ubuntu 26.04.1 LTS; clang 21.1.8. Direct dependencies and full resolution are pinned in pubspec.yaml/pubspec.lock. The minimal native project was generated/tested in an isolated /tmp checkout with extracted build prerequisites, then its source was copied into this repository. System packages, DOT. and user credentials were not modified.

| Check actually executed | Result |
| --- | --- |
| `dart format --output=none --set-exit-if-changed lib test integration_test` | Pass |
| `flutter analyze --no-pub` | No issues |
| `flutter test --no-pub` | 32 passed, zero skipped |
| `python3 scripts/test_linux_native.py` | 1 native integration test passed: real path-provider/keyring plugins, real SQLite and draft restart |
| `flutter build linux --debug` | Pass |
| `flutter build linux --release --no-pub` | Pass |
| Existing Stage 0 unit/media tests | 15 passed, zero skipped |
| `python3 scripts/check_native_bundle.py apps/native/build/linux/x64/release/bundle` | 14 release files checked; no dotenv asset or literal Groq key |

Final clean-source checks also ran successfully from this repository after copying the scaffold: lockfile-enforced package resolution, analysis, all 32 tests, release compilation, bundle checks and native integration. The resulting Linux release bundle is local ignored build output, not a tracked installer.

The keyring check used a disposable D-Bus session and data directories plus a unique synthetic key that was deleted. Missing-keyring exceptions are also tested for safe handling. No user's API key was included in source, UI state, database, logs or release assets. The app does not import the project .env.

A Windows/Linux baseline GitHub workflow and exact-revision SDK bootstrap helper are authored. **GitHub CI has not run in this session.** Windows native build/key storage and Android/iOS device evidence remain pending; neither templates nor fixtures count as those results. Linux acceptance covers the Stage 1 foundation only, not playlist acquisition/export or installable packaging.

See [STAGE1_GUIDE.md](STAGE1_GUIDE.md) for clean setup, commands, data contracts and platform evidence, and [decision 0002](decisions/0002-native-foundation.md) for the framework boundary. Stage 2's shared interface work may proceed with the verified foundation, while each real media adapter still needs its Stage 0 proof.

## Stage 0/1 code review — 2026-10-12

The implementation plan and all Stage 0/1 handwritten source, tests, setup and CI were reviewed. Fixes address worker cancellation/recovery, stale exports/checkpoints, original metadata retention, asynchronous draft/key state, startup Retry, strict media verification, subprocess/ZIP limits, provider input privacy and conservative cover identity. The SDK bootstrap now rejects tracked SDK modifications.

SQLite schema is now **v3**. New tracks retain original structured metadata through edits; existing v1/v2 tracks retain effective fields and original source titles but do not fabricate unavailable original structured fields. v1-to-current and v2-to-current migrations are exercised.

Actual review checks: **30 Python tests and 48 native tests passed, zero skipped on Linux; 1 real native integration test passed; static analysis and Dart formatting passed; Linux debug/release builds and the 14-file release bundle scan passed.** The three retained full-length live sample MP3s passed strict decoding without another source download. No live Groq/artwork/storage request or new device/platform pass was inferred from mocks. Upstream SQLite DNS was unavailable for the isolated copy; its existing downloaded artifact was reused through the dependency's hash-verified cache without changing pins.

Detailed findings, regression evidence and current boundaries: [CODE_REVIEW_STAGE01.md](CODE_REVIEW_STAGE01.md). Earlier test counts and run measurements above are retained as historical evidence. Windows/GitHub execution and live provider/phone gates remain pending.

## Next actions

Run the prepared Windows native/build checks or GitHub CI and record actual results. Stage 2 fixture work is complete; begin Stage 3 only after the relevant native media proof, and keep mobile gates open. Populate this project's .env with the new Groq key (never paste it in chat), then run one live stable-ID naming check against the retained sample. Supply an identifying MusicBrainz contact for a known-cover test. Continue the Android native execution spike when a toolchain/device is available; retain iOS as explicitly unresolved until it can be built/tested.

For future updates, record stage, implementation revision, commands/results, observed limits and next action. Do not mark a platform or stage done without its stated evidence.

## Stage 2 implementation and acceptance (2026-10-13)

The separate fictional demo demonstrates validated import, explicit progress steps, cancellation/retry, partial/empty/expired/offline states, selected/excluded/failed counts, stable-ID silent preview controls, metadata editing with original titles/versions, explicit Save/Cancel and frozen ZIP/MP3 filename previews. Demo edit/destination failures preserve user input and review. Durable drafts and OS credentials are unchanged. No source/provider request, real playback or device file save is simulated as success.

Shared lavenderblush tokens, white surfaces, 48 px controls and focus treatments are implemented. The full native suite passes **80 tests, zero skipped**, including **32 new regressions**. The layout matrix covers 320/390/768/1024/1440 px and landscape at 100%/200% text; keyboard-inset editing, focus restoration, semantic routes, Flutter target/label/contrast guidelines and palette ratios pass. Rendered fictional screens were reviewed and recorded in docs/stage2/screens. See [Stage 2 guide](STAGE2_GUIDE.md) for entry points and reproducible commands.

`dart format --output=none --set-exit-if-changed lib test integration_test` and `flutter analyze --no-pub` pass. `python3 scripts/test_linux_native.py` passes **1 actual Linux plugin/keyring/SQLite/restart test**, now including the fixture route. `flutter build linux --release` passes; the release scan finds no dotenv/literal Groq key. The unchanged Stage 0 Python suite passes **30 tests, zero skipped** with the project's FFmpeg/ffprobe. Official Linux prerequisites were extracted into /tmp for these checks; no system packages or DOT. files were modified. Flutter/package pins and SQLite schema remain unchanged.

Stage 2 is accepted for its fixture scope. This evidence does not certify actual phone screen readers/keyboards, Windows builds, native acquisition/playback/export, AI identification or online covers. Those gates remain open. No GitHub workflow, external provider call, deployment, commit or push was performed. Stage 3 is next, dependent on the relevant native media proof.
