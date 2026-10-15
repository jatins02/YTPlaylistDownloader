# Native application

The shared Flutter app contains the Stage 1 foundation, isolated Stage 2 fixture
journey, verified Linux Stage 3 media pipeline and Stage 4 naming/artwork/tag
adapters, plus Stage 5 snippet playback and persistent review. Setup and execution boundaries are in [Stage 1](../../docs/STAGE1_GUIDE.md),
[Stage 3](../../docs/STAGE3_GUIDE.md), [Stage 4](../../docs/STAGE4_GUIDE.md) and [Stage 5](../../docs/STAGE5_GUIDE.md).
Flutter and Dart are recorded in [toolchain.json](../../toolchain.json); keep the
committed pubspec.lock and exact runtime pins.

The real Linux route persists drafts, verifies full audio/snippets and attempts
stable-ID naming and conservative front covers with each user's OS-stored key.
Provider failures preserve prepared peers. Private MP3 tagging verifies frozen
metadata, actual embedded cover bytes and audio. Linux snippets play through the local audio service. Revision-safe name/cover
edits and include/exclude choices persist across restart. Device MP3/ZIP export remains Stage 6; the fictional journey stays separate.

Source boundaries:

- `domain/`: validated values, immutable records, phases and safe failures.
- `data/`: versioned SQLite migrations, transactional repository and UUID-based private storage.
- `platform/`: OS credential storage and explicit media capability contracts.
- `metadata/`: bounded providers, artwork evidence/cache orchestration and guarded tag/image workers.
- `application/`: runtime startup/recovery, durable processing and isolated fixture state.
- `ui/`: responsive lavenderblush draft/processing/settings and real review/editor/player screens, plus separate fixtures.

Desktop SQLite executes through the FFI package's background isolate; mobile
SQLite uses the native plugin. Media/tagging are enabled only on verified Linux
runtimes. Windows/Android/iOS execution gates remain open. Workers stay bounded
and use current attempt/revision checks; final export publication is unavailable.
