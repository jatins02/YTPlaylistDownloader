# Project status

Updated: 2026-10-16.

## Current state

**Stage 0 is in progress.** The bounded CLI, tests, dependency pins and optional container/provider probes are implemented. The Stage 1 native foundation is accepted on Linux, and Windows foundation checks now pass in GitHub CI; manual Windows QA and media execution remain unproven. Stage 2’s fictional interface journey is complete. Stage 3 real Linux acquisition/conversion/snippets and recovery and Stage 4 Linux naming/artwork/tag adapters are implemented. Live Groq naming and known public artwork/embedded-cover acceptance pass; other-platform tagging remains unverified. Stage 5 real Linux snippet playback and persistent review/editing are implemented; manual audio/chooser QA and other-platform execution remain open. Device export is Stage 6 and remains unavailable. No cloud resources have been provisioned.

| Stage | Status | Evidence |
| --- | --- | --- |
| 0 — Feasibility | In progress | 58 Python tests pass locally and in CI; source runs and live Groq/artwork checks pass; native device/player/distribution gates open |
| 1 — Native foundation | Linux accepted; Windows CI foundation verified, manual QA pending | GitHub CI: 155 Linux tests, 148 Windows tests (1 symlink test skipped); native plugin/restart checks and debug/release builds pass on both |
| 2 — Design/fixture flow | Complete for fixture UI | Responsive journey; 80 native tests; rendered review; Linux integration/build pass |
| 3 — Device pipeline | Linux accepted; other platform gates open | Real native source/codecs, historical live sample, recovery/quotas/cleanup; review passes 132 native and 41 Python tests |
| 4 — AI/artwork/tags | Linux implementation/live acceptance verified; full platform acceptance open | Review: 172 Flutter / 58 Python tests; native ID3/restart and live Groq/recording/release/front/APIC proof pass; Windows/phone tag execution remains unverified |
| 5 — Review/edit | Linux implementation/native-output acceptance verified; manual/device gates open | Durable revision-safe edits/covers/selections, one bounded native snippet, responsive review; see Stage 5 evidence below |
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

Dependencies/tools were first tested in isolated /tmp locations, then an ignored project-only .venv-stage0 and .tools-stage0/bin were prepared and checked from this folder. Activate .venv-stage0 to run the harness here. No system Python or DOT. environment was changed. Recreate clean-checkout setup using STAGE0_GUIDE.md. Docker, Java/ADB and Xcode are unavailable here. The Stage 1 work used an isolated Flutter 3.47.5 / Dart 3.13.4 SDK and Linux build toolchain; Linux native builds are now verified. No system compiler packages were installed locally. Subsequent Windows CI foundation evidence is recorded below; phone builds remain unverified.

## Pending Stage 0 gates

- Provider account/known-artwork gates are closed by Stage 4's live native checks below: the owner supplied the project Groq key, and the public project URL identifies artwork requests. Quota errors remain gracefully bounded and tested offline; no live quota exhaustion was forced.
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

At initial Stage 1 acceptance, the Windows/Linux workflow and bootstrap helper were authored but CI and Windows native checks had not run. The executed desktop CI results below supersede that pending foundation gate; Android/iOS device evidence remains pending. Linux acceptance covers the Stage 1 foundation only, not playlist acquisition/export or installable packaging.

See [STAGE1_GUIDE.md](STAGE1_GUIDE.md) for clean setup, commands, data contracts and platform evidence, and [decision 0002](decisions/0002-native-foundation.md) for the framework boundary. Stage 2's shared interface work may proceed with the verified foundation, while each real media adapter still needs its Stage 0 proof.

## Stage 0/1 code review — 2026-10-12

The implementation plan and all Stage 0/1 handwritten source, tests, setup and CI were reviewed. Fixes address worker cancellation/recovery, stale exports/checkpoints, original metadata retention, asynchronous draft/key state, startup Retry, strict media verification, subprocess/ZIP limits, provider input privacy and conservative cover identity. The SDK bootstrap now rejects tracked SDK modifications.

SQLite schema is now **v3**. New tracks retain original structured metadata through edits; existing v1/v2 tracks retain effective fields and original source titles but do not fabricate unavailable original structured fields. v1-to-current and v2-to-current migrations are exercised.

Actual review checks: **30 Python tests and 48 native tests passed, zero skipped on Linux; 1 real native integration test passed; static analysis and Dart formatting passed; Linux debug/release builds and the 14-file release bundle scan passed.** The three retained full-length live sample MP3s passed strict decoding without another source download. No live Groq/artwork/storage request or new device/platform pass was inferred from mocks. Upstream SQLite DNS was unavailable for the isolated copy; its existing downloaded artifact was reused through the dependency's hash-verified cache without changing pins.

Detailed findings, regression evidence and current boundaries: [CODE_REVIEW_STAGE01.md](CODE_REVIEW_STAGE01.md). Earlier test counts and run measurements above are retained as historical evidence. Windows/GitHub foundation execution was pending at that review; see the later CI results below. Live provider/phone gates remain pending.

## Next actions

Desktop foundation CI now passes. Perform manual Windows QA and its skipped symlink check before broader platform acceptance. Stage 3 Linux and Stage 4 Linux implementation/live acceptance are verified. Prove Windows media/tag execution, expose an Android SDK/JDK/ADB/USB device path and retain the iOS gate until a Mac/iPhone can be built/tested. Those missing execution paths prevent full Stage 4 acceptance; no access to them exists in this environment. Stage 5 Linux playback/editing is implemented; complete its manual speaker/chooser and platform gates, then implement Stage 6 verified device saving. The owner's configured development key stays in ignored `.env`; native releases continue to use each user's OS vault.

For future updates, record stage, implementation revision, commands/results, observed limits and next action. Do not mark a platform or stage done without its stated evidence.

## Stage 2 implementation and acceptance (2026-10-13)

The separate fictional demo demonstrates validated import, explicit progress steps, cancellation/retry, partial/empty/expired/offline states, selected/excluded/failed counts, stable-ID silent preview controls, metadata editing with original titles/versions, explicit Save/Cancel and frozen ZIP/MP3 filename previews. Demo edit/destination failures preserve user input and review. Durable drafts and OS credentials are unchanged. No source/provider request, real playback or device file save is simulated as success.

Shared lavenderblush tokens, white surfaces, 48 px controls and focus treatments are implemented. The full native suite passes **80 tests, zero skipped**, including **32 new regressions**. The layout matrix covers 320/390/768/1024/1440 px and landscape at 100%/200% text; keyboard-inset editing, focus restoration, semantic routes, Flutter target/label/contrast guidelines and palette ratios pass. Rendered fictional screens were reviewed and recorded in docs/stage2/screens. See [Stage 2 guide](STAGE2_GUIDE.md) for entry points and reproducible commands.

`dart format --output=none --set-exit-if-changed lib test integration_test` and `flutter analyze --no-pub` pass. `python3 scripts/test_linux_native.py` passes **1 actual Linux plugin/keyring/SQLite/restart test**, now including the fixture route. `flutter build linux --release` passes; the release scan finds no dotenv/literal Groq key. The unchanged Stage 0 Python suite passes **30 tests, zero skipped** with the project's FFmpeg/ffprobe. Official Linux prerequisites were extracted into /tmp for these checks; no system packages or DOT. files were modified. Flutter/package pins and SQLite schema remain unchanged.

Stage 2 is accepted for its fixture scope. This evidence does not certify actual phone screen readers/keyboards, Windows builds, native acquisition/playback/export, AI identification or online covers. Those gates remain open. No GitHub workflow, external provider call, deployment, commit or push was performed. Stage 3 Linux evidence is recorded below; other media-platform gates remain open.

## Stage 3 implementation and Linux acceptance (2026-10-14)

The native app has a separate real processing route and a Linux adapter with pinned-runtime verification. It enumerates atomically, preserves all returned positions/duplicate occurrences/unavailable placeholders, acquires unique sources once, strictly decodes and checks full MP3/snippet duration/hash/bytes, and publishes immutable assets under running generation tokens. Source uploader evidence is retained without guessing artists. Schema v4 adds durable enumeration/errors/durations/uploader evidence, explicit active manifests and unmapped-entry selection; historical migrations are unchanged.

Pause, close/restart and explicit retry reuse only verified source/audio boundaries. Ready peers survive failures and keep their IDs/checksums; damaged media is flagged before an explicit rebuild. Cancel fences the database before stopping guarded process groups. OS file-size limits, bounded output, time/duration/count/concurrency/storage/free-space limits, orphan cleanup, 48-hour expiry and cancelled-job private cleanup are implemented. User-exported copies are outside cleanup; tagging/export capabilities remain false.

Actual checks: **110 Flutter tests pass, zero skipped** (104 ordinary + 6 opt-in real-codec cases), **32 Python tests pass, zero skipped**, Linux formatting/analysis/release scan/builds pass, and both foundation and new actual native pipeline/UI/restart integration tests pass in disposable Linux sessions. The live sample first retained two successful peers while one source failed; explicit retry completed all three without reacquiring those peers. Sanitized records are in [STAGE3_RESULTS.json](STAGE3_RESULTS.json); setup/contracts are in [STAGE3_GUIDE.md](STAGE3_GUIDE.md). Native CPU/RAM/battery capacity has not been measured; configured limits are conservative desktop development bounds, not phone capacity claims.

**Linux Stage 3 is accepted. Full multi-platform acceptance remains open.** The owner confirmed an Android phone available by USB; no USB device filesystem, JDK, SDK or ADB is exposed here. No Mac/iPhone is available. Windows process-tree/build/media execution is unverified. No phone adapter, real player, online metadata/artwork or native file-destination save was marked supported, and no paid host, deployment, commit or push was performed. Stage 4 can continue on proven Linux while these platform spikes are pursued separately.

## Review of implemented Stages 0–3 (2026-10-14)

Reviewed the implemented native/CLI source, domain/repositories, controller/UI,
media/process/file lifecycle, provider probes, tests and setup/platform/CI
configuration against the plan and skills. Existing uncommitted work was kept;
dependency pins and historical migrations remain unchanged. See
[findings and regression evidence](CODE_REVIEW_STAGE03.md).

Corrections close readiness and frozen-state bypasses, atomically invalidate
snippets when audio is replaced, recover jobs/export snapshots without surviving
attempts, retain legacy/duplicate occurrence titles and errors, fence starts
after pause/cancel, serialize refresh/retention/cleanup, drain work before
shutdown and retire invalid retained media before explicit retry. Unexpected
errors remain structured and verified peers survive. Startup media filesystem
errors preserve drafts/settings; old credential reads cannot overwrite newer
state.

The CLI now isolates child environments/process groups, caches and extractor loading,
starts short-track snippets correctly and enforces their duration/filename
bounds. Artwork cannot guess among matching release editions. AI missing known
version/clip markers retains original-title fallback and a review flag; naming
requires original source records. Its prompt is `stage0-v2`. The optional image
includes the supervisor asset needed by its copied tests; it was not built.

Final commands/results: **132 Flutter tests pass, zero skipped** (122 ordinary
and 10 opt-in real-codec tests); **41 Python tests pass, zero skipped**;
`dart format --output=none --set-exit-if-changed lib test integration_test tool`
and `flutter analyze --no-pub` pass. Linux debug/release builds pass; the release
scan checks **16 files** without dotenv/literal Groq keys. Both
`python3 scripts/test_linux_native.py` and the opt-in `--test pipeline_test.dart`
pass one actual native test each in disposable sessions. Three fresh
`python -m stage0 synthetic --runs 3` runs pass, each verifying three distinct
fictional MP3s, tags/embedded cover, snippets and ZIP manifests/checksums.
`git diff --check` passes.

The socket-restricted sandbox required scoped execution access for Flutter and
native tests. Missing Linux prerequisites were restored by extracting Ubuntu
packages under `/tmp`; no system installation or sibling-project access occurred.
The tests use the existing pinned runtime, clang 21.1.8, CMake 4.2.3 and Ninja
1.13.2. No live source/provider/storage requests, phone/Windows execution,
Docker build, GitHub CI run, deployment, commit or push was performed.

Next actions remain the Android toolchain/device spike, Windows execution and
the unresolved iOS gate; Stage 4 can proceed on proven Linux with the owner's
securely configured key and identifying artwork contact. This review adds no
Stage 4–9 completion claim.

## GitHub Actions repair — 2026-10-14

The committed Foundation workflow's [run #3](https://github.com/jatins02/YTPlaylistDownloader/actions/runs/38596427291)
failed before native app checks on both runners: Windows could not check out a
long Flutter engine fixture filename; Linux's Dart SDK download stopped with
curl exit 92 (an interrupted HTTP/2 stream). The media job also exposed a real
FFmpeg 6.1.1 compatibility defect: decoder-thread errors can return exit zero
even with `-xerror`.

The Flutter clone now records `core.longpaths=true`. Linux bootstrap uses a
private temporary curl configuration with HTTP/1.1, retries for interrupted
transfers and connection/transfer time limits, without altering the pinned SDK
or the user's curl configuration. Strict Stage 0 probe/decode operations now
reject any error-level stderr even after a zero exit, retaining redacted failure
messages. CI pins and prints the existing Ubuntu codec package
`7:6.1.1-3ubuntu5`; it is a CLI compatibility test runtime, not the verified
Stage 3 native media runtime.

Actual local checks: 43 Python tests pass, zero skipped, with both the exact
Ubuntu FFmpeg 6.1.1 package from the failed run and the project's pinned FFmpeg
8 runtime. The former failure was reproduced before the fix. 132 Flutter tests
pass with the pinned Stage 3 runtime, zero skipped; formatting changes no files
and analysis reports no issues. Bootstrap revision/dirty-checkout rejection and
temporary downloader configuration cleanup are covered by offline regressions.
A completely fresh official Flutter clone and 227.6 MiB Dart SDK download also
pass with the repaired bootstrap (Flutter 3.47.5 / Dart 3.13.4, exact revision).
The owner published the commits through `6cc8bbd280850655e5788743fed59f293e1c625f`.
[Foundation run #4](https://github.com/jatins02/YTPlaylistDownloader/actions/runs/38614867240)
completed successfully on all three jobs (2026-10-14 18:24:20–18:29:15 UTC),
verified on 2026-10-15 locally. Each original failure is resolved; no check was
removed or weakened to obtain success.

| Actual GitHub check | Result |
| --- | --- |
| Media contracts: `.venv-ci/bin/python -m unittest discover -s tests -v` | 43 pass, zero skipped; FFmpeg/ffprobe 6.1.1-3ubuntu5, Python 3.14.4 |
| Linux `flutter test --no-pub` | 122 pass, zero skipped; opt-in real-codec tests are not enabled in CI |
| Windows `flutter test --no-pub` | 115 pass, 1 existing symlink test skipped because creating symlinks requires Windows developer/admin privileges |
| Both SDK bootstraps, enforced package lockfiles, Dart formatting and Flutter analysis | Pass; exact Flutter 3.47.5 revision / Dart 3.13.4 |
| Linux `python scripts/test_linux_native.py` | Actual native plugins, synthetic key storage, SQLite and draft restart pass; debug build passes |
| Windows `flutter test integration_test/foundation_test.dart -d windows` | Actual native plugins, synthetic key storage, SQLite and draft restart pass; debug build passes |
| `flutter build linux --release` and `flutter build windows --release` | Both pass |
| `python scripts/check_native_bundle.py <bundle>` | Linux 16 files / Windows 15 files checked; no dotenv asset or literal Groq key |

Runner images: Ubuntu 24.04 `20261004.327.1` and Windows Server 2022
`20261004.326.1`. Linux installed clang package `1:18.0-59~exp2` and CMake
`3.28.3-1build7`. These are executed CI foundation checks, not real phone,
Windows media, user export, manual desktop QA or distribution evidence. The
Windows symlink test still needs an appropriately privileged execution path.
Android/iOS media/device gates and Stages 4–9 remain open.


## Stage 4 implementation and Linux evidence — 2026-10-15

[Stage 4 guide](STAGE4_GUIDE.md) describes setup, API/transport/identity contracts,
resource bounds, opt-in live checks and exact feature boundaries. Schema **v5**
appends enrichment states, provider cooldowns, bounded artwork cache and public
model/contact settings without changing historical migrations. The personal key
stays in the OS vault; no native dotenv, account library or shared key was added.

The real Linux processing route now attempts naming/artwork after verified
acquisition/conversion/snippets. Every response is validated by exact stable ID;
invalid/unknown replies preserve source fallbacks and review flags. Existing
human field overrides and newer revisions defeat delayed results. Name/art
errors stay separate from source/audio failure. Explicit retries preserve
accepted peers; paused/interrupted enrichment resumes with verified audio.

Front covers require unique recording/release/credited-artist/version evidence
and approved front images. Ambiguous editions, unsupported images and provider
failures remain visible. Public HTTPS destinations/DNS/redirects, deadlines,
response/image/pixel limits, persisted request pacing/cooldowns, verified JPEG
normalization and a 24-hour/16-entry cache bound acquisition. Metadata changes
retire automatic artwork while preserving human cover/removal choices. Cache
expiry and job cleanup do not delete device-exported copies.

The Linux tag adapter creates new full MP3s from immutable metadata/audio/cover
snapshots in private job work directories. It verifies ID3v2.3 title/version,
artists, features, known album, source identity and **exact embedded cover
bytes**, unchanged encoded audio, file checksums and full decoding/duration.
Equal titles retain distinct source audio and IDs. `canTag` is enabled only with
the pinned Mutagen 1.48.1/Pillow 12.3.0 runtime; `canExport` remains false.
No real playback/editor, completed ZIP publication or device transfer was added.

Initial offline checks and subsequent acceptance results are recorded in
[STAGE4_RESULTS.json](STAGE4_RESULTS.json). The table below is the initial
offline implementation record; final follow-up counts appear below it.

| Actual local check | Result |
| --- | --- |
| `flutter test --no-pub` without `STAGE3_TEST_RUNTIME` | 146 pass, zero skipped; default offline CI path |
| `STAGE3_TEST_RUNTIME=<pinned manifest> flutter test --no-pub` | 163 pass, zero skipped: 146 ordinary + 17 actual-codec cases |
| `.venv-stage0/bin/python -m unittest discover -s tests -v` | 47 pass, zero skipped, independently with project FFmpeg 8 and CI FFmpeg 6.1.1-3ubuntu5 |
| `dart format --output=none --set-exit-if-changed lib test integration_test tool` | 65 files checked, zero changes |
| `flutter analyze --no-pub` | No issues |
| `python3 scripts/test_linux_native.py` | Foundation native plugins/keyring/SQLite/restart: 1 pass |
| `python3 scripts/test_linux_native.py --test pipeline_test.dart` | Real-codec native pipeline/UI/restart: 1 pass with pinned runtime |
| `python3 scripts/test_linux_native.py --test enrichment_test.dart` | Native keyring/provider boundary/UI/image/ID3/restart: 1 pass with pinned runtime and fictional providers |
| `flutter build linux --release` | Pass; native tests also build debug |
| `python3 scripts/check_native_bundle.py apps/native/build/linux/x64/release/bundle` | 17 files checked; no dotenv asset or literal Groq key |
| `dart run tool/media_smoke.dart` | Existing standalone Stage 3 synthetic harness: pass, 3 ready tracks |
| Live-tool preflight without `--live`, Python compilation and `git diff --check` | Expected live refusal; compilation and whitespace checks pass |

Source/provider
fixtures are fictional; actual images/codecs/keyring/SQLite/MP3 readback are
executed on Linux. The development live tool refuses to run without `--live`,
keeps keys off argv/child environment/reports and evaluates known/modified/
unknown naming quality without turning failed outcomes into success.

The owner initially chose offline checks, then explicitly requested the
remaining live acceptance and supplied a Groq key in this project's ignored
`.env`. The following execution evidence supersedes the deferred-live status.

## Stage 4 live acceptance follow-up — 2026-10-15

`.venv-stage0/bin/python scripts/test_stage4_live.py --live` exits **0**:
`acceptance_passed=true` and `quality_passed=true` on **openai/gpt-oss-120b**,
native prompt `native-stage4-v1` / response schema `1`. The configured account
accepts the strict request. Stable-ID mapping, known Get Lucky title/Daft Punk/
Pharrell Williams/Nile Rodgers fields, slowed/reverb preservation and explicit
unknown-source review/empty artist arrays all pass. Ambiguous artwork for those
benchmark songs remains honestly uncertain.

The independent known-cover check and combined run both pass through the
production artwork adapter: **Foley — Patricia Taxxon / Foley Artist**, recording
`7af784a9-2bd1-4a11-8712-6c2432f17b0b`, release
`db3b609d-3383-4675-af4c-fd5023c42367`. The approved front normalizes to a
500×500, 57,618-byte JPEG, and its exact embedded APIC bytes and full audio
decoding verify in a synthetic MP3. No actual song was downloaded for this
artwork/tag check, and all temporary media was removed. Sanitized evidence is
in [STAGE4_LIVE_RESULTS.json](STAGE4_LIVE_RESULTS.json).

Live execution exposed and fixed two defects that fictional transport replies
could not reveal: Dart's custom `HttpClient.connectionFactory` required an
explicit TLS handshake with original-host certificate/SNI verification; CAA's
index advertised legacy HTTP image links that now reconstruct to trusted HTTPS
before any request. Regression tests execute real local TLS, wrong-host rejection
and handshake cancellation. Capped MusicBrainz release subqueries lacking a
total count stay uncertain, and canonical provenance omits empty query/fragment
separators. The live tool now requires distinct naming and known-cover/readback
success, supports key-free `--live --artwork-only`, and rejects a wrong known
title or an uncertain/undecoded cover as acceptance evidence.

Final verification: **170 Flutter tests pass, zero skipped** (153 ordinary + 17
opt-in actual-codec cases); the default CI path separately has **153 pass, zero
skipped**. **50 Python tests pass, zero skipped** with both pinned project FFmpeg
8 and isolated CI FFmpeg 6.1.1-3ubuntu5. Formatting checks 67 Dart files with zero
changes; analysis reports no issues. The affected actual Linux enrichment native
integration passes (1 test), debug and release builds pass, and the rebuilt
16-file release scan finds no dotenv asset or literal Groq key. Earlier foundation
and pipeline native passes remain recorded in the initial evidence. Python
compilation and `git diff --check` pass.

**Remaining Stage 4 gate:** actual Windows/Android/iOS media/tag execution and
tag/cover readback. No Windows runtime, Java/Android SDK/ADB/USB path or Mac/iPhone
is available here; those tests remain unexecuted and corresponding media/tag
capabilities stay disabled. Live quota exhaustion was not forced; bounded
429/cooldown/provider-failure behavior passes offline tests. This completes
Linux Stage 4 implementation and live provider acceptance, not full platform
acceptance, player/device QA or a new GitHub CI run. Stages 5–6 retain playback/editing and verified export/destination
publication responsibilities. Publication evidence is recorded separately below.

## Review after Stage 4 — 2026-10-15

[Review findings](CODE_REVIEW_STAGE04.md) document the inspected scope and fixed
artwork transaction, settings read, decoded cover, legacy artwork identity and
CLI prompt/completion issues. Final actual checks: **172 Flutter tests pass, zero
skipped**, including 17 real-codec cases; the default CI path separately has
**155 pass, zero skipped**. **58 Python tests pass, zero skipped** with each of
the project FFmpeg 8 and CI FFmpeg 6 runtimes. Formatting checks 67 files with no
changes, analysis reports no issues, all three actual Linux native integrations
pass, and debug/release builds pass. The 16-file rebuilt release scan finds no
dotenv or literal Groq key. Python compilation and whitespace checks pass.

The owner authorized a local commit, push to origin/main and observation/fixing
of GitHub workflows without further input. Code and review evidence are locally
committed as `7c5b6d8e7e4f03a038a603b33a9bf8b09e7cf00e` (55 files). The working
tree was clean after that commit; `.env` and the configured key were excluded.

Initial publication attempts were blocked by authentication/access: HTTPS Git has no
noninteractive credentials; SSH, after strict verification against GitHub's
official published host key, returns `Permission denied (publickey)`; the GitHub
connector's create-blob request returns HTTP 403 `Resource not accessible by
integration`. The signed-in browser could stage four root files, but automatic
approval review rejected committing that partial subset because it would create
an incomplete repository state rather than publish the tested full commit.
That upload draft was cancelled without committing. The atomic browser-editor
alternative failed GitHub sign-in (`No auth flow succeeded`). No credentials,
account permissions or remote branch settings were changed.

At that point remote main remained at `6cc8bbd280850655e5788743fed59f293e1c625f`
and Foundation run #4 was only historical baseline evidence. The owner then
explicitly approved ordered browser commits, including temporary intermediate
states on main, to publish all 55 reviewed files.

## Stage 4 publication and CI — 2026-10-15

All 55 reviewed files were published through 18 browser commits, ending at
`2a87a1aa60255fe02703969b3114b09fa3eeb049`. A missing documentation upload was
detected by the tree comparison and republished before final acceptance.
`git fetch origin main` and `git diff --exit-code HEAD origin/main` confirmed
that the complete published tree exactly matched local reviewed commit
`673e8f3`: both tree hashes were `8e21bf2fc90420f6141d657c67c3b6854b44f328`.
The original local implementation/status commits remain preserved on
`review/stage4-local-673e8f3`; local main was aligned with the identical published
tree without changing project files or rewriting remote history.

[Foundation run #22](https://github.com/jatins02/YTPlaylistDownloader/actions/runs/38772441828)
passed all three jobs on the complete published revision. Actual CI results:

| Job | Result |
| --- | --- |
| Native foundation (Linux, Ubuntu 24.04) | 155 tests pass, zero skipped; native SQLite/keyring/restart integration passes; debug/release builds pass; 17 release files pass credential/asset scan |
| Native foundation (Windows Server 2022) | 148 tests pass, one existing symlink test skipped; native SQLite/secure-storage/restart integration passes; debug/release builds pass; 16 release files pass credential/asset scan |
| Existing media contracts (Ubuntu 24.04, exact CI FFmpeg 6.1.1-3ubuntu5) | 58 Python tests pass, zero skipped |

Both native jobs enforce the committed dependency lockfile, format 67 files
without changes and report no analysis issues. The Windows symlink skip requires
elevated/developer-mode filesystem privileges; it is not a passed test. The
pinned checkout action emits a Node.js 20 deprecation warning while GitHub runs
it on Node.js 24; all checks pass, so no unrelated action/dependency upgrade was
made. Earlier runs from the approved intermediate publication were superseded
by this complete revision; their results are not final acceptance evidence.

No additional code changes were needed after complete publication. This status
update records the successful run; its own push triggers the unchanged workflow
again and must also be checked before reporting the final branch green. Native
media/tag execution on Windows, Android and iOS, actual player/device-save QA,
and the Stage 5–6 work remain open as documented above.


## Stage 5 implementation and Linux acceptance (2026-10-16)

The real processing route now exposes one gesture-started private snippet at a time, pause/resume, bounded seeking, explicit Stop and lifecycle suspension handling. Stable track/asset IDs preserve playback through renaming. The Linux adapter verifies the pinned FFmpeg PulseAudio output and a local Unix socket before enabling playback, verifies private snippet bytes/decoding and supervises bounded output. A fixed private PulseAudio client configuration disables shared memory/memfd/autospawn without relaxing existing file limits.

Review uses durable revision-checked `review` attempt tokens in schema v5. Explicit Save atomically applies only changed human fields and the cover choice; Cancel/Escape discards uncommitted text. Failed saves retain text/image choices, and stale revisions require explicit rebase followed by Save, preserving untouched newer fields. Interrupted editors recover as cancelled attempts without requeuing verified audio. Human cover import/removal/selection uses verified private assets; original source titles and portable filename previews remain visible. Unique-track and unmapped-entry inclusion persists across restart. Pending edits/preparation, selected unavailable entries and review warnings remain visible, and final Save to Device stays disabled until Stage 6 publication/transfer exists.

| Command/check actually executed | Result |
| --- | --- |
| `dart format --output=none --set-exit-if-changed lib test integration_test tool` | 79 files; no changes required |
| `flutter analyze --no-pub` | No issues |
| `STAGE3_TEST_RUNTIME=<pinned manifest> flutter test --no-pub` | 199 passed, zero skipped; includes 17 opt-in real-codec/image/tag cases |
| `flutter test --no-pub` without runtime opt-in | 182 passed, zero skipped |
| `STAGE5_SCREENSHOTS=<private output> flutter test --no-pub test/review_widget_test.dart` | 11 passed, including opt-in readable UI renders |
| `scripts/test_linux_native.py --test foundation_test.dart`, `pipeline_test.dart`, `enrichment_test.dart` | 1 actual native integration case passed for each |
| `scripts/test_stage5_audio.py` with pinned runtime and private PulseAudio 17.0 | 1 actual native review/output integration case passed |
| `flutter build linux --release --no-pub` | Pass |
| `scripts/check_native_bundle.py apps/native/build/linux/x64/release/bundle` | 18 release files; no dotenv asset or literal Groq key |
| `.venv-stage0/bin/python -m unittest discover -s tests -v` with project FFmpeg | 58 passed, zero skipped |

Native review acceptance uses real SQLite, the OS vault with a unique fictional credential, the pinned FFmpeg/image/tag workers and a disposable local PulseAudio server/null sink. Captured PCM distinguishes equal-title 440/880 Hz tracks, verifies bounded completion, switching and pause, and confirms renaming keeps preview bytes/IDs. Invalid cover Save leaves metadata untouched; retrying valid bytes succeeds. Human cover APIC bytes survive full-MP3 readback, and edits/removal/selection/recovery survive restart. Fictional providers make no live requests and do not use the owner's `.env` key.

Widget tests cover 320/390/844-landscape/768/1024/1440 px, long Unicode metadata, 200% text, keyboard insets, explicit focus restoration, retained failed/conflicted text, chooser cancellation and suspension without autoplay. They wait for observable asynchronous results rather than assuming fixed disk latency. Reviewed [desktop](stage5/screens/review-desktop.png), [phone review](stage5/screens/review-phone.png) and [phone editor](stage5/screens/editor-phone.png) renders use fictional stored records; they do not prove physical phone behavior.

The only new direct Flutter dependency is exact `file_selector: 1.1.0`; the lockfile and Linux/Windows generated registrants are committed. Flutter/Dart/media pins remain unchanged. PulseAudio acceptance exercised official package `1:17.0+dfsg1-2ubuntu4` in an isolated extracted toolchain; no system audio service, global packages, cloud infrastructure or DOT. files were changed. See [STAGE5_GUIDE.md](STAGE5_GUIDE.md) and [STAGE5_RESULTS.json](STAGE5_RESULTS.json).

Stage 5 is accepted for the exercised Linux implementation and private native-output scope. Physical-speaker listening, manual OS image-chooser interaction, screen-reader/device keyboard QA and Windows/Android/iOS media/playback remain unverified. No Android SDK/JDK/ADB/USB or Mac/iPhone execution path is available here. Independent-phone requirements remain in scope. Stage 6 complete tagged-file/ZIP publication and destination transfer remain unimplemented. GitHub publication and fresh CI evidence will be recorded after the tested change is uploaded.
