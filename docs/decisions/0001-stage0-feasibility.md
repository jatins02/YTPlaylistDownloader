# Decision 0001: Stage 0 core proof and independent-device direction

Date: 2026-10-12. Status: **provisional; core desktop proof passed, native mobile feasibility remains open**.

## Decisions

The owner confirmed zero budget, independent Android/iPhone operation, laptop support and device-only saves, with no Mac/iPhone access. The earlier hosted pipeline and laptop-companion alternative do not meet that combination. Propose shared native UI/domain code with per-platform media adapters and local storage; Flutter is a candidate, not selected or proven.

Keep the bounded Python CLI as a reference contract/media spike. It performs real local source acquisition, conversion, tag verification and ZIP export; it is not a native app or an iOS-compatible runtime solution. Optional S3/container adapters remain future experiments only.

Use Groq openai/gpt-oss-120b as the initial configurable text-metadata model. It supports strict structured output and is listed on Groq's free plan, subject to quotas/account availability. No model is proven best for this playlist until actual naming is reviewed. The owner will provide a new key in the created .env. Never package that key in a shared native app; each user supplies a personal key through secure settings.

## Evidence

15 contract/media tests passed with real FFmpeg/ffprobe. Three synthetic runs passed. The owner's three-track playlist downloaded, decoded and exported in three fresh local runs, about 19–21 seconds each, with ~30 MB ZIPs. Exact metrics and runtime versions are in PROJECT_STATUS.md and STAGE0_RESULTS.json.

Synthetic cover embedding/readback passed; live online matching and Groq naming were not run without configuration. The live exports intentionally retain source titles and Unknown Artist fallback. Empty feature frames can be omitted by ID3 serialization, so the writer explicitly omits empty features and checks absent readback as empty. Version markers are retained in semantic titles and export names.

## Mobile risks to prove

The Android wrapper is only a candidate; inspect its current bundled Python/runtime/ABI support rather than trusting old documentation. Current yt-dlp needs supported Python plus EJS/JavaScript dependencies. The iOS adapter is unselected; desktop subprocess code is not portable proof. The historical FFmpegKit package is retired, so codec dependencies require maintained/source-build choices and actual device checks.

Without Mac/iPhone access, iOS build/device acceptance cannot be performed here. Public iOS distribution also has membership requirements. Keep the goal explicit rather than promising a free complete release. See STAGE0_NATIVE_SPIKES.md for the next per-platform checks.

## Completion decision

Stage 0 remains in progress until live AI/known artwork, independent native phone execution/file delivery, laptop packaging and measured distribution/device constraints are verified. No hosting, storage or paid API upgrade has been provisioned.

Sources: [Groq structured outputs](https://console.groq.com/docs/structured-outputs), [free limits](https://console.groq.com/docs/rate-limits), [yt-dlp dependencies](https://github.com/yt-dlp/yt-dlp), [Android candidate](https://github.com/yausername/youtubedl-android), [FFmpegKit status](https://github.com/arthenica/ffmpeg-kit), [iOS setup](https://docs.flutter.dev/platform-integration/ios/setup), [Apple membership](https://developer.apple.com/programs/enroll/).
