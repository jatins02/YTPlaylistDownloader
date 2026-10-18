# Compatibility and release maintenance

Maintain only claims supported by actual builds and execution evidence. The
[Stage 9 checklist](STAGE9_GUIDE.md) separates automated evaluation from physical
acceptance. No automatic runtime/network updater, store submission, shared API
key, hosted backend or paid service is part of this handoff.

## Reproduce and investigate

1. Record the failing package's `package.json`: package ID, original source
   revision, dirty flag, target/scope, schema, build OS/libc and pins. Preserve
   the original artifact and trusted checksum. Do not equate a packaging-script
   revision with the revision that built the executable.
2. Reproduce offline with fictional metadata and synthetic, distinguishable
   audio. Capture the failure category and operation boundary. Never collect
   user vaults, dotenv, raw response bodies, signed URLs, media or private
   destination paths in public reports. Keep accepted peers and human edits in
   the regression case. Live requests remain an explicit, separately recorded
   opt-in using a permitted source and the user's own secure key.
3. Identify whether the failure is source access/extractor drift, codec/runtime,
   provider quota/model/schema, conservative artwork matching, OS plugin,
   destination API or resource limits. Do not relax HTTPS/redirect checks,
   token fencing, file caps, checksum/readback or visible failure handling to
   make an upstream error disappear.

## Change exact pins deliberately

`toolchain.json`, `apps/native/pubspec.lock`, `requirements-stage0.lock` and
`requirements-native-runtime.lock` are the authoritative version inputs.
Bootstrap the exact Flutter commit with `scripts/bootstrap_flutter.py`. Review
dependency changes and upstream release/license notes; record the actual
compiler/OS/architecture and runtime output. Never use an unpinned `latest`,
ship a development venv or inherit the sibling project's environment.

For a source-engine update, test URL reconstruction, playlist occurrence/unique
limits, inaccessible entries, deadlines, cancellation and restart without
refetching an already captured playlist. For AI/model changes, test exact stable
ID sets, malformed/partial responses, quotas and cooldowns, uncertainty/version
markers, human revision precedence and source-title fallback. For artwork,
exercise public DNS/redirect restrictions, provider pacing/cache expiry,
byte/pixel/decode limits, ambiguity and embedded cover readback. A successful
network response alone proves none of these contracts.

Run the affected behavior tests and actual native integration tests. The normal
CI codec is a recorded compatibility runtime; it does not substitute for exact
production runtime tests. Commands and setup are in the Stage 3–8 guides:

```bash
python -m unittest discover -s tests -v
cd apps/native
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze --no-pub
flutter test --no-pub
cd ../..
python scripts/test_linux_native.py
```

For media/review/export changes also run the actual pinned-runtime Stage 3, 4,
5 and 6 Linux integration routes, not only repository mocks. See their guides
for `STAGE3_TEST_RUNTIME` and isolated test keyring setup. Never mark Windows or
phone adapters available based on Linux results. Any schema change needs real
migration/restart tests and a backup/restore design before a new release route;
the current installer rejects binary switching across unequal declared schemas.

## Prepare an evaluation handoff

Build from a clean committed checkout using Stage 8's complete bundle/runtime
instructions. Verify tool versions and licenses, scan the actual release assets,
verify the packaged inventory and exercise the installed release. Test retained
equal-schema switching, interrupted installation and corrupt-package rejection.
Cross-version drafts/settings/key persistence still requires two actual app
versions and the same OS application identity; same-version switching is not
that evidence. Keep old versions and external saved copies untouched.

`scripts/build_handoff.py` takes a trusted, already unpacked package, snapshots
and reverifies it, then produces one no-clobber ZIP with the package, guides,
original build provenance, inventory/checksums and explicit evaluation limits.
It rejects dirty-source packages and pins that differ from the handoff checkout.
It does not execute the app or certify device acceptance/licensing. Obtain and
check the original archive checksum before unpacking with a safe utility; never
run an untrusted archive's embedded package manager to establish trust.

```bash
python scripts/build_handoff.py --package /absolute/trusted-unpacked/ytpd \
  --output dist/stage9/ytpd-evaluation-handoff.zip
```

Keep the printed outer ZIP SHA-256 with the handoff in a trusted delivery
channel. Inside are `handoff.json`, `SHA256SUMS`, the desktop archive and guides.
The report's `build_revision` identifies the executable's original build;
guides describe current limits. Checksums are integrity checks, not signatures.
Do not commit binaries, source downloads, keys or personal acceptance data.

## Release and recovery

Before public distribution, resolve the application license and every bundled
component's notices/corresponding-source/build obligations, then choose a
zero-budget installation/signing route for each released platform. Keep signing
keys outside source and release bundles. Retain the same app ID/signing identity
for updates. Confirm install/update/rollback on a clean device, user-owned vault
key access, saved draft/edit persistence, permission denial/cancel/restart,
full-length physical-player tags/embedded covers, and user-copy-safe cleanup.
Record versions, artifact hashes and sanitized observations in the checklist.

Publish source changes, run all CI jobs, inspect failures, fix and rerun until
the exact published commit is green. CI source publication and private handoff
assembly do not authorize a public binary release. An Android-only result does
not satisfy independent Android **and** iPhone operation. Keep outstanding gates
in `PROJECT_STATUS.md`; never convert `pending` to `passed` without execution.
