# Stage 5: real snippets and persistent review

Implemented for the verified Linux development runtime on 2026-10-16. Real
playback, metadata/cover editing and include/exclude controls use durable jobs
and private assets. The fictional Stage 2 journey remains separate. Final MP3/ZIP
publication and destination transfer are now implemented for Linux in
[Stage 6](STAGE6_GUIDE.md); their platform/manual gates remain separate.

## Use the real review

Follow [Stage 3](STAGE3_GUIDE.md) and [Stage 4](STAGE4_GUIDE.md) runtime setup.
After processing a playlist, the same screen shows ready snippets and review
controls, the original source titles, failures and selection counts.

- **Play snippet** starts only after a gesture. A second track stops the first;
  equal names never identify audio. The player supports pause/resume, seeking
  within the prepared snippet and Stop. It never plays the full source file.
- **Edit track** opens explicit Save/Cancel fields for title, artists, features,
  album/version and review confirmation. Names remain Unicode and untruncated;
  the portable filename preview is bounded, while final collision allocation
  remains Stage 6. Unknown artists keep a review flag.
- **Choose image** uses the native file chooser. Input is bounded to 5 MiB;
  the guarded worker rejects invalid/oversized decoded images and normalizes
  accepted covers to verified JPEGs up to 768 pixels per axis and 1 MiB.
  Previously verified covers for the same track can also be chosen. **Remove
  cover** is a deliberate persistent human override.
- Save applies metadata and cover changes atomically. Failures retain editor
  text and cover choice. Conflicts require the explicit **Apply my edited fields
  to the latest revision** action, followed by Save; untouched newer fields stay
  intact. Cancel, Escape or chooser cancellation do not silently save anything.
- Include/exclude applies to a unique track and all repeated occurrences.
  Unmapped unavailable entries have their own explicit selection. Selected,
  excluded and unavailable counts and pending/review-warning reasons remain
  visible before finalization. Excluding an item never deletes its private audio.

Leaving the screen, suspending the app or starting processing stops native output.
Returning never autoplays. Committed edits, cover overrides and selection survive
restart. An interrupted editor is cancelled on restart; its uncommitted text is
not represented as saved. Expiry/cancellation may invalidate private media but
preserve metadata and any future external user copies.

## Linux audio output

The pinned project FFmpeg already includes PulseAudio output, verified again at
adapter startup before enabling playback; no additional
Flutter audio dependency or remote service is used. Playback targets only a
local Unix socket, normally `$XDG_RUNTIME_DIR/pulse/native`, compatible with a
desktop PulseAudio server or PipeWire's PulseAudio service. If output is absent
or fails, playback stays unavailable/visible and edits remain usable. Start the
local audio service and reopen the review to refresh its capability. Other
platform playback adapters remain unavailable pending their own execution proof.

The development/test override `YTPD_AUDIO_SOCKET` accepts an absolute Unix socket
path, never a TCP server. Each supervised audio client uses a private fixed
configuration disabling shared memory, memfd and server autospawn. This avoids
PulseAudio's large shared-memory allocation without raising Stage 3 file limits.
The current manifest, checksum/byte length, MP3 decode and bounded duration are
checked before playback; generation checks prevent stale starts/progress.

## State and concurrency

Review uses the Stage 4 v5 tables; current schema v6 adds Stage 6 publication/
delivery records. The stage column supports `review` without rewriting migrations.
A running editor token blocks export freezing. Save requires that token, its captured/rebased revision and the current
track. User images publish in the same transaction as the edited metadata;
discarded/failed candidates remain private and are cleaned safely. Only changed
fields gain human override precedence. Provider suggestions cannot overwrite
saved human fields or a human cover/removal choice.

Native playback replacements wait for old output to terminate. Media preparation,
close and cancellation stop supervised playback; retention skips an active short
preview, open review token or image save and retries later. The open-token check
and expiry decision share one transaction. Play/seek controls wait for active
export, preparation or cancellation; Stop remains available. Late pause/seek
results cannot overwrite a newer playback request. Renaming metadata leaves the
immutable track/audio/preview asset IDs and bytes intact. No control freezes an export to
bypass pending edits or declares a device save complete.

## Verification

Use the exact SDK and project-only environment described in the earlier guides.
The normal suite exercises transactional review, failures/conflicts, restart,
selection, playback races, suspension, large text and keyboard layouts. Runtime
media/image/tag cases remain opt-in via `STAGE3_TEST_RUNTIME`.

```bash
cd apps/native
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze --no-pub
flutter test --no-pub
```

Actual Linux review/audio acceptance needs the pinned media manifest, Linux
native build prerequisites from Stage 1 and **PulseAudio 17.0**. The helper starts
a disposable server, private D-Bus session, null output sink and mode-0700 Unix
socket. It never touches the normal desktop server or records a microphone.

```bash
export STAGE3_TEST_RUNTIME="$PWD/.tools-stage3/media-runtime.json"
.venv-stage0/bin/python scripts/test_stage5_audio.py
```

For an official package extracted without installing system software, supply
`--pulse-binary /absolute/path/pulseaudio` and `--module-directory
/absolute/path/modules`, with its private core libraries on `LD_LIBRARY_PATH`.
The exercised package is `1:17.0+dfsg1-2ubuntu4`; Flutter 3.47.5/Dart 3.13.4 and
the existing exact FFmpeg/runtime pins remain unchanged. The only new Flutter
direct dependency is official `file_selector: 1.1.0`, with the full lockfile.

The native test processes fictional equal-title 440/880 Hz tones, captures PCM
from that private sink and verifies their distinguishable output and bounded
completion. It also checks immutable audio during renaming, pending-edit export
blocking, user-image normalization/embedded APIC readback, corrupt-preview
rejection and durable edits/selections/cover overrides after restart. Provider
responses and the keyring credential are fictional; no live request or owner key
is needed. Actual command results and CI are recorded in [status](PROJECT_STATUS.md).

Screenshot generation is opt-in with `STAGE5_SCREENSHOTS=/absolute/output/path`
when running `test/review_widget_test.dart`. The readable renders load only fonts
already bundled in the pinned SDK. These are stored-record UI tests with
fictional data, not physical phone or native audio evidence.

## Remaining gates

Windows/Android/iOS media/playback execution remains unverified and disabled.
Linux private-sink capture proves native decoder/output operation, not physical
speaker listening. Manual OS file-chooser interaction, physical-speaker listening
and phone/device keyboard/lifecycle/accessibility QA remain outstanding. Widget
tests exercise chooser cancellation through an injected picker; plugin compilation
does not prove manual dialog interaction. No unavailable platform or device test
is marked passed. Stage 6 verifies complete tagged MP3/ZIP publication and
Linux destination transfer before saving; actual phone/Windows and manual
picker/player gates remain open. See [the Stage 5–6 review](CODE_REVIEW_STAGE56.md).

Primary adapter references: [FFmpeg PulseAudio output](https://ffmpeg.org/ffmpeg-devices.html#pulse-1)
and [Flutter's file_selector](https://pub.dev/packages/file_selector).
