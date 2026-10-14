# YTPlaylistDownloader

A successor to DOT.: playlist downloads, AI song naming, automatic covers, snippets and editable review, then full tagged MP3/ZIP save to your device.

**Current state:** Linux Stage 3 now processes real playlists into private full MP3s and verified snippets, with ordered/duplicate handling, pause/resume, failures/retries, storage limits and cleanup. Configure the local runtime, save a playlist draft, then **Open playlist → Process playlist**. The fictional Stage 2 demo remains separate. AI naming/covers, interactive playback/editing and final device export are later stages. Android, Windows and iOS media verification remain open.

## Confirmed direction

Zero budget, independent Android and iPhone use, laptop support, device-only saves, and professional lavenderblush UI. No Mac/iPhone is currently available for testing. Flutter is selected for the foundation; media adapters remain provisional; the former hosted-web plan is superseded. Do not silently replace the phone requirement with a laptop companion.

## Start here

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

Install the pinned requirements and FFmpeg/ffprobe/Deno first as described in the guide. Real AI naming awaits a configured key; online artwork and actual mobile export tests remain open. The optional S3 adapter/container is a future experiment, not required native infrastructure.

Coding agents start with [AGENTS.md](AGENTS.md); agent.md is a compatibility pointer. Task-specific skills live under .agents/skills/. The sibling DOT. stays reference-only; its environment, credentials and music are not imported.
