# Product specification

Revised 2026-10-12. Confirmed: zero budget; Android and iPhone must work independently; laptop support; device downloads only. A native app direction is proposed, pending per-platform proof. No Mac/iPhone is currently available. See IMPLEMENTATION_PLAN.md and ARCHITECTURE.md.

## Required journey

Paste a public/unlisted YouTube playlist → on-device acquisition/conversion → AI naming and album-cover lookup → listen to snippets and edit names → final Save to Device → full-length tagged MP3 files and/or ZIP at a user-selected destination.

No hosted worker or laptop companion is required for an independent phone. No account, cloud library or cross-device sync is included. Local drafts/settings are allowed; they do not turn the app into a permanent music-library product. The app can open without a hosted service; new downloads/AI/artwork still require internet.

## Default behavior

- Public/unlisted accessible YouTube and YouTube Music playlists; no login-cookie collection, private/age-restricted streams or infinite mixes initially.
- Best available audio converted once to MP3, requested 320 kbps. Source quality remains the ceiling.
- Original playlist order; repeated video acquired once per job, repeated occurrences visible and one exported copy by default.
- Snippet up to 30 seconds starting at 30 seconds; short tracks start at 0. One snippet plays at a time after a gesture.
- AI metadata keyed by stable track ID, original data retained, uncertainty visible and human corrections authoritative.
- Cover search through recording/release metadata; select reliable front artwork, retain provenance, show a neutral placeholder otherwise.
- Final save snapshots ready selected tracks and edits, embeds title/artist/features/known album/front cover, verifies files, and exposes native save/share/document actions.
- ZIP and individual MP3 export; handle cancellation, denied permissions and low storage honestly. No automatic insertion into every native Music library is promised.

Initial production capacity targets remain 100 unique tracks, 20 minutes/track and 2 GiB source/export ceilings, but are **unproven on phones** and must be reduced or confirmed from Stage 0/7 measurements. The feasibility CLI deliberately accepts only 3–10 entries, 10 minutes/track and a bounded scratch workspace. Do not silently truncate a larger playlist.

## Naming and editing

Store title, primary artists[], featured_artists[], optional album/version and a review flag separately. Render `<song name> - <artist> - <features>.mp3`; omit the last separator when features are empty. Preserve Unicode and meaningful live/remix/slowed/verse-only markers. Unknown artist stays explicitly Unknown Artist; model confidence is not proof.

Export filenames are sanitized, byte-bounded and collision-safe; semantic metadata is not truncated. Example: Moonlit Train - Mira Vale - Jun Park.mp3. Original source titles remain available during review. Editing uses visible fields, live filename preview and explicit Save/Cancel. Pending saves block finalization; errors retain user text; stale revisions do not silently overwrite.

## Progress and partial failures

Show real counts/phases, per-track states, cancellation and eligible retries. Do not fabricate percentages. Unavailable rows remain visible. Failed AI/artwork retains playable audio and asks for review. The user explicitly excludes failed items before final save; omission counts must be visible.

Respect device suspension: persist checkpoints and resume when the OS permits. Do not promise continuous processing in every background/locked-screen state. Final save creates verified private artifacts before copying to the chosen destination; incomplete writes are never marked successful.

## Credentials, storage and cleanup

The development .env belongs only to this project. Each native user supplies their own AI key, stored through OS secure storage and never embedded in shared binaries. Send bounded textual source metadata to Groq; no audio, private links or cookies. The initial model is openai/gpt-oss-120b, configurable and subject to the account's free quotas.

Use private per-job temporary storage with bounded retention, cleanup and resource limits. Remove scratch/unreferenced artifacts; preserve user-exported copies. Local retention defaults can follow the original 24-hour draft/export preparation windows with a 48-hour maximum, but device shutdown delays cleanup until the app can run again. Explain this honestly rather than pretending a server scheduler exists.

## Visual and accessibility requirements

Professional restrained lavenderblush palette, white surfaces and near-black accents. Responsive native layouts across phone/tablet/laptop; visible touch play/edit actions; readable large text; accessible labels/focus; reduced motion. See DESIGN_SYSTEM.md, adapting CSS concepts to native tokens/widgets.

## Explicitly unresolved/deferred

Native extraction/conversion/export on both phones, iOS build/device/distribution access, final framework selection, public-store release costs and laptop packaging remain feasibility gates. No cloud library, shared developer AI key, video downloads, automatic sync, paid infrastructure or phone-on-LAN substitution is included.
