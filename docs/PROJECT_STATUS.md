# Project status

Updated: 2026-10-12.

## Current state

**Stage 0 is in progress.** The bounded CLI, tests, dependency pins and optional container/provider probes are implemented. The full native application is not implemented and no cloud resources have been provisioned.

| Stage | Status | Evidence |
| --- | --- | --- |
| 0 — Feasibility | In progress | 15 tests pass; 3 synthetic runs and 3 live local playlist runs pass; native/provider gates open |
| 1 — Native foundation | Not started | Framework/platform adapters not proven |
| 2 — Design/fixture flow | Not started | Written design requirements |
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
- Create this project's .env for a new user-provided Groq key; do not reuse DOT.'s credentials.

The original hosted plan has been superseded as the default. Native on-device adapters with shared UI are proposed; iOS is still required but unproven. Independent Android/desktop work can progress without claiming both-phone completion.

## Verified local evidence

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

Dependencies/tools were first tested in isolated /tmp locations, then an ignored project-only .venv-stage0 and .tools-stage0/bin were prepared and checked from this folder. Activate .venv-stage0 to run the harness here. No system Python or DOT. environment was changed. Recreate clean-checkout setup using STAGE0_GUIDE.md. Docker, Flutter, Dart, Java/ADB and Xcode are not installed here; container and native builds have not been verified.

## Pending Stage 0 gates

- GROQ_API_KEY is empty at setup time; choose Groq's free plan, paste the key into .env and run metadata-check on a retained report. Account access, quota and song-identification quality remain unverified.
- MUSICBRAINZ_CONTACT needs a project URL/contact identifier before the known recording/release/cover check.
- Actual Android extraction/runtime/conversion/export spike and device evidence.
- iOS-compatible extraction/media adapter, Xcode/build access, real iPhone evidence and a viable distribution route. No Mac/iPhone is available; this is an unresolved feasibility requirement, not a passed or dropped feature.
- Laptop packaging and actual saved-file/player evidence beyond the CLI.
- Native device resource/battery/lifecycle limits and final capacity choices.

Public App Store distribution has membership requirements; zero-budget public iOS release is not promised. Optional hosted storage probes are not mandatory under the revised native baseline. No API key, cloud storage account or paid service was provisioned.

## Next actions

Populate this project's .env with the new Groq key (never paste it in chat), then run one live stable-ID naming check against the retained sample. Supply an identifying MusicBrainz contact for a known-cover test. Continue the Android native execution spike when a toolchain/device is available; retain iOS as explicitly unresolved until it can be built/tested.

For future updates, record stage, implementation revision, commands/results, observed limits and next action. Do not mark a platform or stage done without its stated evidence.
