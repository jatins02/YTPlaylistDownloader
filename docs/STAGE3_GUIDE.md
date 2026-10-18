# Stage 3: local playlist and audio processing

Implemented and accepted for the tested **Linux x64 development app** on 2026-10-14. Windows, Android and iOS media execution remain unproven. The owner has an Android phone available by USB, but this execution environment exposes no USB devices, JDK, Android SDK or ADB; no Mac/iPhone is available. No phone support was silently dropped, substituted with a laptop server or claimed from desktop tests.

## Run the app

Use the pinned Flutter setup in [STAGE1_GUIDE.md](STAGE1_GUIDE.md). This checkout already has project-local Stage 0 media tools; a clean checkout must obtain the recorded Linux runtime first. The prototype does not depend on DOT.'s environment or credentials.

From the repository root:

```bash
python3 scripts/configure_media_runtime.py
export YTPD_MEDIA_RUNTIME="$PWD/.tools-stage3/media-runtime.json"
export PATH="$PWD/.tools-stage1/flutter/bin:$PATH"
cd apps/native
flutter run -d linux
```

Paste a playlist link, save its draft, then **Open playlist → Process playlist**. The real route is separate from **Explore the fictional demo**. It shows named phases, ready/failed counts, unavailable entries and every occurrence in original returned order. Repeated source IDs acquire one audio copy; different videos with equal titles keep separate IDs and files.

**Pause and keep progress** stops workers and leaves a resumable job. **Resume processing** verifies retained files and resumes at a valid source/audio boundary. Closing the application also pauses its active worker; a crash is recovered on startup. **Cancel processing / Cancel job** is terminal for that draft, preserves existing private audio and fences late results. Import a new draft to start a cancelled job again. **Remove temporary media** is available after cancellation and deletes only that job's managed private bytes, preserving source metadata and any copies outside the app.

When source acquisition fails, playable peers survive. Use **Retry failed tracks**; it does not refetch a changed playlist or reacquire ready peers. Entries with no usable identity remain visible. Missing provider positions/counts create explicitly unavailable placeholders; unknown positions are labeled unreported. Such entries cannot silently disappear into a later export. Live/upcoming/overlong sources are visible unsupported entries. Private/authenticated/age-restricted sources and cookie collection are not supported.

Source titles, bounded uploader/channel evidence and measured durations are stored independently of human edits. Artists remain unknown and names need review. **Stage 3 does not perform AI naming, artwork matching, tagging, interactive playback or final device export.** Full-length raw MP3s and snippets are verified private preparation assets; `canTag` and `canExport` remain false. Listening/editing/device transfer belong to Stages 4–6.

## Runtime and local configuration

| Component | Exact tested version |
| --- | --- |
| Flutter / Dart | 3.47.5 / 3.13.4; existing recorded SDK revision |
| Python | 3.14.4 |
| yt-dlp / packaged EJS | 2026.8.19 / 0.8.0 |
| FFmpeg and ffprobe | n8.1.3-17-gc389840894-20261011 |
| Deno | 2.5.4 |
| SQLite schema | 4 |

`configure_media_runtime.py` writes ignored `.tools-stage3/media-runtime.json` with four absolute executable paths: python, ffmpeg, ffprobe and deno. It reads no dotenv file and makes no network request. Pass its `--python`, `--ffmpeg`, `--ffprobe` and `--deno` options for explicitly installed tools. Keep a venv Python's invocation path; resolving its symlink would select the system interpreter and lose the packages.

Native startup verifies every recorded version before enabling acquisition/conversion/snippets. A missing/mismatched runtime leaves drafts/settings usable and processing unavailable. A distribution build must package and license its own validated runtime in Stage 8; these developer-local paths are not a portable installer. Tool updates are deliberate compatibility work, never an unrecorded self-update.

Set `YTPD_MEDIA_RUNTIME` before launching, or put the same JSON in the app's private support directory as `media-runtime.json`. The app never loads `.env`. Source tools inherit a small environment allowlist; Groq keys and other arbitrary environment secrets are not forwarded. Config, plugin, cookie/netrc and remote-component loading are not enabled by the source adapter. The required EJS code is the installed pinned package. [yt-dlp dependencies/options](https://github.com/yt-dlp/yt-dlp), [EJS setup](https://github.com/yt-dlp/yt-dlp/wiki/EJS).

## Limits and verification

The conservative tested desktop defaults are **100 playlist occurrences, 10 unique sources, 600 seconds per source, 50 MiB per media file, 512 MiB per job, 1 GiB across managed media and a 64 MiB free-space reserve**. One playlist/one track processes at a time. Enumeration has a two-minute deadline, individual operations at most five minutes and each processing invocation at most twenty minutes. Socket timeout is fifteen seconds; source/extractor/fragment retries are bounded to one. The source request takes one extra entry beyond the count cap to detect truncation; oversized lists reject atomically.

Linux enforces the file ceiling with `RLIMIT_FSIZE`, in addition to downloader caps and final byte checks. Storage is checked before work and during guarded commands; directory ceilings can overshoot by data written within a polling interval before cancellation. Resource exhaustion is a visible recoverable failure, not a successful partial file.

Every source and derivative has one audio stream, a finite bounded duration and a full strict FFmpeg decode. Full MP3 duration is compared with acquired audio; known source duration provides another truncation check. Hashing and playlist JSON parsing use Dart isolates; codecs/extraction run outside the UI process. Full MP3 uses requested 320 kbps, limited by source quality. Snippets start at 30 seconds for tracks longer than 60 seconds; shorter tracks start at zero. Encoding leaves MP3 frame-padding room so the measured snippet is at most 30 seconds.

## Durable lifecycle

Schema v4 appends enumeration/error/duration/uploader fields, explicit active media manifests and selection for unmapped entries. Historical migrations remain unchanged. Playlist entries, deduplicated tracks and enumeration completion commit in one transaction under the running attempt token. There is no half-imported prefix to mistake for a full playlist.

Every publication validates its track/conversion token inside the database transaction. Assets have immutable UUID paths/checksums. A newly verified replacement atomically becomes active; older manifests stay immutable. Frozen exports select active audio and reject unexcluded unmapped entries. Acquisition and converted-audio checkpoints stay meaningful when a preview is published. Resuming checks lengths/hashes and decodes before reusing files; damaged ready audio is flagged and rebuilt only after an explicit retry.

The bundled Python supervisor starts each tool in its own process group, enforces the file cap and kills descendants on cancellation, timeout, parent death or normal completion. A parent-death race is checked before spawn; termination is deferred across the spawn/assignment gap. Final stdout/stderr is byte-bounded; raw diagnostics and signed URLs are discarded. Even a zero exit status cannot override a reported final storage-write failure. [Linux parent-death signal semantics](https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html), [Python process/session support](https://docs.python.org/3/library/subprocess.html).

Startup removes orphan assets and incomplete scratch under the sole workspace lock. Registered assets are retained through failures/retries. The private job's retention window is 48 hours **from draft creation**, checked on startup and every five minutes when the app can run. Resuming processing or editing does not reset that timestamp; active workers, playback, open editors and active exports are protected until their work ends. Expiry removes private bytes and keeps source metadata/edits. Add the playlist as a new draft to prepare it after expiry. Device shutdown can delay cleanup; there is no hosted scheduler. Stage 6 defines completed-export expiry and external-copy preservation.

## Executed evidence

- **110 Flutter behavior/widget/real-codec tests pass**, zero skipped: 104 ordinary tests plus six opt-in tests with actual pinned tools and generated audio.
- **32 Python tests pass**, zero skipped, including parent-crash and lingering-descendant checks.
- Existing native foundation/plugin/restart integration and the new native pipeline/UI/restart test pass in disposable Linux sessions.
- Formatting, analysis, Linux debug/release compilation and release dotenv/literal-key scanning pass.
- The supplied three-track live playlist completed with real full MP3s and verified snippets. The initial run prepared two peers; one source failed. Explicit retry prepared the remaining track without changing the peers' IDs/checksums. A final fresh saved-checkout run is recorded in the evidence summary.

[Sanitized acceptance records](STAGE3_RESULTS.json) contain observed modes, counts, times and hashes. They do not prove real phone execution, Windows compilation, interactive listening, covers, tags or destination saving. Raw reports and generated/downloaded media remain ignored in `stage3-runs`.

## Repeat checks

From `apps/native`:

```bash
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze --no-pub
flutter test --no-pub
STAGE3_TEST_RUNTIME="$YTPD_MEDIA_RUNTIME" flutter test --no-pub
dart run tool/media_smoke.dart
```

The last command uses generated fictional audio through the real adapter. A live check is explicitly opt-in:

```bash
dart run tool/media_smoke.dart --live 'https://www.youtube.com/playlist?list=YOUR_PLAYLIST_ID'
dart run tool/media_smoke.dart --resume /absolute/path/to/this/repo/stage3-runs/linux-RUN_ID
```

From the repository root, with the pinned SDK/tools available:

```bash
python3 scripts/test_linux_native.py
STAGE3_TEST_RUNTIME="$YTPD_MEDIA_RUNTIME" python3 scripts/test_linux_native.py --test pipeline_test.dart
```

Ordinary CI runs no live source/provider requests. The real-codec suite is explicitly enabled with `STAGE3_TEST_RUNTIME`; the standalone native pipeline test also requires that manifest. Recorded local checks are not a claim that GitHub Actions ran.

## Remaining platform gates

Android needs an exposed SDK/JDK/ADB/device path and a minimal independently executed source/JS-runtime/codec/storage spike. The maintained wrapper remains a candidate; inspect its actual bundled Python/JS/codec versions and private-storage behavior before choosing it. [Android candidate](https://github.com/yausername/youtubedl-android). Windows needs native build/source/process-tree/recovery evidence and its own supervisor implementation. iOS needs Mac/Xcode and a real iPhone plus an extraction/in-process codec route; this Linux supervisor cannot be reused there. No Mac/iPhone is available.

Those adapters remain unavailable. Linux acceptance completes the feasible Stage 3 scope; **the full multi-platform Stage 3 gate remains open** until the required devices/runtime paths are proven. Both independent phones and the Windows target remain requirements.
