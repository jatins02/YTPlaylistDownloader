# Staged implementation plan

Revised 2026-10-12 after Stage 0 discovery. **Confirmed constraints: zero budget; Android and iPhone must work independently; laptop support; device downloads only; no Mac or iPhone available for testing.**

The previous hosted-web topology is superseded as the default. See [the decision history](docs/decisions/0000-hosted-plan-superseded.md). A laptop-on-LAN companion does not satisfy independent phone operation. No paid provisioning is authorized by this plan.

## Target outcome

Playlist import → on-device acquisition/conversion → AI metadata and automatic covers → snippet preview and editable names → final tagged MP3/ZIP save to the device. UI remains professional lavenderblush with white/black accents and responsive layouts.

Proposed direction: shared native UI/domain code (Flutter selected for the Stage 1 foundation), platform-specific media adapters, private local files and SQLite state. The Flutter foundation has Linux execution evidence; media adapters remain provisional until their native execution is proven. No hosted worker, cloud database/object store or required user account is part of the zero-budget baseline. AI/source/artwork services still need internet and have quotas. Each user supplies their own AI key; never bundle the owner's .env in a released app.

## Sequence

| Stage | Exact outcome | Dependencies |
| --- | --- | --- |
| 0 | Core media/provider proof and independent target-platform execution proof | None |
| 1 | Reproducible native foundation and durable local state | Relevant Stage 0 platform gate |
| 2 | Responsive lavenderblush fixture journey | 1 |
| 3 | Real on-device playlist processing and recovery | 0 platform proof, 1, 2 |
| 4 | Validated AI naming, artwork and tag adapters | 3 |
| 5 | Real snippets and persistent revision-safe editing | 2–4 |
| 6 | Final verified tagged MP3/ZIP device export | 5 |
| 7 | Real-device accessibility, lifecycle and capacity evidence | 6 |
| 8 | Installable packages and viable distribution/update route | 0 distribution gate, 7 |
| 9 | Verified release and maintenance handoff | 8 |

Android/desktop work can progress independently while iOS is unproven. That does not remove iOS from scope or complete the full-product gate. Current evidence is in [PROJECT_STATUS.md](docs/PROJECT_STATUS.md).

## Stage 0 — Prove risky integrations and platform execution

**Goal:** Demonstrate repeatable playlist-to-tagged-file behavior, then establish an independent execution/export path on each target platform within zero budget.

**Achievables:** bounded [feasibility harness](docs/STAGE0_GUIDE.md), exact Python dependency pins, test reports/resource measurements, AI selection, native spike checklist, architecture decision and real-device evidence.

**Work:** Run the supplied three-track public playlist three times with fresh artifacts. Decode all tracks, generate snippets, read tags/cover back and verify the ZIP manifest/checksums. Validate one live Groq response by stable track ID and one known recording/release/cover lookup. Measure wall time, sampled RAM/CPU, scratch storage and payload bytes. Build minimal independent Android/iOS extraction, native conversion and file-export spikes with the current required runtime dependencies. Test real devices and record an affordable build/install/distribution route.

**Done when:** three fresh source runs succeed; live AI and known-cover checks pass; the sample downloads/converts/exports on actual Android, iPhone and laptop independently of a laptop server or hosted media worker; local players display correct tags/cover; resource limits and tested dependency versions are recorded; a distribution route fits the owner's constraints. Desktop Python success, emulator output and an iOS compile cannot replace actual device evidence.

**Current limits:** local core runs and Stage 4 configured Groq/known-artwork acceptance passed. Android/iOS native adapters are untested; Mac/iPhone access is unavailable. Windows media/tag execution and saved-file/player/distribution evidence remain open. Keep Stage 0 in progress and document unsupported/unproven gates. Continue useful core/provider or feasible-platform work without promising both-phone completion.

## Stage 1 — Native foundation and local state

**Goal:** A clean checkout builds/runs the chosen skeleton on each proven platform and preserves private local job state.

**Achievables:** pinned toolchain/project, platform adapter interfaces, SQLite migrations, secure-key storage, isolated job directories, setup instructions and baseline CI.

**Work:** Validate UI-to-native integration; store phases, original metadata, effective fields, revisions/checkpoints and exports. Use maintained OS secure-storage adapters and explicit per-user key settings. Keep processing outside the UI thread.

**Done when:** documented clean builds work; a fixture draft survives restart; migrations initialize empty storage; credentials are absent from source/binaries/logs; local jobs remain isolated; adapter failures have structured errors. Only platforms with evidence can be called supported.

**Implementation record (2026-10-12):** Foundation deliverables are implemented in apps/native with exact pins, setup helpers and baseline CI. Linux acceptance checks passed: persistent drafts, migrations, keyring integration, isolated state, structured errors and clean debug/release builds. Windows runner/setup/CI is implemented but execution is pending; Android/iOS templates remain unverified. Stage 1 is accepted for the proven Linux foundation only; no pending platform or media gate is marked passed. See [Stage 1 guide](docs/STAGE1_GUIDE.md) and [status](docs/PROJECT_STATUS.md).

## Stage 2 — Design system and fixture journey

**Goal:** A coherent native import → progress → review → save flow at phone/tablet/laptop sizes.

**Achievables:** lavenderblush tokens, accessible controls, track/editor/player screens, settings and loading/empty/partial-failure/expiry states.

**Work:** Adapt DESIGN_SYSTEM.md to native widgets. Include long Unicode names, duplicate titles, missing covers and visible touch actions. Provide explicit Save/Cancel for edits and selected-track counts.

**Done when:** the fixture flow works at narrow, landscape, tablet and laptop widths without clipped controls; keyboard/screen-reader routes, large text, focus and contrast pass; rendered screens are reviewed. Fictional fixtures are clearly labeled.

**Implementation record (2026-10-13):** Stage 2 fixture interface is complete. Separate in-memory import/progress/review/editor/silent-player/save flows, settings and recoverable error/expiry states are implemented. Layout, large-text, keyboard, semantics/contrast checks and rendered-screen review pass; the full native suite has 80 passing tests. Linux native integration/release checks pass. Real source/media/export and actual phone/Windows verification remain separate gates. See [Stage 2 guide](docs/STAGE2_GUIDE.md).

## Stage 3 — On-device playlist and audio pipeline

**Goal:** Real accessible playlists become isolated playable tracks with truthful progress and recoverable local state.

**Achievables:** validated URLs, ordered entries, duplicate handling, native source/conversion/snippet adapters, cancellation/retry, resource caps and cleanup.

**Work:** Use platform-tested runtimes/codecs. Persist checkpoints and generation tokens. Respect OS suspension/background limits. Bound bytes/duration/count/concurrency and make low storage/network failures actionable.

**Done when:** the real sample works independently on every claimed platform; unavailable items do not erase peers; equal titles preserve distinct bytes; duplicate sources follow the rule; restart resumes from a valid boundary; Cancel blocks stale publication; limits stop work safely. No unlimited iOS background-processing promise.

**Implementation record (2026-10-14):** Stage 3 source/conversion/snippet processing is implemented and accepted for the proven Linux x64 development app. Real sample acquisition, strict decode/duration/checksum checks, ordered/deduplicated entries, visible failures, generation-fenced pause/cancel/retry, restart reuse, quotas, expiry and private cleanup are implemented. 110 native tests (including six actual-codec cases), 32 Python tests and Linux native integration/release checks pass. Android phone availability is confirmed, but USB/toolchain access is absent here; Android/iOS/Windows media adapters remain disabled and their execution gates open. Full multi-platform completion is not claimed. See [Stage 3 guide](docs/STAGE3_GUIDE.md).

## Stage 4 — AI names, artwork and tags

**Goal:** Every acquired track gets a validated naming attempt and conservative artwork lookup with explicit uncertainty.

**Achievables:** configurable Groq adapter, schema/prompt versions, stable-ID mapping, deterministic song–artist–features formatting, throttled cover cache/provenance and tag readback adapters.

**Work:** Start with openai/gpt-oss-120b on the user's configured Groq account; validate account availability and quality. Send bounded source text only. Preserve remix/live/slowed/verse-only details. Match recording/release-linked front artwork, validate images and let human overrides win by field/revision.

**Done when:** missing/extra/reordered/duplicate replies, multilingual/unknown titles, modified versions, wrong/missing art and provider rate limits have tested outcomes; no positional mapping; delayed AI cannot replace human edits; actual tags/cover read back on each platform. Provider failure keeps playable audio and visible review flags.

**Implementation record (2026-10-15):** Native Stage 4 is implemented for the proven Linux development runtime: secure-key Groq adapter and strict stable-ID validation, conservative recording/release-linked approved front-art lookup, bounded cache/transport, revision/token-safe publication and verified ID3v2.3 full-MP3 derivatives from frozen metadata. Actual image/tag/codecs and Linux native secure-storage/UI/restart checks pass with fictional provider fixtures. The authorized live Groq benchmark passes on openai/gpt-oss-120b for stable IDs, title/artist/features, modified versions and unknown-source uncertainty. Known public recording/release/front-art lookup and embedded-cover/full-decode proof also pass. Windows/Android/iOS media/tag execution remains open; full multi-platform Stage 4 acceptance is not claimed. Playback/editing and verified destination publication remain Stages 5–6. See [Stage 4 guide](docs/STAGE4_GUIDE.md) and [status](docs/PROJECT_STATUS.md).

## Stage 5 — Real review and editing

**Goal:** Users hear actual snippets and correct metadata without losing draft edits or playback identity.

**Achievables:** one-audio controller, fields/filename preview, original-title access, artwork selection/removal, include/exclude controls and revision-aware persistence.

**Work:** Connect private local assets to visible controls. Play on gesture, one bounded snippet at a time. Explicitly save edits; preserve text after save failure and reject stale revisions. Final Save waits for pending changes and selected-ready items.

**Done when:** clips play without overlap and stop at their bound; renaming does not break playback; restart restores committed edits/selection; conflicts and excluded/failed counts are clear before export.

**Implementation record (2026-10-16):** Stage 5 review is implemented for the proven Linux runtime: actual bounded snippets through the local PulseAudio/PipeWire socket, serialized switching/pause/seek and lifecycle stop, persistent revision-safe metadata editing, native image selection with bounded normalization, cover choices/removal and explicit track/unavailable-entry exclusions. Open review tokens block freezing; failed/stale saves preserve text and explicit rebase updates only edited fields. Native synthetic output capture distinguishes equal-title tracks, and user-cover/APIC and restart checks verify actual bytes and durable state. Final file publication/device transfer remains Stage 6. Windows/Android/iOS media/playback execution, physical-speaker listening and manual OS chooser/device QA remain unverified. See [Stage 5 guide](docs/STAGE5_GUIDE.md) and [status](docs/PROJECT_STATUS.md).

## Stage 6 — Final Save to Device

**Goal:** A frozen review revision becomes full-length tagged MP3s and a verified ZIP at the selected device destination.

**Achievables:** immutable snapshots, collision-safe filenames, verified tags/artwork/audio, archive/manifest and native document/save/share integration.

**Work:** Tag new derivatives, verify files, build within local quotas and publish complete private artifacts only. Use Android scoped-storage/document APIs and iOS document/share APIs rather than arbitrary paths. Preserve a recoverable draft when the destination chooser is cancelled.

**Done when:** sample exports/open on actual Android, iPhone and laptop; selected files/tags/covers are correct; equal names survive; repeat Save reuses a completed revision; interrupted writes do not count as success; denied permission, picker cancellation and low storage recover. Files export is not automatic insertion into every Music library.

## Stage 7 — Device lifecycle, accessibility and performance

**Goal:** Measured reliable behavior under realistic device interaction and resource limits.

**Achievables:** device/version matrix, accessibility results, performance/storage/battery measurements and lifecycle recovery evidence.

**Work:** Test keyboard, orientation, large text, screen readers, reduced motion, suspension/restart, network loss and low storage. Use synthetic media for repeatable load and the small real playlist for source smoke tests. Document when the app must remain open.

**Done when:** every claimed platform has real download/edit/save/playback and recovery evidence; no data-loss defect remains; initial capacities are measured. Emulator/simulator tests are distinguished from devices.

## Stage 8 — Packaging and distribution

**Goal:** Installable verified packages with realistic zero-budget distribution and update behavior.

**Achievables:** Android test APK, desktop packages, iOS signing/build evidence if available, runtime manifest, component notices and update/rollback instructions.

**Work:** Check current extractor/JS-runtime/native-library compatibility before bundling. Package media dependencies; exclude .env and developer keys. Distinguish personal development install from public store release and document any unavoidable external expense.

**Done when:** clean target devices install/run the packages; updates preserve private settings/drafts; rollback works; keys are not shared in binaries; iOS install/distribution is either proven within budget or explicitly unresolved. No purchase is implied.

## Stage 9 — Release and handoff

**Goal:** Deliver the verified scope with user guidance and a maintainable compatibility-update process.

**Achievables:** release artifacts, key/setup guide, acceptance evidence, supported-platform/source list, limitations and maintenance instructions.

**Work:** Run actual-device release/export checks, secret scanning and update/recovery exercises. Document AI quota exhaustion, uncertain names, unavailable covers and upstream changes.

**Done when:** the owner completes the intended workflow on every released platform, acceptance gates have evidence and support claims match actual builds. Android-only release does not complete the both-phone requirement unless the owner changes scope.

## Shared definition of done

Deliverables exist, behavior is demonstrated, relevant tests pass, real-platform limits are recorded and PROJECT_STATUS.md contains actual evidence. No screenshot, build, mock or desktop CLI alone proves the entire product.
