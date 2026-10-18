# Whole-project implementation review

Reviewed 2026-10-18 from main `16e18f6`. The review covers the Stage 0 harness,
native domain/repositories/controllers, source/codec/process and metadata/tag
adapters, review/save UI, filesystem lifecycle, packaging/handoff helpers,
CI/test contracts and current/historical documentation. It preserves exact pins,
schema v6 and the platform execution gates. No personal key or source media is
used in the regression tests.

## Confirmed defects and corrections

| Defect reproduced before correction | Resulting behavior and regression |
| --- | --- |
| Native/CLI codecs accepted a local HLS manifest while decoding bytes from a different file | Standalone-container and `file,pipe` protocol allowlists apply before probing/decoding/conversion/snippets; verified MP3 playback also forces the MP3 input format. Real-codec regressions reject manifest substitution and retain normal MP3/M4A/WebM support |
| CLI's audio probe accepted a video with no audio | Require exactly one audio stream and fully decode the selected audio stream; a generated video-only MP4 is rejected |
| Provider authorization detection depended on header casing and retained a mutable caller map across awaits | Snapshot headers and match authorization case-insensitively before DNS/network work; cancelled-scope regressions prove rejection without making a request |
| IPv6 filtering admitted special-purpose protocol, transition and documentation destinations | Conservatively exclude `2001::/23`, `2002::/16` and `3fff::/20` alongside the existing local/mapped/documentation restrictions. Boundary tests retain ordinary public IPv6. This is a provider-specific conservative policy, not a general-purpose IP registry implementation |
| Review capability flags were read once, leaving Play disabled after the audio service started | Poll current adapter availability alongside review state; preserve the loaded draft on check failure, disable unsafe controls, sanitize failures and recover on the next successful read. Availability checks do not rerun runtime verification or autoplay |
| Overlong ordinary tracks were labelled live-stream failures | Report duration-cap failures as `limitExceeded`, retaining live/unavailable precedence and every source entry |
| A real source-file size violation was treated as a whole-job quota failure, blocking review/exclusion of playable peers | Carry an in-process per-file classification without changing persisted error codes/schema. Fail only that track and discard its temporary work before continuing; global job/workspace/disk limits still stop work. A real supervisor-limit regression verifies peers reach review and the failed item can be explicitly excluded |
| APK inspection accepted required component names that were directories or empty files | Required manifest/DEX/engine/notices must be nonempty regular files; eight directory/empty replacements are rejected |
| Desktop verification accepted empty required AOT/components/notices or a nonexecutable Linux entrypoint with a matching inventory | Reject incomplete/unlaunchable packages even when a manifest consistently describes those bytes/modes |
| Installer verified a copied package but did not compare its identity with the requested input | Reverify and compare the complete snapshot before publishing its immutable directory; a different valid package introduced during copying leaves the old active package unchanged |
| Activation trusted the directory name independently of the manifest's content ID | Candidate and current directory IDs must match their verified manifests; a valid package under another ID cannot activate |

The IPv6 policy was checked against the [IANA special-purpose registry](https://www.iana.org/assignments/iana-ipv6-special-registry/),
including the newer documentation allocation. Globally reachable protocol-service
exceptions inside the conservatively blocked ranges are deliberately unavailable
to these fixed HTTPS providers.

## Code structure and documentation decisions

Token/revision checks, separate original/human metadata, frozen verified exports,
no-clobber destination journals and private workspace cleanup serve distinct
integrity boundaries and remain in place. Native process/image/codec work stays
off the UI thread. No broad architectural rewrite or dependency upgrade is
needed to correct the reproduced failures.

The Stage 0 feasibility harness, optional cloud experiments and fictional Stage 2
journey are intentional separate entry points, not the real processing path.
Removing them would discard contract tests/evidence; they do not become required
app infrastructure. Historical migrations/results remain historical. Platform
adapters stay disabled without their own execution evidence.

Corrected stale Android release-signing guidance, the architecture's packaging/
export claims, the project's skill schema pointer and capacity wording. The
current retention implementation uses **48 hours from draft creation**, with
active work/editor/export protection; edits/resume do not reset it. Guides now
state this boundary and explain creating a new draft after expiry. They do not
promise an automatic transfer of old human edits into that new job.

The native integration helper now uses `--no-pub`: dependency resolution belongs
to the explicit pinned setup step, not an incidental integration test. Handoffs
include this review alongside their original package provenance and limits.

## Verification and limits

Every defect above has a regression that failed against the prior behavior.
Commands, actual suite results and final publication evidence are recorded in
`PROJECT_STATUS.md` and the associated pull request. Real-codec tests use the
pinned standalone runtime and fictional generated audio; provider fixtures and
injected destinations are identified rather than counted as live/manual proof.
The Linux native checks use disposable displays, SQLite/keyring sessions and
a private PulseAudio null sink. Development prerequisites are extracted official
packages under `/tmp`; no global packages, ordinary keyring/audio server or
sibling project are modified.

The codebase is **not a completed cross-platform product**: Windows media and
independent Android/iPhone acquisition, codecs, playback, tagging and native
document delivery remain unavailable/unverified. Actual owner journeys,
manual native panels/physical players, clean devices, cross-version data/key
acceptance, physical accessibility/battery and public licensing/signing gates
remain open. Offline fixtures and green CI cannot close them. Fresh live source/
Groq/public-artwork calls remain separate explicit opt-ins; historical evidence
does not establish current upstream availability. See [Stage 9](STAGE9_GUIDE.md).
