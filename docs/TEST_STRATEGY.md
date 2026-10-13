# Verification strategy

Revised for independent native devices and zero budget. Current desktop harness tests are evidence for core contracts only; they cannot prove phone operation.

## Current checks

Run `python -m unittest discover -s tests -v` with real FFmpeg/ffprobe. Tests cover safe URL normalization, ID-based model mapping, missing/extra/duplicate records, unknown artists, version preservation, Unicode/case collisions, image validation, credential redaction, real tag/cover readback, full-audio decoding and corrupt/incomplete ZIP rejection. Synthetic fixtures are generated, never copied from DOT.

Run `python -m stage0 synthetic --runs 3` for repeatable local correctness. Live source/provider checks are opt-in. Use the supplied playlist for three fresh source runs and the configured Groq key for one independently validated metadata request. A known cover requires title/artist/album and verified recording/release evidence.

## Acceptance matrix

| ID | Required evidence | Gate |
| --- | --- | --- |
| N01 | Three fresh real playlist runs; all three distinct tracks decode and export | 0 |
| N02 | Actual Groq response matches exact stable IDs; malformed replies rejected/fallback visible | 0, 4 |
| N03 | Known online recording/release/front-cover match and embedded-image readback | 0, 4 |
| N04 | Actual Android independently acquires/converts/saves sample; no laptop/backend | 0, 3, 6 |
| N05 | Actual iPhone independently acquires/converts/saves sample; native runtime path documented | 0, 3, 6 |
| N06 | Laptop app packages and exports without global-tool assumptions | 0, 8 |
| N07 | Durable private state, restart/retry, generation fencing and cancellation | 1, 3 |
| N08 | Duplicate title/source, ordered positions, failed items and Unicode names | 3, 6 |
| N09 | Human edits beat delayed AI, persist on restart and block save while pending | 4, 5 |
| N10 | Snippets are bounded and never overlap; edits preserve playback identity | 5 |
| N11 | Full tagged MP3/cover/ZIP integrity and unique names through real device export | 6 |
| N12 | Picker cancellation/permission denial/low storage produce recoverable behavior | 6, 7 |
| N13 | Narrow/landscape/tablet/laptop, keyboard, large text, focus/contrast/screen reader | 2, 7 |
| N14 | OS suspension/force-stop, network loss, source/provider outage and resource limits | 3, 7 |
| N15 | Credentials absent from code/binaries/logs; user keys in secure storage | 1, 8 |
| N16 | Clean install/update/rollback and viable distribution route per platform | 8 |
| N17 | Owner completes released-platform workflow; support claims match evidence | 9 |

Record devices/OS/runtime versions, commands, revisions, sample durations/bytes and observed outcomes. Android/iOS emulator/simulator results supplement but do not replace actual phone export/playback tests. No Mac/iPhone access means N05 is outstanding, not passed.

## Benchmarks and reports

CLI reports contain per-phase times, sampled process-tree RSS/CPU and scratch peaks. Payload-byte counts exclude protocol/retry overhead where stated; unknown values remain null. Short synthetic clips are not a production capacity estimate. Measure on-device CPU/memory/storage/battery and background behavior before setting final limits.

Keep downloaded media, private links, credentials and runtime reports ignored. Commit sanitized evidence summaries only when desired. Live API calls never run automatically in ordinary CI. The pinned native project has local checks and a baseline Linux/Windows CI workflow. Workflow authorship does not establish an executed CI result.

## Stage 1 foundation checks

Run `dart format --output=none --set-exit-if-changed lib test integration_test`, `flutter analyze --no-pub` and `flutter test --no-pub` from apps/native. The real SQLite suite covers v1-to-v2 upgrades, persisted revisions/overrides, source occurrences, ID-based ownership, interrupted generations, fenced asset registration and frozen exports. Widget checks exercise actual controller/database draft saving, invalid input and a 320px layout at 2x text scale. Secure-storage failure tests sanitize native exceptions.

The native integration test uses registered path-provider/secure-storage plugins, a temporary database and a unique synthetic key, then checks draft persistence after close/reopen. Use `python scripts/test_linux_native.py` for an isolated Linux display/keyring or `flutter test integration_test/foundation_test.dart -d windows` on Windows. Tests never replace the user's stored key or access DOT. Both debug and release compilation are required. Keep Windows/phone results pending until actual execution; GitHub workflow authorship is not a passing run.

## Stage 0/1 review regressions

`tests/test_review_regressions.py` covers fast subprocess output, nonfinite/corrupt audio, duplicate empty query parameters, archive quota/concurrent publication, prompt allowlisting, featured-credit/ambiguous cover matching, provider deadlines, client cleanup/rollback, CPU baselines and optional provider dependencies. Providers and object storage are mocked; these checks authorize no real upload/deletion.

`apps/native/test/review_regression_test.dart` covers original metadata and v2 migration, cancelled/stale attempts, checkpoint ownership, preserved playable peers, per-job recovery revisions, obsolete export checkpoints, stale/corrupt/ambiguous snapshots and asynchronous draft/key races. `startup_widget_test.dart` exercises Retry and large-text landscape failures. Exact current results are in PROJECT_STATUS.md.

## Stage 2 fixture checks

`fixture_journey_test.dart` exercises deterministic phases, identities/occurrences, recovery, failed selection, revision-checked edits, preserved source titles/versions, immutable save previews, duplicate-name distinction and one bounded silent preview. `fixture_widget_test.dart` uses actual Flutter controls across six viewport sizes at 1x/2x text, keyboard insets, Tab/Enter/Escape and semantic/contrast/target guidelines. `foundation_widget_test.dart` verifies demo actions leave the actual temporary SQLite store and personal-key state untouched. The native integration test also opens/closes the fixture route through the real app.

Ordinary tests make no network/provider requests and generate no screenshot artifacts. Opt-in `--dart-define=STAGE2_PREVIEWS=true --plain-name 'rendered evidence'` generates reviewable PNGs with SDK fonts in ignored build output. Reviewed fictional screenshots and the scope of automated accessibility evidence are in [STAGE2_GUIDE.md](STAGE2_GUIDE.md). Actual TalkBack/VoiceOver and device keyboard/export checks remain outstanding.
