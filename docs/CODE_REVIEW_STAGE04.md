# Review after Stage 4 — 2026-10-15

Reviewed the implemented CLI and native paths for identity/token/revision
publication, private files, restart/cancellation/retention, source/codec bounds,
provider requests, artwork/cache evidence, frozen tagging, settings/error UX,
setup helpers, fixtures and CI contracts. This builds on the recorded Stage 0–3
review; the Stage 2 fixture journey remains isolated. No dependency pins, source
capacities or platform execution gates were relaxed.

Fixed findings:

- The native artwork transaction accepted conflicting success/failure inputs
  or an absent outcome. It now rejects those writes before retiring an existing
  verified cover. The regression checks that its active asset and pointer survive.
- Unexpected naming-settings read failures escaped the widget callback. They
  now show a safe retry message without exposing raw native diagnostics.
- The tag worker verified JPEG structure without fully decoding cover pixels,
  and checked total pixels instead of each normalized axis. It now rejects a
  truncated or overwide cover before creating a tagged derivative.
- The legacy CLI artwork adapter did not revalidate recording details, could
  accept a truncated search/release list, chose the first approved front and
  rejected the archive's legacy HTTP image links. It now validates stable MBIDs,
  exact recording identity/credits, complete bounded evidence and a unique
  approved front for the matched release. Trusted legacy image URLs reconstruct
  to HTTPS before fetching. Redundant loops over already-unique matches were
  removed. Existing tests now use representative provider identity/count fields.
- The CLI naming prompt could include URL/key-shaped text inside allowed source
  fields, and could accept parseable JSON from a refused/truncated completion.
  Prompts now redact those values, while original-title fallback remains intact;
  only one unrefused `stop` completion is accepted. Prompt version is `stage0-v3`.

The live Stage 4 checks also found and fixed the custom HTTPS factory's missing
TLS handshake and the archive's advertised HTTP image URLs, with real local TLS
and actual live artwork/embedded-cover evidence. See [live results](STAGE4_LIVE_RESULTS.json).

Actual local verification after review:

| Check | Result |
| --- | --- |
| Pinned-runtime `flutter test --no-pub` with `STAGE3_TEST_RUNTIME` | 172 pass, zero skipped: 155 ordinary + 17 actual-codec cases |
| Default `flutter test --no-pub`, runtime opt-in unset | 155 pass, zero skipped |
| `.venv-stage0/bin/python -m unittest discover -s tests -v` | 58 pass, zero skipped with project FFmpeg 8; separately 58 pass, zero skipped with CI FFmpeg 6.1.1-3ubuntu5 |
| Dart formatting / Flutter analysis | 67 files, zero formatting changes; no analysis issues |
| Linux foundation native integration | 1 pass; actual keyring/SQLite/restart |
| Linux pipeline native integration | 1 pass; actual source boundary/codecs/UI/restart with synthetic input |
| Linux enrichment native integration | 1 pass; actual keyring/images/ID3/codecs/UI/restart with fictional HTTP replies |
| Python compilation / `git diff --check` | Pass |

Linux release/asset scanning and publication/CI results are recorded in
[PROJECT_STATUS.md](PROJECT_STATUS.md). Credentials remain outside source,
prompts, logs, reports and release assets. Real Windows/Android/iOS media/tag
execution is still unavailable here; these tests do not close those gates.
Playback/editing and final device export remain Stages 5–6.
