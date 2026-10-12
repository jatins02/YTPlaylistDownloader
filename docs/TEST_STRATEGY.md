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

Keep downloaded media, private links, credentials and runtime reports ignored. Commit sanitized evidence summaries only when desired. Live API calls never run automatically in ordinary CI. Type/build tests for the future native project begin once its framework/toolchain is selected; no native CI is claimed yet.
