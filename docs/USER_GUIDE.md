# Private evaluation user guide

This is an evaluation of an unfinished native application. There is no public
production release. Linux x64 has automated real-media and export evidence;
manual listening, native save-panel and clean-device acceptance are pending.
Windows is a foundation evaluation. Android's CI APK is a foundation test build.
iPhone has no verified build. Neither phone currently supports the complete
independent workflow. The [handoff gates](STAGE9_GUIDE.md) remain authoritative.

## Install and start

Obtain the complete package and its checksum from a trusted maintainer. A hash
detects damage; it cannot identify a trustworthy publisher. Keep the full bundle
together. Do not download a random runtime or copy only the executable.

Follow [Stage 8 installation](STAGE8_GUIDE.md#linux-install-update-and-rollback).
Linux needs compatible GTK 3, GLib, SQLite, graphics, libsecret/Secret Service and
a working local PulseAudio/PipeWire session. Unlock the desktop keyring before
opening the app. Installing libsecret alone does not supply an unlocked keyring.
The package records its build OS/libc; another Linux distribution still needs
its own clean-machine test. A `foundation` package has no media runtime; use the
explicit `linux-media` evaluation package for real processing.

Use the same OS account for subsequent versions so the OS keeps the same private
drafts/settings and key vault. Close the app before switching versions. Retain
the previous package and back up important data. Equal-schema binary rollback
does not restore an older database. Never place packages in app-private storage.

Draft cards show local **Added** and **Last activity** timestamps plus up to
three original YouTube song names after enumeration, so repeated imports are
recognizable. Activity reflects draft processing/review updates, not a separate
processing-only timestamp.

## Set up your own AI key

Open **AI key settings** from the drafts or playlist screen. Add your own Groq
key and save it in OS secure storage. Native builds read no `.env` and contain
no shared developer key. Do not put keys in chat, screenshots, playlist text,
issue reports or commands. A keyring failure is visible; there is no plaintext
fallback. Saved drafts remain usable without a key.

**Naming settings** controls the Groq model ID and public artwork contact.
The configured default is `openai/gpt-oss-120b`; access depends on your account.
Use a public contact value, since artwork providers receive it in requests.
Naming sends bounded source title/uploader/duration text, not audio or your
private saved files. Artwork lookups contact MusicBrainz and Cover Art Archive.
The app needs network access for sources, naming and artwork, but no hosted
music library or app account.

## Process, review and save on Linux

1. Add a public or accessible unlisted YouTube/YouTube Music playlist URL.
   Private/login-required, age-restricted sources and endless mixes are outside
   the supported evaluation scope. The current limits are 100 occurrences,
   **10 unique tracks**, 600 seconds per track, 50 MiB per media file,
   512 MiB per private job, 1 GiB managed workspace and a 64 MiB free-space
   reserve. An oversized list fails rather than silently losing songs. Maximum
   sizes are ceilings, not a promise that every combination fits together.
2. Prepare the playlist and keep the app open. Work runs locally. Failed entries
   remain visible and playable peers remain available. Duplicate occurrences
   retain their order but download/export one MP3 per unique source by default.
3. Use **Prepare / retry names and covers** if enrichment needs another attempt.
   Check uncertain names and version markers (live, remix, slowed, clip, etc.).
   Missing evidence keeps the source-title/Unknown Artist fallback or a neutral
   cover; the app does not invent a recording identity.
4. Listen to the single active preview and edit names, artists, features or
   covers. Snippets are at most 30 seconds; they start at 30 seconds for tracks
   over a minute and at zero otherwise. Explicit **Save** commits edits;
   cancellation preserves the previous values. Human choices win over later AI
   responses. Include/exclude deliberately; retry or exclude unavailable audio
   before final preparation. Close any open editor before exporting. You do not need
   to review every name to download: **Fill missing details when saving** is on
   by default. It keeps source titles/existing edits, uses `-` for missing artists
   in exported files and leaves optional album/features/covers empty. Stored
   uncertainty and human edits remain unchanged. Turn it off to require naming
   review before saving.
5. Choose **Save to Device**, then wait for full-length tagged files and their
   ZIP manifest to be verified. This is still private preparation. Choose
   **Save ZIP** or **Save MP3** and select a local destination in the native
   panel. Only a confirmed saved-copy message means destination delivery
   completed. These are full MP3s, not previews. Requested 320 kbps encoding
   cannot improve the original source quality.
6. Existing destination files are never overwritten. Select a new name when
   needed. Use a local filesystem with hard links and user extended attributes;
   unsupported filesystems must be changed, not bypassed. Saving does not
   automatically import music into another application's library. Use **Return
   to review** before changing the frozen selection or metadata.
7. After saving an MP3, that song shows **Downloaded** and its save/selection
   controls are disabled. **Choose remaining songs** reopens review and selects
   the ready songs without confirmed download receipts. Prepare and save those
   as another ZIP or individual MP3s. A confirmed ZIP marks every included song
   downloaded. Cancellation/failure does not mark anything downloaded. This
   history survives reopening; the app does not scan or manage your saved copies.

The **fictional demo** is separate: demo previews and save messages never fetch,
play or save real audio. It is not a device acceptance test.

## Failures and recovery

| Situation | Action and retained state |
| --- | --- |
| No key, invalid key, unavailable model or exhausted AI quota | Correct settings or wait for the provider allowance/cooldown, then explicitly retry names/covers. Audio and human edits stay available. No paid model/provider is selected automatically |
| Uncertain name or unavailable/ambiguous cover | Review the visible fallback, enter a name or choose/remove a cover, then save the edit. A matched identity alone does not prove downloaded cover bytes |
| Source/extractor or network failure | Restore connectivity and use **Retry failed tracks**. Unavailable entries stay visible; explicitly exclude them if saving peers. Upstream changes may require a tested maintainer update |
| Changed private audio | Use **Recheck audio**, then retry the affected track; review metadata is retained |
| Save-panel cancellation, denied permission, full disk or unsupported filesystem | Preparation remains recoverable. Free space or select another local destination and retry. Do not treat a closed panel as success |
| App stopped, suspended or closed | Checkpoints retain committed review and processing boundaries. Reopen and resume/retry; uninterrupted background completion is not promised. Unsaved editor changes are cancelled on restart |
| Crash near the end of delivery | A complete external file may exist before its receipt was persisted. Inspect it and choose a new filename on retry; the app does not overwrite it or invent a receipt |

The app is temporary workspace software, not a permanent music library. Private
media normally expires 48 hours after the draft was created when the app next runs its cleanup;
active processing/export and open edits are protected. Metadata/committed edits
and external saved copies survive private cleanup. Edits/resume do not reset the
retention window. Add the playlist as a new draft to prepare expired audio again.
Do not rely on previews or internal paths as backups.

For support, report app/package ID, platform/runtime versions, the failing action
and sanitized error category. Exclude API keys, `.env`, databases, private paths,
signed media URLs, raw provider responses and personal music. See the
[maintenance process](MAINTENANCE.md) for tested compatibility changes.
