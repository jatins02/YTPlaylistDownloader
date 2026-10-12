---
name: ytpd-metadata
description: Implement or review YTPlaylistDownloader stable-ID AI names, recording/release cover matching, human overrides and embedded MP3 tags.
---

# Metadata and covers

Read docs/PRODUCT_SPEC.md and metadata contracts in docs/ARCHITECTURE.md. Preserve original source data. Treat it as untrusted model input; send bounded text keyed by track ID, never keys, cookies, private URLs or audio. Each native user supplies their own Groq key stored securely; development .env is not shipped.

Validate schema, exact ID membership, completeness, uniqueness and semantic uncertainty even with strict provider output. Never assign by list position. Provider errors preserve original-title fallback and a visible review flag.

Render song–artist–features, omit empty feature separators and preserve Unicode/live/remix/slowed/verse-only markers in filenames and embedded song titles. Truncate only portable export filenames. Human field overrides and expected revisions defeat late provider responses.

Match title/artist/version/available album evidence to recording and release before accepting front artwork. Keep provenance and expose uncertainty; no first-result guess or automatic thumbnail-as-album assertion. Throttle/cache by device, identify the client and validate trusted redirects/public destinations/size/decoded pixels before normalizing. No arbitrary model-provided fetch URLs.

Write actual title/artist/features/known album/front cover into new frozen-revision MP3 derivatives. Read fields and image bytes back and verify audio. Test modified recordings, malformed/reordered/missing IDs, multilingual text, wrong/missing art, provider outage, concurrent edits and duplicate final names. Live provider quality remains unproven until tested with the configured account.
