# Stage 4: naming, front artwork and verified MP3 tag adapters

Implemented for the proven **Linux development runtime** on 2026-10-15.
The native naming/artwork workflow and frozen-revision tag adapter exist and
have offline behavior, actual-codec and Linux native execution evidence. Live
Public artwork and configured Groq naming acceptance passed on 2026-10-15
after the owner authorized the remaining live checks and supplied the key in
this project's `.env`. Windows, Android and iOS media/tag execution remain
unproven. Those gates prevent claiming full multi-platform Stage 4 acceptance.

## Use the native workflow

Follow [Stage 1](STAGE1_GUIDE.md) and [Stage 3](STAGE3_GUIDE.md) setup with the
exact SDK and media runtime. The same project-local Python environment also
needs **Mutagen 1.48.1 and Pillow 12.3.0**, already pinned in
`requirements-stage0.lock` and recorded in `toolchain.json`. Startup checks
those versions before enabling naming/covers/tagging. Missing metadata tools
leave the Stage 3 audio adapter, drafts and key settings usable.

1. Configure `YTPD_MEDIA_RUNTIME` with `scripts/configure_media_runtime.py`.
2. Start the Linux app in an unlocked Secret Service/keyring session.
3. Open **AI key settings** on the drafts or playlist screen and store your own
   Groq key. The native app reads no dotenv file, and embeds no developer key.
4. Open a playlist and process it. After full audio and snippets are verified,
   the app attempts names and covers for each prepared unique track.
5. Review the displayed names, original titles, needs-review flags, independent
   naming/artwork errors and verified cover thumbnails. Without a key, audio
   remains ready and the missing-key warning stays visible.
6. Use **Prepare / retry names and covers** after correcting a key, waiting out
   quota errors or restoring connectivity. Accepted peers are retained. Changed
   cover bytes are verified and rebuilt on explicit retry without repeating
   accepted naming.

**Naming settings** selects the Groq model and public artwork contact. The
default is `openai/gpt-oss-120b`, with the public project URL in the identifying
User-Agent. Settings affect future attempts; completed names are retained.
Unsupported model/account permissions and free-quota exhaustion fail visibly
rather than silently selecting another model or provider. No paid provisioning
or app account/cloud library is required.

**Listening, persistent review editing, ZIP publication and Save to Device are
Stages 5–6.** Stage 4 does not expose these operations as completed capabilities.
The fictional Stage 2 journey remains isolated from real jobs, providers and
files. Human metadata/cover override persistence APIs are exercised by tests;
the real editor/cover chooser belongs to Stage 5.

## Naming contracts

Native prompt version `native-stage4-v1` / response schema version `1`.
One request contains at most ten bounded original source records, keyed by
immutable track ID. Only title, optional uploader and measured duration are
sent. URL/key-shaped text is redacted; audio, cookies, source URLs and private
file paths are never provider inputs. Authorization comes from the OS vault.

Strict provider output is also validated locally: exact ID membership and
completeness, uniqueness, fields, types, text bounds, artist arrays, uncertainty
and untruncated completion/refusal status. A malformed batch applies no partial
positional mapping. Missing version/clip markers preserve the original title,
unknown artists and a review reason. Unicode semantic fields remain untruncated;
display names omit empty feature separators. Portable export filename
allocation remains Stage 6 work.

Publication requires the current enrichment attempt token and captured track
revision. Prior human field overrides are excluded from AI merging. An edit
made during the request rejects the stale candidate; a deliberate artwork
choice/removal defeats a late image. Original source/channel evidence is not
rewritten. Failure keeps verified full audio/snippets and a visible review flag.

## Artwork identity and transport

A cover requires a unique exact title/version and credited-artist recording
match, validated recording details, a single matching release and one approved
front image. A known album title cannot select among release editions. Unknown
artists, uncertain names, changed versions, ambiguous/missing recordings,
releases or approved fronts produce a neutral placeholder and an explicit
reason. No thumbnails are asserted to be album covers, and no AI URL is fetched.
A uniquely verified release may fill a missing album only if a human has not
explicitly overridden that field.

Requests use identifying User-Agent, persisted device request slots and quota
cooldowns. MusicBrainz requests are separated by at least 1.1 seconds; artwork
requests are serialized as well. There are no automatic provider retries.
Requests have 45-second total deadlines, bounded DNS/connect times and bounded
decoded response bytes. Redirects are bounded and revalidated; authorization
never follows a redirect. HTTPS sockets use validated public DNS addresses,
preserve TLS hostname verification and bypass ambient proxy routing.
The custom socket factory explicitly completes TLS before returning a socket;
TCP address pinning alone does not make Dart's custom factory secure.

Artwork destinations are restricted to Cover Art Archive and Internet Archive
hosts. Legacy default-port HTTP image links from those providers are reconstructed
as HTTPS before requests; alternate ports, user credentials, fragments and
untrusted hosts stay rejected. Recording requests stay on MusicBrainz. A capped
25-release subquery without total-count evidence cannot prove unique identity.
Raw images are capped at 5 MiB,
8 million pixels and 8192 pixels per axis. Animated, truncated, unsupported or
unsafe images are rejected. Pillow runs in the guarded Linux worker, strips
image metadata and normalizes to a JPEG no larger than 768 pixels per axis and
1 MiB. UI thumbnails use the verified normalized bytes.

Cache entries retain recording/release identity, matched title/artists, album,
public source URL, matcher version, verification time, dimensions and checksum.
The cache holds at most 16 images / 16 MiB of logical image payload, plus SQLite
and WAL overhead; entries expire after 24 hours and are pruned at startup and
Linux retention checks. Cached checksums/provenance and actual JPEG decoding are
verified before reuse. Job cover assets remain private, immutable ID-based
files and follow Stage 3's bounded job retention. Cleanup affects no device-
exported user copies. Identity edits invalidate automatic covers while keeping
human cover/removal choices.

## Tagging contract and execution boundary

`NativeTagAdapter.prepare` accepts an integrity-checked frozen `ExportSnapshot`,
a stable track ID and a private work directory inside that job. It selects
exact frozen audio/cover asset IDs and verifies their managed paths, sizes and
checksums. The snapshot now captures active artwork IDs/manifests alongside
metadata and full audio; creating it does not publish an export.

The guarded worker writes a new full MP3 derivative with ID3v2.3 `TIT2` (semantic
title/version), `TPE1`, optional known `TALB`, nonempty `TXXX:FEATURED_ARTISTS`,
`TXXX:SOURCE_VIDEO_ID`, canonical `WOAS` and optional front-cover `APIC`. It reads
all fields and the **actual embedded image bytes** back, verifies source and
snapshot identity, and compares every encoded audio byte before/after tagging.
The adapter additionally fully decodes the resulting MP3, compares duration and
checks source/cover/file hashes. Source and snippet bytes are never retagged or
renamed by title. Equal display names retain distinct audio and private IDs.

Linux `canTag` is enabled only with verified metadata tools and actual execution
evidence. `canExport` stays false; the adapter returns a verified private file,
not a published ZIP or successful destination save. Stage 6 must own export
attempts, publication, manifests, recovery and destination transfer.

## Reproduce checks

From `apps/native`, with the pinned SDK on PATH:

```bash
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze --no-pub
flutter test --no-pub
STAGE3_TEST_RUNTIME="$YTPD_MEDIA_RUNTIME" flutter test --no-pub
```

The default suite sends no provider requests. Real-codec/tag tests opt in with
the existing verified Linux runtime manifest; all audio/images and provider
responses in them are fictional fixtures.

From the root:

```bash
PATH="$PWD/.tools-stage0/bin:$PATH" .venv-stage0/bin/python -m unittest discover -s tests -v
python3 scripts/test_linux_native.py
STAGE3_TEST_RUNTIME="$YTPD_MEDIA_RUNTIME" python3 scripts/test_linux_native.py --test pipeline_test.dart
STAGE3_TEST_RUNTIME="$YTPD_MEDIA_RUNTIME" python3 scripts/test_linux_native.py --test enrichment_test.dart
```

The Stage 4 native test uses the real OS keyring with a unique synthetic key,
actual private SQLite/files, image/ID3/codecs, UI and restart recovery. Provider
HTTP boundaries use fictional replies and do not prove live provider quality.

Opt-in development provider acceptance, from the root:

```bash
export YTPD_MEDIA_RUNTIME="$PWD/.tools-stage3/media-runtime.json"
.venv-stage0/bin/python scripts/test_stage4_live.py --live
# Independent public artwork/embedded-cover check, with no Groq key:
.venv-stage0/bin/python scripts/test_stage4_live.py --live --artwork-only
```

Configure only this project's `.env` or `GROQ_API_KEY` for this **development
command**. It passes the key to the native Dart acceptance tool through stdin,
never argv, child environment, temporary files or reports. The native release
continues to use the OS vault. `--sources /path/to/bounded-source-records.json`
can supply an explicit 1–10 record fixture. The default known/modified/unknown
benchmark reports ID validation, version preservation and quality outcomes;
failed quality checks do not return a passing exit code. Artwork uncertainty is
reported honestly and cannot stand in for a successful known-cover check.
Both modes additionally check the curated public recording **Foley — Patricia
Taxxon**, release **Foley Artist**, through the production matching/transport
adapters. The known recording/release IDs must match; the downloaded image is
normalized and embedded into a synthetic MP3, with exact APIC readback and full
audio decoding. No real recording is downloaded by this check. A combined run
requires both naming quality and that known-cover proof to succeed; artwork-only
success does not imply Groq acceptance.
No live request is made without `--live`.

Actual results and unresolved gates are recorded in [PROJECT_STATUS.md](PROJECT_STATUS.md)
and [STAGE4_RESULTS.json](STAGE4_RESULTS.json); the public live check is in
[STAGE4_LIVE_RESULTS.json](STAGE4_LIVE_RESULTS.json). New Stage 4 code has not been
executed in GitHub CI in this work; previous foundation CI is historical evidence.

Primary protocol references: [Groq structured output](https://console.groq.com/docs/structured-outputs),
[Groq API](https://console.groq.com/docs/api-reference),
[MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API),
[MusicBrainz pacing](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting),
[Cover Art Archive](https://musicbrainz.org/doc/Cover_Art_Archive/API),
[Dart socket factory](https://api.dart.dev/dart-io/HttpClient/connectionFactory.html).
