# Stage 6: verified full MP3 and ZIP saves

Stage 6 adds private export publication and destination delivery to the real
processing/review route. Its Linux implementation uses the existing pinned
FFmpeg/Mutagen/Pillow runtime and `file_selector: 1.1.0`; it adds no cloud service,
account, paid dependency or shared API key. Windows/Android/iOS export adapters
remain disabled until their own media and device execution gates pass. Desktop
checks do not complete the plan's actual Android/iPhone acceptance requirement.

## Save a reviewed playlist

1. Prepare audio and review names/covers with the Stage 3–5 runtime. Resolve
   selected metadata warnings and explicitly exclude unavailable items. Repeated
   source occurrences remain visible but produce one MP3 per unique track.
2. Choose **Save to Device**. Preparation freezes the current selection,
   metadata and exact audio/cover IDs. Open edits or unfinished preparation block
   this action. Keep the app open while full MP3 derivatives and ZIP are verified.
3. When files are ready, choose **Save ZIP** or a track's **Save MP3**. The native
   Linux save panel lets you choose a local destination and filename. ZIPs contain
   all selected full MP3s and `manifest.json`; individual saves use the same
   verified full derivatives.
4. A saved-copy message appears only after the destination confirms the complete
   verified bytes. Cancelling the panel or denying permission keeps preparation
   available for retry. Existing files are never overwritten: choose a new name.
5. **Return to review** unlocks edits/selection. A later preparation freezes the
   changed revision. Repeated saves of an unchanged prepared review reuse its
   completed snapshot, filenames and verified private bytes.

If original audio changed, **Recheck audio** diagnoses the affected track; then
**Retry failed tracks** rebuilds it from retained processing boundaries. Human
metadata/cover choices and playable peers remain intact.

Saving files does not promise automatic insertion into every Music application.
Private preparation alone is not a successful device save. Exported external
copies survive private expiry/discard; the app is not a permanent music library.

## Integrity and state

Schema v6 appends `export_publications` and `export_deliveries`; historical
migrations are unchanged. An export attempt owns its frozen snapshot and current
generation. All file, archive, manifest and metadata verification must finish
before one transaction publishes the record, completes the attempt and moves the
job to `exportReady`. A status/phase update alone cannot replace publication.
Stale workers cannot publish after Stop, recovery or cancellation. Interrupted
preparation returns to the retained review and freezes a new revision on retry.

Tagged MP3s are new derivatives verified by the Stage 4 adapter: full decoding,
duration, encoded audio preservation, ID3v2.3 fields and exact embedded APIC bytes.
Source and snippet assets are unchanged. Filenames preserve Unicode/version/
feature distinctions, omit empty feature separators, reject unsafe path syntax,
protect reserved device names and stay within 184 UTF-8 bytes. NFC names with
NFKC/casefold collision checks and bounded suffixes preserve equal-name audio.
Semantic metadata is not truncated.

The bounded native worker streams ZIP creation and verification. Entry sets,
unique portable names, regular-file type, storage method, uncompressed length,
CRC, SHA-256 and exact manifest bytes must agree. Extra/duplicate/truncated/
changed entries or loose derivatives fail visibly. Published bundles use only
job/export/file UUIDs under private `jobs/<job>/exports/<export>/` directories;
titles never locate bytes. Files and containing directories are fsynced before
publication. Startup removes unpublished private bundle orphans.
Every reuse/delivery rechecks immutable file hashes and the ZIP contents.

## Native delivery and interruption

Linux delivery copies through a guarded worker off the UI thread. A random
exclusive `.ytpd-<delivery UUID>.part` file is created beside the selected
location, with mode 0600 and an ownership nonce stored in an extended attribute.
The private SQLite journal records intent before creating the empty staging file,
then binds its exact device/inode before payload copying. An interrupted intent
without a bound inode can clean only a matching random ownership nonce. Streamed
checksums, length and fsync/readback finish before a no-clobber hard link atomically
publishes the verified open inode. A destination
file appearing during transfer causes an error rather than replacement.

Ordinary failure/Stop removes only the owned staging file. Restart fences
unfinished deliveries and cleans only journalled staging identities with the
matching nonce; it never scans Downloads or deletes a destination copy. A crash
after publication but before receipt persistence may leave a complete external
file with an interrupted receipt; the app does not invent success or overwrite
that file on retry. The frozen private export remains available.

The destination must be a local filesystem supporting hard links and user
extended attributes. Unsupported filesystems fail safely with an actionable
choose-another-location error. The save adapter rejects app-private destinations,
symlinks at file endpoints and wrong extensions. Chosen paths stay in private
recovery records, never ZIP manifests, provider inputs or user-facing error logs.
No arbitrary desktop path adapter is enabled on phones; Android document APIs
and iOS document/share APIs still require their own native implementation/proof.

## Limits and cleanup

The existing proven defaults remain ten unique tracks, 600 seconds/track,
50 MiB per media file, 512 MiB per private job, 1 GiB per workspace and a 64 MiB
free-space reserve. Archives may aggregate up to the smaller of the job limit
and runtime track capacity (`maxFileBytes * maxTracks`); MP3/source/snippet
file caps are unchanged. Temporary duplicates and archive bytes count toward the
job/workspace limits. Destination free space is checked independently, and
mid-write disk/permission failures preserve recovery. These limits are not phone
capacity evidence or a promise that every maximum-size combination fits.

Preparation has the existing job deadline, individual workers have bounded
operation deadlines, and Stop fences before terminating processes. Active
preparation/delivery and open review tokens prevent retention from deleting their
private job bytes. Cancelling a completed export fences pending delivery before
allowing private discard; saved external copies remain intact.
Unpublished scratch is cleaned safely; completed private bundles follow the
job's bounded retention/discard lifecycle. Cleanup never removes exported copies.

## Reproduce checks

Use the exact SDK and isolated/provisioned Linux prerequisites in Stage 1, plus
the pinned project-only Stage 3 media manifest. Ordinary tests use synthetic
state and do not invoke providers or the owner's `.env`.

```bash
cd apps/native
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze --no-pub
flutter test --no-pub
# Additionally execute the real media/image/tag/archive/delivery tests:
STAGE3_TEST_RUNTIME=/absolute/path/media-runtime.json flutter test --no-pub
```

From the repository root, with the pinned Flutter bin on PATH:

```bash
STAGE3_TEST_RUNTIME="$PWD/.tools-stage3/media-runtime.json" \
  .venv-stage0/bin/python scripts/test_linux_native.py --test export_test.dart
PATH="$PWD/.tools-stage0/bin:$PATH" .venv-stage0/bin/python -m unittest discover -s tests -v
```

The native acceptance uses actual Linux plugins, OS vault with a unique synthetic
credential, SQLite, 65-second distinguishable tones, real tags/covers, ZIPs,
external file transfer, restart and private cleanup. Its destination chooser is
injected with test-owned paths; manual native-panel interaction and physical
player/device acceptance are separate gates. No live source/provider request is
needed. Opt-in `STAGE6_SCREENSHOTS=<absolute output>` runs the readable fictional
stored-record renders in `test/export_widget_test.dart`; these do not prove phone
or native destination interaction. Actual results are in PROJECT_STATUS.md.

Reviewed fictional stored-record renders: [desktop](stage6/screens/export-desktop.png)
and [narrow viewport](stage6/screens/export-phone.png). The latter is a Flutter
layout render, not evidence from a physical phone.

The [Stage 5–6 review](CODE_REVIEW_STAGE56.md) records additional playback,
retention, cancellation and cleanup regressions. Recovery rejects special-file
replacements without blocking; orphan cleanup does not recreate discarded jobs.
