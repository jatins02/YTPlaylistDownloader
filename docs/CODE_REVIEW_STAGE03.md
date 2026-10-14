# Review of implemented Stages 0–3

Reviewed on 2026-10-14 against IMPLEMENTATION_PLAN.md, PRODUCT_SPEC.md,
ARCHITECTURE.md, the stage guides and the three project skills. This review
covers the CLI/provider probes, native domain and repositories, private files,
Linux media/process adapters, controllers, fixture and production screens,
tests, setup scripts, platform scaffolds and CI/container configuration.

Existing uncommitted implementation work was retained. No dependency upgrade,
historical migration edit, new product stage, commit, push or deployment was
performed. SQLite remains v4. The sibling DOT. was not accessed.

## Corrected findings

| Finding | Correction and behavior evidence |
| --- | --- |
| The foundation state API could mark a track ready with audio alone; enrichment recovery could do the same. | Both paths require exactly one active audio and snippet manifest. Regressions reject missing snippets and preserve queued recovery. |
| Replacing audio and retiring its old snippet happened in separate transactions. A crash between them could pair different conversions. | Publication invalidates dependent manifests atomically. Replacement sources also invalidate derivatives. A restart regression retains immutable history while requiring a fresh snippet. |
| Pipeline phase/retirement writes accepted tokens for unrelated stages; publication accepted inconsistent checkpoints. | Prepared-media writes require a current track conversion token and the matching acquired/converted checkpoint. Rejected writes leave active assets unchanged. Retirement also advances the job revision. |
| Nonexport tokens could write checkpoints into frozen/export-ready state. | Attempt creation and checkpoint acceptance enforce export phase boundaries. Completed snapshots remain immutable and edits still create a new review revision. |
| A crash between freezing an export and creating its worker left a permanently locked draft. Active jobs without running attempts also escaped foundation recovery. | Startup recovers active job phases independently of attempt rows, queues unfinished tracks and fails abandoned planned exports. Recovery remains idempotent and touches each affected job once. |
| Foundation imports omitted occurrence titles; legacy rows displayed an unavailable fallback despite retaining the linked source title. | Store each occurrence title and use the original linked title for older rows. One shared query supplies entry lists and transactional snapshots; human-edited titles are never used as source evidence. |
| Pause/cancel could finish while a retry transaction was waiting, after which the controller could start another worker. | Command generations fence that pending start. A regression blocks SQLite and pauses during retry, then proves acquisition never starts. |
| Multiple forced reads could overlap; paused jobs looked active; missing-job reads left an endless spinner; raw stop/read failures could escape UI callbacks. | Serialize forced refreshes, distinguish queued from running work, show a recoverable loading error and redact unexpected failures. Read failures clear after a successful read without erasing command errors. |
| A duplicate occurrence's source error was hidden by its shared track's state. | Render distinct occurrence and track failures, including beside a ready shared track. A widget regression verifies the warning remains visible. |
| Unexpected source exceptions or revision conflicts could leave processing stuck. | Fence interrupted active work, preserve verified peers and expose a structured recoverable failure. Synthetic-codec recovery proves peers are not reacquired or the playlist refetched. Invalid starts do not mutate terminal/review/export jobs. |
| Expiration could race a new acquisition; overlapping discards could race filesystem deletion; shutdown could release storage before discard finished. | Serialize retention with acquisition, coalesce discards, make repeated removal idempotent and drain managed work before closing. Real-codec tests cover expiration/acquisition and shutdown/cleanup ordering while preserving external copies. |
| A hash-valid retained snippet could be truncated; a decode-invalid retained asset could be retried forever. | Verify expected snippet/full-audio duration, retire decode-invalid boundaries, then rebuild through an explicit retry. The snippet regression retains the original full audio and avoids another source download. |
| The guarded runner could race supervisor termination during cleanup or miss a synchronously thrown storage-monitor error. | Await supervisor exit and pending monitoring before returning; catch synchronous monitor failures and validate operation limits. Process tests exercise timeout, cancellation, file/output caps and sanitized monitor failures. |
| A media-directory filesystem error could disable drafts/settings at startup; bundled byte slices could include unrelated buffer bytes. | Keep media unavailable after media filesystem failure while preserving the foundation, and install exactly the asset's byte range. |
| An old key-presence failure could overwrite a newer successful load. | Apply the same load-generation/disposal checks to success and failure. An out-of-order vault regression keeps the newer key state. |
| Successful CLI commands could leave descendants writing; media tools inherited provider credentials and could load plugin/remote components. | Retire POSIX process groups on every exit, allowlist child environments, isolate Python, disable shared extractor caches/configuration/plugins/remote components and keep CLI temporary/Deno files inside the quota-checked scratch root. Offline tests prove no delayed writes or inherited provider credentials; the pinned extractor accepts the options without a network request. Windows execution remains unverified. |
| CLI snippets for 30–60-second tracks started at 30 seconds and allowed padding beyond the stated bound. | Start short tracks at zero, reserve encoding padding and verify duration. A generated 45-second two-tone track proves the snippet contains the opening tone and remains at most 30 seconds. |
| Invalid filename budgets could break the portable cap/collision loop. | Reject unsupported budgets and keep bounded Unicode/collision behavior, including at the supported minimum. |
| A known album title could select the first of several release editions; AI could strip known version/clip markers; naming could use edited export titles when originals were absent. | Require one matching release, retain original-title fallback/review when known markers disappear, reject control characters and require original source records. The naming prompt is now `stage0-v2`. Provider tests use fictional mocked responses; live quality remains unproven. |
| The optional CLI image copied supervisor tests without their tested asset; an optional cleanup client was not closed. | Include the supervisor asset and close the client even when deletion fails. No Docker image or external storage request was executed. |

## Checks executed

The pinned project SDK and media manifest were used. The Flutter runner needed
loopback access outside the socket-restricted sandbox. Linux prerequisites were
downloaded from Ubuntu packages and extracted under
`/tmp/ytpd-stage2-toolchain/sysroot`; no system packages were installed.
The Git safe-directory exception was scoped to individual commands.

| Command/check | Actual result |
| --- | --- |
| `dart format --output=none --set-exit-if-changed lib test integration_test tool` | Pass |
| `flutter analyze --no-pub` | No issues |
| `STAGE3_TEST_RUNTIME=<project manifest> flutter test --no-pub --reporter expanded` | 132 passed, zero skipped: 122 ordinary tests and 10 opt-in real-codec tests |
| `PATH=<project media tools> .venv-stage0/bin/python -m unittest discover -s tests -v` | 41 passed, zero skipped |
| `.venv-stage0/bin/python -m stage0 synthetic --runs 3` | Three fresh runs pass: distinct audio, tags/cover readback, snippets and verified ZIPs |
| `python3 scripts/test_linux_native.py` | One actual foundation/plugin/keyring/SQLite/restart test passes in a disposable session |
| `STAGE3_TEST_RUNTIME=<project manifest> python3 scripts/test_linux_native.py --test pipeline_test.dart` | One actual runtime/codec/processing-UI/restart test passes in a disposable session |
| `flutter build linux --debug --no-pub` and `flutter build linux --release --no-pub` | Pass |
| `python3 scripts/check_native_bundle.py apps/native/build/linux/x64/release/bundle` | 16 release files checked; no dotenv asset or literal Groq key found |
| Pinned `yt_dlp --help` with configuration/plugin/remote-component disabling options | Pass, no source request |
| `git diff --check` | Pass |

Runtime: Flutter 3.47.5 at the existing recorded revision, Dart 3.13.4,
Python 3.14.4, yt-dlp 2026.8.19, EJS 0.8.0, Deno 2.5.4 and
FFmpeg/ffprobe n8.1.3-17-gc389840894-20261011. Linux build prerequisites used
clang 21.1.8, CMake 4.2.3 and Ninja 1.13.2; the disposable display used
Xvfb 21.1.22. Package versions and temporary verification logs remain under
`/tmp/ytpd-stage2-toolchain` and `/tmp/ytpd-review-*.log` for this session.

Initial test attempts exposed the sandbox's socket restriction and missing
temporary build prerequisites. An intermediate regression run exposed a test
import error; it was corrected. The results above refer to the corrected final
checks, not those failed attempts.

## Remaining gates

This is evidence for the implemented Linux/fixture/CLI scope. Android USB,
SDK/JDK/ADB access and Windows execution remain unavailable here; iOS still
needs Mac/Xcode and a real iPhone. No phone, Windows, Docker or GitHub CI pass
was inferred. No live YouTube, Groq, artwork or storage request was made in this
review. Stages 4–6 real enrichment/review/playback/tagged device export and
Stages 7–9 device QA/packaging/release remain later work.

Next actions remain the independent Android spike, Windows execution, the iOS
gate and Stage 4 on proven Linux with a securely configured user key and an
identifying artwork contact. Review and tests reduce defects; they do not prove
that every possible defect or unavailable-platform issue is absent.
