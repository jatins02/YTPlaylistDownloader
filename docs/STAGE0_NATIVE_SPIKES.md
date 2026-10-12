# Native execution spikes

Status: **not implemented/tested**. The CLI core passed, but both phones must execute independently of it.

## Android proof

1. Install a current compatible JDK/Android SDK and select a maintained extractor/codec adapter. Inspect bundled Python, yt-dlp, EJS/JS runtime, ABIs and target SDK; an old README is not compatibility evidence.
2. Create only a minimal test activity/native harness, not the full application UI. Use private app storage and a fixed small permitted playlist; no shared developer API key in the package.
3. On a real phone, enumerate all three entries, obtain audio, convert MP3 and generate a bounded preview. Record runtime versions, source errors, actual bytes/time/memory and APK size.
4. Tag/read back title/artist/source and a generated cover; build a verified ZIP. Export via native document/scoped-storage APIs and open it in a local player.
5. Repeat with network loss, app suspension/restart, cancellation, low storage and destination-picker cancellation. Check source-derived titles never become private path identities.

A pass requires independent acquisition/conversion/export on the actual phone. A desktop wrapper invocation or emulator compile is insufficient.

## iOS proof

1. Obtain Xcode/macOS build access and an actual iPhone test path. Neither is available now. A CI/simulator build can check compilation, but cannot prove device Files/export/background behavior.
2. Select an iOS-compatible extraction path and in-process codec/tag adapter. Python's desktop subprocess path is not available on iOS; do not assume the CLI or Android binaries run unchanged.
3. Build a minimal signed test app and run the same source/preview/tag/ZIP/document-export checks independently on the iPhone. Record network/source compatibility and actual lifecycle limits.
4. Establish personal testing versus public distribution requirements. Do not buy membership or claim zero-cost App Store release without a viable route and authorization.

This gate stays unresolved until real execution and file export are proven. The owner has not agreed to drop iOS.

## Laptop proof

Package the proven media tools/runtime with an app prototype and test on the intended OS. Check read/write permissions, playback, ZIP extraction and actual destination save on a clean installation. Do not depend on the development /tmp tools or DOT.'s virtual environment.

## Shared UI decision

Flutter is a candidate for shared responsive UI/domain code with native platform channels, but only commit to it after the media adapters can be called on the target OS. Contract/naming fixtures from the Python spike can be reused as test data; its desktop subprocess implementation is not automatically reused on every platform.

Primary references: [yt-dlp dependencies](https://github.com/yt-dlp/yt-dlp), [Android candidate](https://github.com/yausername/youtubedl-android), [Python subprocess platform availability](https://docs.python.org/3/library/subprocess.html), [Flutter iOS tooling](https://docs.flutter.dev/platform-integration/ios/setup), [Apple enrollment](https://developer.apple.com/programs/enroll/).
