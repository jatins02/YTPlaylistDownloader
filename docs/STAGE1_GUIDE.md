# Stage 1 native foundation

## Implemented behavior

The native application saves canonical YouTube playlist links as private local drafts, lists them after restart, and provides masked settings for your own Groq key. Secure-storage errors remain visible without preventing draft use. There is no network request or media processing in this stage. The app does not load `.env`; that file belongs to the separate Stage 0 CLI.

Flutter 3.47.5 / Dart 3.13.4 are pinned in toolchain.json, apps/native/.flutter-version and .fvmrc. The SDK's exact official revision is verified by the bootstrap helper. Direct package versions and transitive dependency hashes are locked in pubspec.yaml/pubspec.lock. Do not run dependency upgrades as part of normal setup.

## Clean checkout: Linux

Install Git, Python 3 and the Flutter Linux build prerequisites. On Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libsqlite3-dev libglu1-mesa
python3 scripts/bootstrap_flutter.py
export PATH="$PWD/.tools-stage1/flutter/bin:$PATH"
cd apps/native
flutter doctor -v
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter run -d linux
```

Run from a desktop session with an unlocked Secret Service keyring (GNOME Keyring or an equivalent). libsecret alone cannot store keys. A missing/locked keyring produces a settings error; draft storage still works. No plaintext key fallback exists.

For headless native integration tests, also install `xvfb xauth dbus-x11 gnome-keyring fuse3`, then run from the repository root:

```bash
python3 scripts/test_linux_native.py
```

The helper creates a disposable display, D-Bus session, data/config directories and synthetic test key. It does not unlock your normal keyring. The integration test uses the actual Flutter path-provider/secure-storage plugins and SQLite, saves a draft through the controller, closes/reopens storage and verifies its identity.

Build the application with `flutter build linux --release`. Run `build/linux/x64/release/bundle/yt_playlist_downloader` from apps/native. Keep the entire bundle together. This is a development build, not a packaged installer.

## Clean checkout: Windows

Install Git, Python 3, and Visual Studio 2022 with Desktop development with C++, the Windows SDK and C++ ATL. Flutter's Windows compiler is Visual Studio; VS Code alone does not provide it. In PowerShell at the repository root:

```powershell
python scripts/bootstrap_flutter.py
$env:Path = "$PWD\.tools-stage1\flutter\bin;$env:Path"
Set-Location apps/native
flutter doctor -v
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter test integration_test/foundation_test.dart -d windows
flutter run -d windows
flutter build windows --release
```

The Windows workflow now passes these foundation checks, including actual native key storage, draft restart and debug/release compilation: [Foundation run #4](https://github.com/jatins02/YTPlaylistDownloader/actions/runs/38614867240). Its default suite passes 115 tests and skips the existing symlink test, which requires developer/admin privileges. Manual Windows QA and media/device export execution remain pending.

## Platform evidence

This table records Stage 1 foundation acceptance. For the subsequently verified
Linux source/conversion/snippet adapter, see [Stage 3](STAGE3_GUIDE.md) and the
[Stages 0–3 review](CODE_REVIEW_STAGE03.md).

| Platform | Foundation evidence | Media/device export |
| --- | --- | --- |
| Linux x64 | Local analysis, behavior tests, native debug/release compilation and actual native-plugin integration test | Adapter unavailable; Stage 0 CLI proof only |
| Windows x64 | Executed CI: analysis, 115 tests, native key storage/draft restart and debug/release builds pass; 1 symlink test skipped | Media adapter unavailable; manual QA, packaging/player evidence pending |
| Android | Runner template, API 24 minimum (Flutter 3.47.5) and backups disabled; SDK/device checks pending | Native spike pending |
| iOS | Runner template and Keychain entitlements authored; no Xcode/Mac/iPhone check | Native spike and distribution route unresolved |

Both phones remain in scope. These templates do not establish independent phone downloading. Android release signing still uses the development template; replace it with a deliberate release-signing configuration during Stage 8. Do not publish that template as a production release. iOS entitlements/signing must be checked on Xcode and a real device before claiming support.

## Local state and concurrency contracts

The application-support location from the OS contains `ytplaylistdownloader/drafts.sqlite`, a session lock, and `jobs/<job UUID>/assets/<asset UUID>.<extension>`. Titles are never path components. Job directories are isolated; exclusive creation prevents replacement, and managed paths reject symlinks/traversal. Linux directories have mode 0700; Windows inherits the user's profile ACL and phones use their application sandbox. This is local draft storage, not a permanent music library. SQLite is not encrypted; credential bytes never enter it.

One application process owns a workspace. Startup acquires the OS lock before migrations and recovery. Desktop SQLite runs through the FFI package's isolate; all database work uses asynchronous APIs and transactions. Foreign keys, WAL and a five-second busy timeout are enabled. Schema v1 creates jobs/tracks/ordered occurrences; v2 adds attempts/assets/frozen exports; v3 records original structured metadata separately from edits. Legacy v1/v2 tracks keep their source titles and effective metadata, with originalMetadata left null because the lost structured fields cannot be reconstructed safely. Upgrade and downgrade failures are explicit. Append new migrations after versions ship.

Source videos deduplicate within a job, while ordered playlist occurrences remain distinct. Different videos with equal titles retain distinct IDs. Source titles remain separate from effective/suggested metadata and per-field human overrides. Updates require expected revisions; stale suggestions cannot overwrite edits.

Attempts carry stage, immutable identity and generation. Checkpoint updates and asset registration validate the current running token and owner within the transaction. Track/job cancellation and failure retire their workers. Recovery retains checkpoints, invalidates old tokens/revisions, updates each job once and preserves already playable peers. A retry retires the historical retryable row, preventing it from blocking finalization indefinitely. Checkpoint asset references must belong to the same job/track. Export attempts start with a fresh checkpoint for their own snapshot. A checkpoint is a resume boundary, not a promise of OS background execution. Future adapters must verify complete files/checksums before `registerAsset`; Stage 1's repository tests use manifest fixtures, not downloadable audio.

Finalization freezes ready selected tracks, metadata revisions and explicitly identified audio manifests into hashed snapshots. It rejects missing or ambiguous audio and unfinished non-export processing. Stage 3 must define active audio selection before permitting multiple retained conversion artifacts for a track; the foundation does not guess which one to export. Snapshot hashes are checked again on reuse. Concurrent requests for the same active revision reuse the snapshot and lock edits. A recovered unfinished export must freeze the current review revision again. Completed snapshots remain reusable while the review has not changed. Returning to review invalidates an unfinished export worker; edits invalidate requests for an older completed review. This only prepares durable export state; tagging, ZIP verification, picker transfer and marking completion belong to Stage 6 and are not implemented here.

## Secrets and checks

The secure adapter stores a per-user key through flutter_secure_storage. It never uses a bundled `.env`, logs a native exception or falls back to SQLite/files. Linux uses libsecret/Secret Service; platform-specific storage must be tested independently. Synthetic integration credentials use unique test key names and are deleted. A prefix/length check validates input syntax only; live Groq authentication/quality is Stage 0/4 work.

```bash
cd apps/native
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --no-pub
flutter test --no-pub
```

The release check `python scripts/check_native_bundle.py <release-bundle-directory>` rejects bundled dotenv files and literal Groq keys, without printing key material. It is also part of CI.

The baseline workflow covers Linux/Windows foundations and the existing Stage 0 synthetic-media contracts; it sends no provider calls and receives no API secrets. CI results are evidence only after execution. SDK/native prerequisite installation requires internet; normal draft operation needs no hosted service.

Primary setup references: [Flutter Linux](https://docs.flutter.dev/platform-integration/linux/setup), [Flutter Windows](https://docs.flutter.dev/platform-integration/windows/setup), [secure-storage platform requirements](https://pub.dev/packages/flutter_secure_storage/versions/11.2.0), [desktop SQLite](https://pub.dev/packages/sqflite_common_ffi/versions/2.4.3).
