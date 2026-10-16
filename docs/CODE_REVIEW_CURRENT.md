# Review of the current implemented codebase

Date: 2026-10-17. Baseline: `245090b` (implemented Stages 0–6).

## Scope

Reviewed the implementation plan and product/architecture contracts against the
CLI, native domain/controllers, transactional repositories and migrations,
source/codec/process supervision, metadata/artwork/tag workers, review and
export lifecycle, UI/fixture boundary, setup helpers and CI. Existing tests and
the previous review records informed the checks. Future Stages 7–9 and unproven
platform adapters were not implemented or represented as supported.

## Findings and corrections

- **Embedded titles could lose versions.** The native domain displayed
  `Olive (Live)` correctly, but the Python tag worker independently recomputed
  `Olive`. The native adapter now sends the frozen semantic title and requires
  that exact title in the worker's ID3 readback. The duplicate formatting rule
  was removed. The opt-in live acceptance caller uses the same request contract.
  A real full-MP3/ZIP regression compares filenames and actual TIT2 values with
  the reviewed metadata for Olive and Delivery.
- **The CLI still used substring version matching.** Complete literal Unicode
  labels now preserve Live inside unrelated words, handle combining marks and
  avoid duplicating already present labels or punctuation-bearing versions.
- **CLI filenames could collide under compatibility normalization.** Filename
  allocation and archive validation now use NFKC/casefold collision keys while
  retaining NFC display text. Distinct fullwidth/ASCII names receive distinct
  filenames; a manually colliding archive is rejected before publication.
- **Zero process exit could override codec errors.** Native probe, full decode,
  conversion, snippet preparation and playback now require clean stderr at
  error log level. Raw diagnostics remain bounded and private. Other supervised
  tools retain their existing diagnostic behavior. Two guarded-tool regressions
  prove that a zero-exit probe/decoder error cannot validate audio.
- **Malformed artist credits could be silently ignored.** Native recording
  matching now rejects an incomplete credit rather than matching the remaining
  known artist and assigning that recording's cover.
- **Private file checks only rejected symlinks.** One shared guard now also
  rejects directories, FIFOs and other non-regular entities before opening a
  lock, database sidecar, bundled tool or managed asset path. Tests exercise a
  directory, a real Linux FIFO and structured failure from an unsafe tool path.
  The sole-workspace ownership and immutable path contracts remain in force.
- **A completed draft save could erase newer input.** The draft screen clears
  only the submitted text; a link typed while storage was pending is retained.
  Its controlled asynchronous widget regression verifies both the saved first
  playlist and the unsaved second link. Stale copy claiming review/save were
  future work was replaced with wording tied to available device actions.
- **CLI artwork DNS validation did not bind the connection.** The CLI now uses
  the already pinned urllib3/certifi packages to connect to a validated public
  IP, retaining the original TLS/SNI/certificate hostname and HTTP Host header.
  Each redirect is revalidated, ambient proxies are not consulted, retries are
  disabled, and pools/responses close explicitly. DNS has a bounded wait; late
  resolver results cannot open sockets. Streaming reads use the remaining
  response deadline and retain decoded-byte caps. Preflight reports the actual
  existing pinned transport dependencies. Local TLS tests prove successful
  encrypted fetches and rejection of a certificate for the wrong hostname;
  additional tests cover slow DNS and redirect rejection before another socket.
  The implementation follows the [urllib3 custom-SNI contract](https://urllib3.readthedocs.io/en/stable/advanced-usage.html#custom-sni-hostname).

The original version/tag, codec, artist-credit, private-path and CLI collision
defects have failing-before/fixed-after regression evidence. The draft regression
uses an explicit storage gate rather than assuming disk latency. Transport
acceptance uses a synthetic trusted test certificate and private loopback server;
production retains the pinned CA bundle and required certificate verification.

## Validation

All media and provider identities in the tests are fictional. No live source,
Groq or artwork request, owner `.env`, sibling DOT. data or normal desktop audio
service is used. Dependencies, SDK/runtime pins, migrations and platform
availability are unchanged.

| Command/check | Result |
| --- | --- |
| `dart format --output=none --set-exit-if-changed lib test integration_test tool` | 93 files unchanged |
| `flutter analyze --no-pub` | No issues |
| `STAGE3_TEST_RUNTIME=<pinned manifest> flutter test --no-pub` | 240 passed, zero skipped |
| Ordinary `flutter test --no-pub` without runtime opt-in | 214 passed, zero skipped |
| Project Python with project FFmpeg: `-m unittest discover -s tests -v` | 84 passed, zero skipped |
| Actual native foundation/pipeline/enrichment/export and isolated private-audio review | Five native cases passed |
| `flutter build linux --release --no-pub` and release bundle scan | Pass; 19 files, no dotenv asset or literal Groq key |

The native checks use the same isolated official Linux prerequisites and pinned
runtime recorded in the stage guides. Test sockets, SQLite, keyring and audio
state are disposable and separate from normal user state. Development live
checks remain opt-in; changing their tag request does not claim a new live pass.

## CI and remaining limits

The unchanged Foundation workflow runs ordinary Flutter tests, native foundation
restart/plugin checks, release builds/scans on Linux and Windows, and Python
media contracts on Linux. The opt-in real-media and remaining native acceptance
above are separate local Linux checks. Publication checks can be inspected in
[GitHub Actions](https://github.com/jatins02/YTPlaylistDownloader/actions).

Manual Linux save-panel/physical-player/accessibility acceptance and
Windows/Android/iPhone media/tag/playback/export execution remain unverified.
No desktop or injected-chooser result closes a phone or manual gate. Existing
completed exports remain immutable; corrected names apply to a newly reviewed
and prepared revision. Independent phones, zero budget and device-only saves
remain requirements.
