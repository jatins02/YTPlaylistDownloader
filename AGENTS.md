# Project instructions

## Scope and current decisions

Work in YTPlaylistDownloader. The sibling DOT. is reference-only; never modify its files, import its .env, reuse its environment or copy its downloaded media.

Read IMPLEMENTATION_PLAN.md, docs/PROJECT_STATUS.md and the relevant specification before coding. This checkout contains the Stage 0 CLI, Stage 1 native foundation and Stage 2 fictional journey in apps/native. Read docs/STAGE2_GUIDE.md for the fixture boundary and acceptance evidence. Read docs/STAGE1_GUIDE.md and toolchain.json for setup and contracts. Stage 3 source/conversion/snippet processing is implemented for verified Linux runtimes; read docs/STAGE3_GUIDE.md. Stage 4 Linux naming/artwork/tag adapters are implemented; read docs/STAGE4_GUIDE.md for actual evidence and unresolved live/platform gates. Real review/playback and device export remain later work. Explicit owner instructions override documents.

The owner confirmed zero budget, independent Android and iPhone operation, laptop support and device-only saves. No Mac/iPhone is available for testing. Do not replace independent phones with a laptop/LAN companion, provision paid hosting or silently drop iOS. The old hosted topology is superseded. Flutter 3.47.5 is selected for the foundation (decision 0002); media adapters remain candidates pending platform proof. Windows and Linux are the prioritized desktop targets; Windows execution is pending, while Linux foundation checks passed.

## Product behavior

Playlist → on-device processing → AI song–artist–features metadata and covers → snippet review and edits → final full-length tagged MP3/ZIP save through device APIs. Omit empty feature separators; preserve version markers. No permanent cloud music library/accounts are required. UI is responsive lavenderblush with white/black accents and visible touch actions.

## Invariants

- Immutable job/track/asset IDs; titles never identify stored bytes. Never scan a common downloads directory or map AI responses by array position.
- Private per-job files and local durable checkpoints. Native work stays off the UI thread. Respect each OS's background limits; stale generations cannot overwrite newer state.
- Human-edited fields/revisions win over late AI results. Final save freezes selection/metadata; duplicate save requests reuse a completed snapshot.
- Publish only fully verified tagged files/ZIP manifests. Duplicate filenames must preserve distinct audio. Verify embedded cover bytes, not only UI artwork.
- Failed source/AI/artwork stays visible; preserve playable peers and source-title fallbacks. Do not invent artists/covers or silently omit songs.
- Validate/reconstruct supported source URLs, use bounded native operations/desktop argument arrays, and restrict artwork providers/redirects. Enforce time, byte, duration and storage limits.
- Keep secrets out of source, logs, fixtures, prompts and release binaries. The CLI reads only this project's .env. Never read DOT.'s credentials.
- A native release uses each user's own API key with OS secure storage. Do not ship one developer key in a compiled .env. Free API quotas are limited and must fail gracefully.
- Device export cancellation/permission denial preserves recovery. Temporary cleanup must not delete user-exported copies.
- Desktop tests, mock providers, emulator output or successful iOS compilation do not prove the real-device gate. Never mark an unavailable platform test passed.

## Relevant skills

Read task-relevant skills under .agents/skills/: ytpd-media-pipeline for media/task/export lifecycle; ytpd-metadata for AI/artwork/tags; ytpd-interface for responsive review/device-save UX. Their native direction matches the current plan. The optional Stage 0 S3/container adapters are experiments, not required app infrastructure.

## Working conventions

Use exact dependency pins and recorded platform/runtime versions. Write meaningful behavior tests with synthetic audio/fictional metadata; live provider/source calls are opt-in. Keep changes in the requested stage and update PROJECT_STATUS.md with actual commands/results, unresolved gates and next actions. Stage 2 fixture UI is complete and explicitly isolated from real processing. Do not claim production media UI capabilities before the relevant native media spike passes; keep fixture actions labeled and outside durable jobs/files.

No independent agents, purchases, deployment or extra approval steps are implied by this file. Continue routine authorized local work; ask only for material missing decisions. agent.md remains a pointer to this canonical file.

## Native foundation conventions

Use apps/native with the exact SDK revision in toolchain.json and committed pubspec.lock. Run Dart formatting, flutter analyze, behavior tests and native integration tests for the affected proven platforms. Linux acquisition/conversion/snippet capabilities may be enabled only after pinned-runtime verification. Other platform media adapters, tagging and export remain unavailable until their own execution gate passes. Use PipelineRepository token-checked writes for Stage 3; never route real processing through FixtureJourney. Never bypass frozen export creation with a phase update or register an asset without its current attempt token. Stage 6 must add verified export publication/destination transfer before declaring save complete. Baseline CI configuration alone is not evidence that a build ran.

## Stage 3 contracts

Schema v5 is current; v4 remains the historical Stage 3 migration. Source/channel evidence stays separate from human metadata; active manifests select a single verified audio revision. Do not revive cancelled jobs, bypass unresolved-entry export gating, refetch a remote playlist on resume or mark a track ready without verified audio and a snippet. Process groups/file caps are Linux-only primitives. Pause/close retain checkpoints; cancellation fences before killing; expiry/discard affect only private job bytes and preserve metadata/user copies. Real-codec tests require STAGE3_TEST_RUNTIME; live smoke checks are explicitly opt-in. No USB/JDK/Android SDK/ADB is exposed in this execution environment; the owner has an Android phone available by USB.

## Stage 4 contracts

Use the real EnrichmentPipeline and PipelineRepository token-checked writes,
not fixtures. Groq requests use the OS vault and bounded original text; enforce
exact ID sets, uncertainty/version markers and field/revision precedence.
Match recording/release/approved front artwork conservatively. Public HTTPS
DNS/redirect validation, byte/pixel/deadline caps and persisted device pacing/
cache expiry are mandatory. Human cover/removal overrides survive late results.
Tagging uses new frozen-snapshot derivatives, exact embedded-cover readback and
encoded-audio/full-decode verification inside private job work directories.
Linux tagging, configured Groq naming and known public artwork/APIC acceptance
are proven; other-platform media/tag execution remains open. Stage 4 does not prove real playback/editing, ZIP
publication or destination save. Development live checks require explicit
opt-in and never pass a key through argv/files/reports. Stage 6 must own final
verified publication and device transfer.
