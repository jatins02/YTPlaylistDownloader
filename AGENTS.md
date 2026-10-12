# Project instructions

## Scope and current decisions

Work in YTPlaylistDownloader. The sibling DOT. is reference-only; never modify its files, import its .env, reuse its environment or copy its downloaded media.

Read IMPLEMENTATION_PLAN.md, docs/PROJECT_STATUS.md and the relevant specification before coding. This checkout now contains a Stage 0 CLI and tests; the production/native app is not implemented. Explicit owner instructions override documents.

The owner confirmed zero budget, independent Android and iPhone operation, laptop support and device-only saves. No Mac/iPhone is available for testing. Do not replace independent phones with a laptop/LAN companion, provision paid hosting or silently drop iOS. The old hosted topology is superseded. Flutter/native adapters are candidates pending platform proof, not established implementation choices.

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

Use exact dependency pins and recorded platform/runtime versions. Write meaningful behavior tests with synthetic audio/fictional metadata; live provider/source calls are opt-in. Keep changes in the requested stage and update PROJECT_STATUS.md with actual commands/results, unresolved gates and next actions. Do not start a polished full UI before the relevant native media spike passes.

No independent agents, purchases, deployment or extra approval steps are implied by this file. Continue routine authorized local work; ask only for material missing decisions. agent.md remains a pointer to this canonical file.
