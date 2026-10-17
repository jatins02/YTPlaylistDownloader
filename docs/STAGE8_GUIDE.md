# Stage 8 packaging and distribution

Stage 8 is in progress. The scripts produce **private evaluation packages**;
they do not certify a public release or close Stage 7's physical/device gates.
No purchase, hosting, store submission, signing identity or shared AI key is
created. The application always uses each user's own OS-secured Groq key.

## Current package scopes

| Target | Package route | Boundary |
| --- | --- | --- |
| Linux x64 | Complete Flutter release bundle in a deterministic tar.gz; optional separately prepared media runtime; versioned per-user install | Needs compatible GTK 3, GLib, Secret Service/libsecret, SQLite, graphics and local PulseAudio/PipeWire libraries/services. Clean-device/player/manual acceptance remains open |
| Windows x64 | Complete foundation release bundle in a deterministic portable ZIP | Foundation only. Windows media remains disabled; Visual C++ runtime and clean Windows install/update acceptance are unverified |
| Android | `flutter build apk --debug --target-platform android-arm64 --no-pub`; foundation build validation in CI | Personal test APK only; no local SDK/JDK/ADB/device exposed here. Release debug-signing fallback is removed; release signing is unconfigured, not silently debug-signed |
| iPhone | No package/signing evidence | No Mac/Xcode/iPhone; independent media and zero-budget install/distribution remain unresolved |

The package manifest records app version, source revision/dirty-checkout flag, SQLite schema,
toolchain pins, build OS/architecture/libc, capability scope and every file's
SHA-256/length/executable mode.
It contains relative paths only. Checksums detect damage, **not publisher
authenticity**: obtain both package and checksum from a trusted channel. No
automatic network update or runtime download runs in the app.

## Build desktop evaluation packages

Use the exact Flutter revision and committed dependency lockfile. Build the
target on its native OS, run its tests, then package the complete bundle:

```bash
cd apps/native
flutter pub get --enforce-lockfile
flutter build linux --release --no-pub
cd ../..
python3 scripts/desktop_package.py build --target linux-x64 \
  --bundle apps/native/build/linux/x64/release/bundle --output dist/stage8
```

On Windows, use `flutter build windows --release --no-pub`, target
`windows-x64` and bundle `apps/native/build/windows/x64/runner/Release`.
The ZIP/tar.gz and `.sha256` are generated only under the explicit output
directory. No binaries or credentials belong in Git. A foundation-only package
does not contain the media runtime and does not claim playlist processing.

For Linux media, prepare a **new standalone** Python prefix, not this checkout's
venv. The exercised candidate is the official Astral CPython
3.14.4+20260414 Linux x86_64 GNU `install_only_stripped` distribution; upstream
archive SHA-256 is
`fe9a9c32d13870af632cbac3dfc7528ae53597e94472aa4c7d6a42e8166136cd`.
Verify the official `SHA256SUMS` before safely unpacking its `python/` prefix.
This is a separate distribution build pin, not a Python version upgrade.

```bash
python3 -m pip --isolated download --only-binary=:all: --no-deps \
  -r requirements-native-runtime.lock --dest /absolute/runtime-wheels
python3 scripts/prepare_linux_runtime.py \
  --python-home /absolute/standalone/python \
  --ffmpeg /absolute/pinned/ffmpeg --ffprobe /absolute/pinned/ffprobe \
  --deno /absolute/pinned/deno --wheelhouse /absolute/runtime-wheels \
  --deno-license /absolute/deno-2.5.4-LICENSE.md \
  --output /absolute/new-runtime
python3 scripts/desktop_package.py build --target linux-x64 \
  --bundle apps/native/build/linux/x64/release/bundle \
  --runtime /absolute/new-runtime --output dist/stage8
```

The explicit preparer installs exact offline wheels from
`requirements-native-runtime.lock`, checks dependencies/tool versions and keeps
all installed license files. It strips developer environment inheritance from
its child processes, reads no dotenv and invokes no live provider/source. The
preparer itself is offline; download the pinned wheels separately from PyPI.
It materializes only standalone-internal file aliases; venvs, directory links,
external aliases, private configuration, special files and oversized inputs fail.
Optional test/terminal data is omitted. Python caches are generated once using
checked source hashes and virtual source paths, included in the inventory, and
only read at runtime. Supervised `-B` commands never create/update those caches.
The packaged runtime is discovered beside the executable as
`runtime/media-runtime.json`. Explicit `YTPD_MEDIA_RUNTIME`/workspace overrides
retain precedence; a broken override never silently selects another runtime.
Tool hashes are checked off the UI isolate before the existing exact version
checks enable capabilities. No other platform is enabled by this path. Local
Linux builds use Ubuntu 26.04.1; foundation CI uses Ubuntu 24.04. A matching
architecture is insufficient to prove libc/GTK compatibility on another distro;
the manifest's build environment and actual clean-device checks are required.

**Do not publicly redistribute these media packages yet.** The FFmpeg binary
enables GPL/version 3 and many static libraries. Its complete corresponding
source/build recipe and all component obligations still need verification;
runtime notice collection is evidence, not license clearance. The owner also
has not selected a public application-source license. See
[component notices](../packaging/COMPONENT_NOTICES.md).

## Linux install, update and rollback

Close the app and let workers stop before switching versions. Verify the archive
checksum, unpack into a fresh directory with a safe archive utility, then run
the included manager using a trusted Python 3.11+ (or the included standalone
Python in a media package). Installation needs no root access:

```bash
python3 ytpd/package_manager.py verify ytpd
python3 ytpd/package_manager.py install ytpd \
  --prefix /absolute/empty/per-user/ytpd-install
/absolute/per-user/ytpd-install/current/app/yt_playlist_downloader
```

Install a later verified package using the same `--prefix`. Each package has an
immutable content ID under `releases/`; an atomic `current` symlink chooses the
active version. A failed verification/copy leaves the active pointer unchanged.
Interrupted incoming directories are never activated. Existing versions are
retained; the tool never removes an old version or user data. Concurrent installs
are serialized with an OS lock. An unrelated nonempty prefix is rejected.

Rollback activates a retained, reverified package ID from its `package.json`:

```bash
python3 ytpd/package_manager.py activate PREVIOUS_16_HEX_ID \
  --prefix /absolute/per-user/ytpd-install
```

Developers can smoke-test the actual unpacked/installed release without touching
the normal desktop keyring or application data:

```bash
python3 scripts/test_linux_package.py /absolute/unpacked/ytpd
```

This uses the existing headless Linux test prerequisites, a private D-Bus session,
temporary HOME/XDG directories and its own keyring/display. It verifies native
release startup, SQLite integrity/schema and bundled-runtime helper discovery.
It performs no gestures, source/provider calls or listening/export and does not
prove an update across different binaries or a clean physical device.

This is **binary rollback for equal schema versions**, not a database downgrade.
The manager rejects switching between different declared schemas. For a future
schema change, first implement and test an explicit backup/restore/migration
route. Do not edit or overwrite `drafts.sqlite` or a vault as a rollback shortcut.
The current schema remains v6; installation is separate from app-private support
storage. Use the same OS account/application ID so path-provider settings/drafts
and the user's secure key remain at their existing OS locations. Never install
into the app's data directory. Keep a normal backup before adopting evaluation
software. Exported music remains in user-chosen destinations and is never managed
by this installer.

For Windows evaluation, unpack each verified ZIP into its own version directory;
retain the previous directory and close the app before launching another one.
Do not copy only the EXE or mix libraries from releases. Automated Linux pointer
switches do not prove Windows installer or rollback behavior.

## Distribution and maintenance gates

Personal Android debug installs use a development certificate; a distributable
release needs an owner-controlled signing key and a tested update using the same
application ID/signing identity. No key or password is committed or generated by
these scripts. An unsigned release output is not an installable test APK.
[Android signing and debug/release distinctions](https://developer.android.com/studio/publish/app-signing).

The Android CI job uses the exact Flutter/Gradle/AGP/Kotlin pins, JDK 17,
Android platform 36 and build-tools 36.0.0. Gradle's distribution checksum is
enforced. It builds an arm64 debug APK, runs `apksigner verify`, records `aapt`
package information and scans decompressed files for private configuration and
literal keys. Native NDK 28.2.13676358 is selected by the pinned Flutter SDK.
Build/signature success does not prove Android plugin, media, document API or
physical-device behavior. Runner-generated debug identities are ephemeral;
APKs from separate runs are not a supported in-place update channel.

CI validates generated desktop packages/APKs without retaining binary artifacts
or publishing releases. Keep durable evaluation copies from the documented local
build commands and transfer through a trusted device/file channel. This avoids
introducing artifact-storage charges; GitHub's shared free storage allowance is
finite and must be checked before enabling any future retention/upload action.
No hosted updater or runtime auto-download is required. Public distribution
still needs the component and signing gates described here.

Apple's free Personal Team is development testing, not general App Store
distribution; provisioning expires and requires rebuilding/reinstalling. No
available Mac/iPhone establishes that path here, and paid membership is not
authorized. Both-phone scope is unchanged.
[Apple account capabilities](https://developer.apple.com/help/account/basics/about-your-developer-account).

The recorded yt-dlp/EJS/Deno combination must be checked before each package:
current upstream EJS guidance requires a supported JS runtime and packaged solver
code; this project retains Deno 2.5.4 and installed EJS 0.8.0, remote component
loading disabled. Do not substitute `denort`, use unpinned self-updates or infer
fresh YouTube compatibility from synthetic codecs. A permitted live source smoke
and provider/account checks remain opt-in.
[Upstream EJS requirements](https://github.com/yt-dlp/yt-dlp/wiki/EJS).

Full Stage 8 acceptance still needs clean target-device install/run, actual
update/draft/key persistence and rollback, packaged media source/edit/export/
player evidence, component/source clearance and the outstanding Stage 7 gates.
No unavailable phone result, fresh live source pass or public release is implied.
Executed commands/results belong in [PROJECT_STATUS.md](PROJECT_STATUS.md).
