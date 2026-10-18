# YTPlaylistDownloader

A successor to DOT.: playlist downloads, AI song naming, automatic covers, snippets and editable review, then full tagged MP3/ZIP save to your device.

**Current state:** Linux Stage 3 prepares real playlists into private full MP3s and snippets. Stage 4 now attempts revision-safe AI names and conservative front covers using your own securely stored key, with visible failures, retries and validated private MP3 tag adapters. Live Groq naming, public artwork and embedded-cover checks pass. Stage 5 adds real Linux snippet listening, persistent name/cover edits and include/exclude controls. Stage 6 adds verified full MP3/ZIP preparation and Linux destination saving, with cancellation/restart recovery and external-copy-safe cleanup. Stage 7 adds repeatable Linux lifecycle/accessibility QA and measured synthetic loads. Manual save-panel/player QA, physical accessibility/battery checks and other-platform device export remain unverified. Android, Windows and iOS media/tag execution gates remain open; the fictional Stage 2 demo stays separate.

## Confirmed direction

Stage 8/9 provide private evaluation packaging, integrity-checked handoffs and
setup/recovery/maintenance guides. The complete product is still pending actual
Windows/Android/iPhone media execution and the release acceptance gates listed
in [Stage 9](docs/STAGE9_GUIDE.md).

Zero budget, independent Android and iPhone use, laptop support, device-only saves, and professional lavenderblush UI. No Mac/iPhone is currently available for testing. Flutter is selected for the foundation; media adapters remain provisional; the former hosted-web plan is superseded. Do not silently replace the phone requirement with a laptop companion.

## Start here

- [Whole-project review, fixes and verification boundaries](docs/CODE_REVIEW_FINAL.md)
- [Evaluation setup, own-key settings and recovery](docs/USER_GUIDE.md)
- [Stage 9 handoff, supported scope and outstanding release acceptance](docs/STAGE9_GUIDE.md)
- [Compatibility updates and maintenance](docs/MAINTENANCE.md)
- [Stage 8 private evaluation packaging and distribution gates](docs/STAGE8_GUIDE.md)
- [Stage 7 lifecycle, accessibility, measured loads and device gates](docs/STAGE7_GUIDE.md)
- [Stage 6 full MP3/ZIP saving and acceptance limits](docs/STAGE6_GUIDE.md)
- [Stage 5 real snippet playback and persistent review](docs/STAGE5_GUIDE.md)
- [Stage 4 naming, artwork, tags and acceptance boundaries](docs/STAGE4_GUIDE.md)
- [Stage 3 setup, processing and platform evidence](docs/STAGE3_GUIDE.md)
- [Stage 2 demo, verification and screenshots](docs/STAGE2_GUIDE.md)
- [Native app setup and Stage 1 contracts](docs/STAGE1_GUIDE.md)
- [Stage 0 setup and commands](docs/STAGE0_GUIDE.md)
- [Stage 0/1 code review and fixes](docs/CODE_REVIEW_STAGE01.md)
- [Review of all implemented Stages 0–3](docs/CODE_REVIEW_STAGE03.md)
- [Current results and missing gates](docs/PROJECT_STATUS.md)
- [Implementation plan](IMPLEMENTATION_PLAN.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Product specification](docs/PRODUCT_SPEC.md)
- [Design system](docs/DESIGN_SYSTEM.md)
- [Verification strategy](docs/TEST_STRATEGY.md)
- [Zero-budget platform decision](docs/decisions/0001-stage0-feasibility.md)

`.env` was created with an empty `GROQ_API_KEY` and `GROQ_MODEL=openai/gpt-oss-120b`. Paste your own Groq key there; never commit it or share it in chat. The CLI loads only this project's .env. Native users supply their own key through secure device settings; developer keys do not ship in binaries.

```bash
python -m stage0 preflight
python -m unittest discover -s tests -v
python -m stage0 synthetic --runs 3
```

Install the pinned requirements and FFmpeg/ffprobe/Deno first as described in the guide. Linux live AI naming and known public artwork/embedded-cover acceptance are verified; each user still supplies their own key. Actual mobile media/tag/export tests remain open. The optional S3 adapter/container is a future experiment, not required native infrastructure.

Coding agents start with [AGENTS.md](AGENTS.md); agent.md is a compatibility pointer. Task-specific skills live under .agents/skills/. The sibling DOT. stays reference-only; its environment, credentials and music are not imported.
