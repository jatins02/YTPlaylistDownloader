# Stage 9 release and handoff

Stage 9 is **in progress**, not accepted as a completed product release.
The user/setup guide, compatibility process and offline handoff assembler are
implemented. No public binaries, store submission, paid infrastructure or new
shared keys are published. The both-phone requirement remains unchanged.

## Delivered scope and evidence

| Platform/source | Actual verified scope | Release boundary |
| --- | --- | --- |
| Linux x64 | Source acquisition, full MP3/snippet preparation, configured AI naming, conservative public front artwork/APIC, durable review, private verified MP3/ZIP and automated destination transfer; complete evaluation package with standalone runtime | Manual native panel/listening, physical-player, clean-device compatibility, cross-version user data/key and distribution acceptance pending |
| Windows x64 | Foundation behavior, native plugins/restart, release build/scan and portable foundation ZIP in CI | Media/playback/tag/export disabled; clean install/update and manual QA pending |
| Android arm64 | Debug foundation APK build, signature verification and compressed-asset scan in CI | No physical media/document API execution, release signing/update or independent workflow proof |
| iPhone | Required scope recorded | No Mac/Xcode/iPhone build, signing/install or independent workflow evidence |
| Public/accessibly unlisted YouTube and YouTube Music playlists | URL validation and bounded Linux source engine; historical opt-in live sample | No promise for every changing source; login/private/age-restricted/endless mixes excluded; source access/rights remain the user's responsibility |

Current Linux capacity is ten unique tracks up to ten minutes each, subject to
the byte/storage limits in the [user guide](USER_GUIDE.md). The larger initial
product target and phone capacity have not been demonstrated.

[Stage 8 results](STAGE8_RESULTS.json) record the actual package build revision
`aab83fa7028e57a4cf059b2bd0a3a53a45a51b43`, archive checksums, installed
startup/inventory, real-runtime export regressions and equal-schema switching.
That local build revision is retained locally; its changes were published via
PR #5 and merged as `68f0518bb409044a07df840a9bcb29aef1f73036`.
The existing artifacts were **not** rebuilt from that merge or Stage 9 source.
[Main Stage 8 CI](https://github.com/jatins02/YTPlaylistDownloader/actions/runs/39061257524)
passed Linux, Windows, Python contracts and Android APK checks. It did not retain
binary artifacts or execute phone media. Historical live AI/artwork checks are
described in Stage 4; no new live calls are implied by this handoff.

The Stage 9 assembler snapshots a trusted unpacked package, verifies all bytes
and modes against its manifest, checks current pins/clean build provenance,
scans package/guidance for private files and literal keys, and writes a
no-clobber handoff ZIP. It includes the complete package archive, original build
identity, [user guide](USER_GUIDE.md), [maintenance instructions](MAINTENANCE.md),
Stage 8 install/rollback instructions and component-notice limitations. The
outer checksum printed by the command must travel through a trusted channel.
Its manifest explicitly leaves public release unapproved and physical
acceptance unassessed. A generated report is not an acceptance certificate.

## Outstanding acceptance record

All rows below are **pending**. Automation/mock success, desktop tests, APK
compilation, screenshots or an iOS build cannot change these rows by inference.

| Gate | Required execution/evidence |
| --- | --- |
| Clean Linux install and full journey | Exact archive hash, machine/OS/audio/keyring/filesystem versions; user-owned key; permitted playlist; actual review/edit and native MP3/ZIP panel; confirm saved-copy message and full playback/tags/embedded covers in a physical player |
| Cross-version update/recovery | Two real app versions and supported equal-schema route; retained drafts/settings/human edits/key access; interrupted install leaves old version active; rollback/restart and external copies survive |
| Manual accessibility/performance | Keyboard/screen reader, touch/rotation where applicable, audibility/one-player behavior, controlled frame/memory/battery observations and suspension/cleanup on each actual target |
| Windows media and delivery | Native source/codec/playback/tag and destination API execution plus clean install/update/full journey; foundation CI cannot enable these adapters |
| Independent Android | On-device source/codecs, own-key vault, review/audio/tags, document save/cancel/denial/restart/cleanup, retained copies; same-identity signed update and complete owner journey without laptop |
| Independent iPhone | Actual iOS build/install/signing route within zero budget, native media and document/share/vault/background execution, full owner journey and update/recovery without laptop |
| Public redistribution | Owner's application license decision; all bundled licenses/notices/corresponding source and build recipes, including FFmpeg GPL/static components; trusted distribution/signing route and retained artifacts |
| Final owner acceptance | Owner completes the intended workflow on **every released platform**, all applicable evidence above linked; Android alone cannot close the both-phone requirement |

For each execution record: date, tester, platform/device/OS, app version,
package/source IDs and archive SHA-256; permitted test scenario; exact observed
outcome; sanitized evidence location; pass/fail/pending and reason. Record
individual tests (key quota, uncertain metadata, missing artwork, cancellation,
denial, disk full, restart, update, cleanup), not a blanket “works” assertion.
Never include keys, raw databases/provider payloads, private paths or source
media. Update this table and `PROJECT_STATUS.md` only with actual results.

No local USB/Android SDK/JDK/ADB or Mac/iPhone is available in this execution
environment. Manual gestures/listening and missing platform implementations
cannot be substituted with generated evidence. Until the gates close, deliver
the evaluation and source with these limits, not a completed public release.
