# Native foundation

Stage 1 shared Flutter application. Run/setup instructions, platform evidence and storage contracts are in [STAGE1_GUIDE.md](../../docs/STAGE1_GUIDE.md). Flutter and Dart are recorded in [toolchain.json](../../toolchain.json); commit pubspec.lock.

The current screen saves playlist drafts and manages your own Groq key. Downloading, AI requests, cover lookup, playback and device exports are later stages. No fictional downloads are presented as real results.

Source boundaries:

- `domain/`: validated values, immutable records, phases and safe failures.
- `data/`: versioned SQLite migrations, transactional repository and UUID-based private storage.
- `platform/`: OS credential storage and explicit media capability contracts.
- `application/`: runtime startup/recovery and draft/settings state.
- `ui/`: minimal accessible lavenderblush foundation screen.

Desktop SQLite executes through the FFI package's background isolate; mobile SQLite uses the native plugin. Media adapters are unavailable until proven. Future media work must use native/background execution and the repository's attempt/revision checks.
