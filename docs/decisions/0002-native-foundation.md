# 0002 — Flutter foundation with explicit platform gates

Date: 2026-10-12. Status: accepted for the Stage 1 foundation; media/distribution decisions remain provisional.

The owner asked to proceed with Stage 1 and prioritized Windows and Linux. Choose Flutter 3.47.5 for the shared UI/domain and native plugin boundaries. The local Linux application now compiles/runs, including actual path-provider, SQLite and secure-storage integration. Windows receives the same scaffold and CI checks; its build evidence remains pending execution. Android and iOS runner templates retain both-phone scope without asserting that mobile media works.

Use sqflite on mobile and sqflite_common_ffi on desktop, append-only SQLite migrations, UUID-based isolated storage, OS secure storage and transactional revision/attempt checks. Do not introduce hosting, accounts or a shared developer key. Keep the UI minimal until the corresponding native media spike passes.

MediaPort currently reports every media capability unavailable and returns a safe structured error. A saved playlist draft must not appear downloaded. Stage 3 will add adapters only after Stage 0 execution proof, with native/background work and device-specific limits. Stage 6 completes export publication and destination transfer; Stage 1 only stores immutable snapshots.

The architecture has a working Linux foundation, not a completed downloader or proof of iPhone feasibility. Stage 0's live naming/artwork, native phone execution and distribution gates remain open. No platform claim or stage status may infer those results from desktop fixtures or CI configuration.
