# Stage 0 feasibility harness

This CLI validates the risky media/provider path before the native application is built. It creates no cloud resources. Real calls are explicit, optional and require configuration. **A local synthetic or desktop live pass does not prove independent Android/iPhone operation or complete Stage 0.**

## Implemented checks

- Runtime preflight with actual versions and configuration-presence booleans; secret values are not printed.
- Three distinct synthetic tones, including duplicate final names and a Unicode name.
- Real FFmpeg MP3 generation/conversion, bounded snippets, full-audio decoding and ffprobe duration checks.
- ID3v2.3 title/artist/features/album/source/cover write and readback using Mutagen.
- Stable-ID, schema-validated naming; missing/extra/duplicate records rejected independently of provider order.
- Collision-safe portable filenames and a checksum-verified ZIP containing MP3s and `playlist.json`.
- Opt-in live playlist extraction, Groq formatting, exact title/artist/release artwork matching, and private S3 upload/download checks.
- Reports with per-check timings, sampled process-tree memory/CPU, scratch-space peaks, payload-byte measurements and explicit unrun gates.
- Bounded error output and a narrowly scoped storage-cleanup command.

No local database, native UI or platform task service is implemented at this stage. The harness is sequential and intentionally caps a live playlist at 3–10 entries, tracks at 10 minutes and source objects at 50 MiB. Scratch data is capped at 256 MiB while acquiring, and 512 MiB during local media work. This is smaller than the planned production capacity.

## Local setup

Use Python 3.14 (the version exercised here), or validate the lockfile against another supported interpreter before relying on it. Create a new environment belonging to this project:

```bash
python -m venv .venv-stage0
source .venv-stage0/bin/activate
python -m pip install -r requirements-stage0.lock
```

Windows activation: `.venv-stage0\Scripts\Activate.ps1`. Install FFmpeg **and ffprobe**, and Deno 2.5.4 or another currently supported runtime. This execution prepared an ignored .venv-stage0 and Linux-only .tools-stage0/bin in the project, so activating that environment is enough on this machine. These machine-local binaries are not portable phone/Windows packages. The CLI checks project-local .tools-stage0/bin after configured paths/PATH. On a clean checkout, either put the correct platform binaries on PATH or set `FFMPEG_BIN`, `FFPROBE_BIN` and `DENO_BIN` to executable paths. Do not reuse DOT.'s environment or credential file.

```bash
python -m stage0 preflight
python -m unittest discover -s tests -v
python -m stage0 synthetic --runs 3
```

`synthetic` uses fictional metadata and a generated lavenderblush image. It does not call Groq, MusicBrainz, YouTube or storage unless `--with-storage` is explicitly supplied. Media integration tests require the actual binaries; a skipped test is not a pass for its gate.

## Container setup

```bash
docker build -f infra/Dockerfile.stage0 -t ytpd-stage0 .
docker run --rm ytpd-stage0 preflight
docker run --rm --entrypoint python ytpd-stage0 -m unittest discover -s tests -v
docker run --name ytpd-stage0-synthetic --mount source=ytpd-stage0-runs,target=/work/stage0-runs ytpd-stage0 synthetic --runs 3
docker cp ytpd-stage0-synthetic:/work/stage0-runs ./stage0-runs
docker rm ytpd-stage0-synthetic
```

The named volume is writable by the image's nonroot user. It retains artifacts after a container stops. Clean up the named volume after collecting evidence. The Docker recipe has not been built in this execution environment because Docker is unavailable. Dependency pins are recorded in `requirements-stage0.lock`; base-image digests and OS packages are not yet locked. Record the actual image/tool versions when building, and pin the validated image before hosted testing.

## Live configuration

The requested `.env` already exists with an empty GROQ_API_KEY and the selected model. Paste your key there. The local CLI loads only this project file; existing environment variables take priority. For an optional container/storage experiment, copy `.env.stage0.example` to ignored `.env.stage0` and configure a private S3-compatible bucket. Set `MUSICBRAINZ_CONTACT` to the project's public URL or a suitable contact identifier. Docker supports `--env-file .env.stage0`; local execution automatically reads this project’s `.env`. No parent/sibling credential file is read.

Do not put populated keys, signed URLs or downloaded media into chat, commits or public issue reports. Preflight prints presence only. Configure a **one-day expiration lifecycle for the `stage0/` bucket prefix before uploads**; the harness does not modify your bucket policy. The live check creates objects only inside that prefix, rolls back its own uploads on failure, and offers explicit cleanup after device tests.

For an optional hosted experiment, run the following with a small test playlist you are permitted to download:

```bash
python -m stage0 live --playlist 'https://www.youtube.com/playlist?list=YOUR_PLAYLIST_ID' --runs 3 --with-ai --with-artwork --with-storage --host-label render-stage0 --host-region YOUR_ACTUAL_REGION
```

All three runs acquire fresh files into unique directories. A success on this development machine is not evidence for Render or any other deployment network. The host label/region are operator assertions recorded as such; collect provider deployment/network evidence separately.

To check known cover matching independently of playlist identification:

```bash
python -m stage0 cover-check --title 'KNOWN_RECORDING_TITLE' --artist 'KNOWN_ARTIST' --album 'KNOWN_ALBUM'
```

Use a known recording/release pair, then verify the returned recording/release IDs and cover visually. No reliable exact match produces a failed/uncertain check, not a guessed image. The sequential MusicBrainz limiter is sufficient for this one-process harness; a fleet-wide limiter remains Stage 4 work. Provider redirects are bounded and checked against trusted hosts and public addresses; production network/egress enforcement remains separate.

Groq is called once per run with no SDK retries. Provider/schema failure retains source-title fallback, but the report marks that AI check failed. Enrichment failures cannot silently count as full Stage 0 completion. Model schema support, limits and availability still need an actual configured-provider check.

## Reports and private delivery artifacts

Every processing run writes `stage0-runs/<opaque-run-id>/report.json`. Read `checks`, `metrics`, and `mode`; `stage0_complete` deliberately remains false pending live-provider and real native-platform/device evidence.

For storage tests, the report contains object identifiers/checksums, but no signed URLs. Short-lived URLs are written into **`device-links.private.json`**, with restrictive file permissions on Unix. This file is ignored. Open it privately to obtain the MP3 and ZIP links for phone/laptop checks; links expire after ten minutes. Do not publish it or serve the entire output directory publicly.

Check direct download and ZIP extraction on a real phone and laptop; confirm full-length audio, title/artist and actual embedded cover in a compatible local player. Record device/browser versions and observed behavior using [the evidence template](STAGE0_DEVICE_EVIDENCE.md). The harness can verify byte delivery to its own process, but cannot prove a phone saved the file or inserted it into a native music library.

After device checks, use the corresponding run report:

```bash
python -m stage0 cleanup-storage --report stage0-runs/RUN_ID/report.json
```

This deletes only keys under that report's exact run prefix. Delete local private links and media when finished. Failed cleanup must be recorded and the bucket lifecycle verified; neither a subprocess exit nor this CLI is a production retention scheduler.

## Benchmark interpretation

Metrics sample every 100ms. Very short children may be missed, so CPU/RSS values are sampled estimates. The downloader reports its maximum payload counter when available; this excludes retry traffic, metadata requests and transport overhead. Groq reports actual returned token usage. Artwork and verified object delivery count received payload bytes. Missing measurements remain null/not-run, not fabricated estimates.

Local synthetic clips of a few seconds are useful correctness checks, not estimates of full playlist cost. Assess actual worker RAM/disk/CPU and storage bandwidth on the hosted three-run test before approving the proposed budget.

## Remaining Stage 0 gates

1. Live Groq response with exact ID mapping, actual token consumption and a semantic review of modified recordings.
2. Verified known online recording/release/front-cover match and embedded cover.
3. Actual standalone Android acquisition/conversion/file export with the current native runtime dependencies.
4. Actual standalone iPhone equivalent; build/device access is currently unavailable.
5. Laptop application packaging and real device/player evidence, beyond this CLI.
6. Measured native device limits and a distribution/install route that fits the budget.

The three local live source runs are complete; hosted storage is optional under the revised native direction. It is not necessary to purchase or configure cloud storage for the baseline. An iOS compile or desktop report cannot replace actual phone proof.

Once you paste the Groq key into .env, test naming against an existing live-run report without downloading again:

```bash
python -m stage0 metadata-check --report stage0-runs/LIVE_RUN_ID/report.json
```

The output includes validated suggestions and token usage in a local report, never the API key. The initial model is openai/gpt-oss-120b on Groq; free account quotas are limited, and configured-account/model availability must be verified.

## Primary integration references

- [yt-dlp configuration and dependencies](https://github.com/yt-dlp/yt-dlp)
- [yt-dlp JavaScript runtime requirements](https://github.com/yt-dlp/yt-dlp/wiki/EJS)
- [Groq structured outputs](https://console.groq.com/docs/structured-outputs)
- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API)
- [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API)
- [FFmpeg downloads](https://ffmpeg.org/download.html)

Recheck upstream behavior when changing versions. The initial local result and its limits are in [the Stage 0 decision record](decisions/0001-stage0-feasibility.md).
