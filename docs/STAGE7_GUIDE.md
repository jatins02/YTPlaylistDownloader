# Stage 7: lifecycle, accessibility and capacity QA

Stage 7's repeatable Linux QA and accessibility corrections are implemented.
**Full Stage 7 acceptance remains open.** The plan requires real download,
edit, save, playback and recovery evidence on every claimed media platform.
No Android/iPhone media adapter, physical screen-reader result, manual save-panel
result or battery claim is inferred from desktop automation. Stage 8 packaging
and distribution are not started by this work.

## Device and execution matrix

| Target / environment | Evidence available | Remaining Stage 7 gates |
| --- | --- | --- |
| Linux x64 development host, Ubuntu 26.04.1, kernel 7.0.0-38-generic | Exact Flutter 3.47.5 / Dart 3.13.4; pinned Python 3.14.4, FFmpeg n8.1.3-17-gc389840894-20261011, Mutagen 1.48.1 / Pillow 12.3.0; actual synthetic codecs, full tags/ZIP/destination bytes, SQLite reopen, native plugins and isolated audio output | Manual chooser, physical player/speaker, desktop screen reader, physical keyboard/display interaction, battery attribution and fresh live-source smoke |
| Windows x64 / Windows Server 2022 CI | Foundation/widget tests, native foundation restart and release build; CI is not a personal Windows device | Media/tag/playback/document execution, manual accessibility, lifecycle, capacity and battery |
| Android | Unverified template; owner has a phone, but no USB path, JDK, SDK or ADB is exposed here | Independent media/document adapter proof, actual device/OS version, screen reader, orientation/keyboard, suspension/storage/network/battery and capacity |
| iPhone | Unverified template; no Mac/Xcode/iPhone available | Independent media/document adapter, real-device accessibility/lifecycle/capacity/battery and zero-budget distribution proof |

Dependency pins, schemas, media limits and platform capability switches are
unchanged. A headless native integration run is real Linux plugin execution,
with an injected chooser/private audio sink; it is not a physical-device pass.
Exact observations and measured values are in [STAGE7_RESULTS.json](STAGE7_RESULTS.json).

## Accessibility corrections and checks

- Real Play/Pause, Edit and Save MP3 buttons expose both action and song/file
  identity in the actionable semantic label. The seek slider identifies its track
  and announces bounded snippet position. The visible compact labels remain.
- Startup/draft/playlist/cover/export indeterminate progress respects reduced motion:
  it becomes a static labeled hourglass, never an invented completion percentage.
- Native review and settings dialogs have zero-duration transitions when reduced
  motion is requested. Loading state and completion/failure remain available.
- Real review/save controls pass Flutter's Android/iOS target-size, labeled-target
  and text-contrast guidelines. These are measured widget guidelines, not
  TalkBack/VoiceOver/Orca certification.
- Keyboard Enter opens the real revision-safe editor; Escape cancels without
  committing changes and returns focus to its initiating action. Orientation
  changes retain unsaved field text. Tests use portrait/landscape at 200% text.
- The existing real review/export matrix also exercises 320, 390, 768, 1024 and
  1440 widths, landscape, long Unicode names, keyboard insets and missing covers.
  Fixture renders remain isolated from durable processing.

## Lifecycle and failure evidence

The real screen receives inactive, hidden, paused and detached lifecycle events
in binding tests. Each stops the current snippet and returning to resumed never
autoplays. This is injected lifecycle evidence; it cannot establish what a phone
OS allows in the background. Native audio tests separately exercise the actual
pinned decoder and private output socket.

Synthetic source loss produces a visible failed track while verified peers keep
their asset IDs and hashes. Explicit retry downloads only the failed track and
does not enumerate again. A deliberately impossible free-space reserve exercises
the actual `df` budget check without filling the host's disk. It stops before
acquisition, preserves other jobs and resumes with normal capacity restored.
This is fault injection, not a physical network-radio toggle or disk exhaustion.

Each measured load performs acquisition/conversion/snippets, human metadata
edits, full tagged derivatives, duplicate-name allocation, complete ZIP/manifest
verification and actual external ZIP/MP3 byte transfer. It closes/reopens SQLite,
recovers attempts, verifies the frozen publication/receipt and committed names,
then removes private media and verifies the external copy survives.

Keep the app open for acquisition, enrichment and file preparation/transfer.
Desktop inactivity need not stop processing while the process can run; suspended
or terminated execution cannot be promised. Close/Stop drains and fences work;
restart uses verified local boundaries. No resume action starts playback without
another gesture. Never interrupt the owner's real jobs for QA: tests use their
own temporary database, keyring, media, audio socket and destinations.

## Reproduce automated QA

Use the existing exact SDK, official Linux prerequisites and pinned manifest from
Stages 1–6. Do not load `.env` or enable providers for these commands.

```bash
cd apps/native
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze --no-pub
flutter test --no-pub
STAGE3_TEST_RUNTIME=/absolute/path/media-runtime.json \
  flutter test --no-pub --concurrency=1
STAGE3_TEST_RUNTIME=/absolute/path/media-runtime.json \
  STAGE7_QA_OUTPUT=/absolute/test-output-directory \
  flutter test --no-pub test/stage7_capacity_test.dart --concurrency=1
```

A fresh live source smoke requires a separate, permitted small public playlist:

```bash
STAGE3_TEST_RUNTIME=/absolute/path/media-runtime.json \
  STAGE7_QA_OUTPUT=/absolute/test-output-directory \
  STAGE7_LIVE_PLAYLIST='https://youtube.com/playlist?list=YOUR_PUBLIC_LIST_ID' \
  flutter test --no-pub test/stage7_source_smoke_test.dart
```

This explicit live check uses the real bounded source adapter, reports only
counts/timing and does not load `.env` or call naming/artwork. It is not part of
ordinary CI. No playlist was supplied for a fresh Stage 7 live run; historical
Stage 3 source evidence remains historical, and this gate is recorded pending.

The extra opt-in writes one sanitized JSON result per load (3 × 65 seconds,
10 × 65 seconds and 1 × 600 seconds). It also runs source-loss/space recovery.
It makes no live source, Groq or artwork request and reads no owner key.
Run measurements sequentially on an otherwise idle host; concurrent native
builds/media tests distort timing and can exceed existing test deadlines.

From the repository root, run the affected actual native checks:

```bash
python3 scripts/test_linux_native.py --test foundation_test.dart
python3 scripts/test_linux_native.py --test pipeline_test.dart
python3 scripts/test_linux_native.py --test enrichment_test.dart
python3 scripts/test_linux_native.py --test export_test.dart
# PulseAudio 17.0: existing helper uses its own private socket and synthetic sink.
python3 scripts/test_stage5_audio.py
```

The media checks require `STAGE3_TEST_RUNTIME`; the audio helper accepts explicit
official extracted binary/module paths as documented in Stage 5. No normal
desktop audio service, microphone or user keyring is used.

## Measurement interpretation and capacities

The Linux sampler reads this test process and descendants across all spawning
threads every 100 ms. CPU is the observed incremental process ticks; short-lived
workers can escape sampling, so it is a lower bound. Summed RSS counts shared
pages more than once and includes the Flutter test VM, SQLite and instrumentation.
Sampled private/destination storage peaks may miss transient writes. Storage
is summed logical file length, not allocated blocks; two hard links can count
the same inode twice. Wall time
includes verification, transfer and reopen; tool startup verification before the
load and final discard are excluded. These are instrumented development-runtime
measurements, not release frame timing or uniquely attributed physical RAM.

Three finite loads establish measured examples at the current ten-track and
ten-minute individual-duration boundaries. They do not prove the full Cartesian
maximum of ten ten-minute maximum-size source files, 100 production tracks, phone
capacity, thermal behavior or minimum free storage on every filesystem. Keep the
existing conservative limits: ten unique tracks, 600 seconds/track, 50 MiB/media
file, 512 MiB/job, 1 GiB/workspace and 64 MiB free-space reserve. Do not raise caps
from these measurements. Lower them on another device only after its own QA.
Battery attribution is unavailable on this shared host; no zero-drain or battery
life estimate is reported.

## Required manual/device acceptance

For each target, record exact hardware/OS/build/runtime versions and whether the
run is physical, emulator, simulator or headless. Retain sanitized observations,
counts/checksums and measured outcomes, not keys, signed links or user file paths.

1. Independently import a permitted small public playlist, process, listen, edit,
   choose a cover/removal, save ZIP and MP3 through the real OS panel and open
   them in a local player. Check full durations, Unicode/version names, equal-name
   audio and embedded cover bytes. A missing phone adapter keeps this gate open.
2. Use keyboard/focus and the platform screen reader through import, partial
   failure, review, editor and save, at large text and orientation changes.
   Verify each action's song identity and one-time major-status announcements.
   Enable reduced motion and verify static unknown progress/dialog behavior.
3. Background/lock/suspend and restart during download, conversion, editing,
   export preparation and transfer. Check that committed edits/verified peers
   survive, partial copies are not success and playback never autostarts.
4. Toggle the real network, deny/cancel the real destination picker, use a safe
   low-space test volume and interrupt a test-owned transfer. Retry explicitly;
   confirm no existing external copy is overwritten or removed.
5. Measure RAM, CPU, peak private/destination bytes, UI frame responsiveness,
   wall time, thermals and battery on controlled power with a comparable idle
   baseline and repeated runs. Record sample intervals and instrumentation.
   Confirm or lower initial capacities without changing the independent-phone
   requirement. A simulator or shared-host energy delta is insufficient.

Until those gates are evidenced, Stage 7 remains partial and the app must not be
advertised as supported on unverified media platforms. No purchases, hosting,
store release or laptop companion substitution is part of this stage.
