---
name: ytpd-media-pipeline
description: Implement or review YTPlaylistDownloader native playlist/audio tasks, checkpoints, full MP3/ZIP device exports and temporary-file cleanup.
---

# Media lifecycle

Read docs/ARCHITECTURE.md and the current stage in IMPLEMENTATION_PLAN.md. Zero budget and independent phones supersede the former hosted topology. Desktop CLI success does not prove Android/iOS execution.

Use immutable job/track/attempt IDs and private per-job storage. Validate supported source IDs, bound native/tool operations and never interpolate inputs into a shell. Keep work outside the UI thread. Use local durable checkpoints and generation checks; a late attempt cannot publish over a newer one. Respect OS suspension and resume boundaries rather than promising unlimited background work.

Download unique sources once per job while preserving occurrence positions. Partial source/enrichment failures stay visible. Cancel stops further work and stale publication. Retry only bounded eligible phases.

Save freezes selection/metadata. Produce new full-length tagged files, read tags/cover back, check duration/decoding, allocate portable collision-safe names, and verify all ZIP entries/checksums before marking output complete. Native picker cancellation/permission denial keeps recovery. Cleanup must not delete user-exported external copies.

Test distinguishable synthetic files, duplicate titles, restart/cancel races, storage limits, stale generations and corrupt exports. Use actual media tools/adapters for integration; record real device evidence separately. Optional S3/container probes are experiments, not required production dependencies.

Stage 3 Linux is implemented: read docs/STAGE3_GUIDE.md and docs/PROJECT_STATUS.md. Use schema v4/PipelineRepository, explicit active manifests and the verified runtime manifest. Keep phone/Windows media unavailable pending their actual execution proof. Never use fixture state for real files, bypass token-checked publication or interpret ordinary tests as the opt-in real-codec/native/live checks.
