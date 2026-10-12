# YTPlaylistDownloader

A successor to DOT.: playlist downloads, AI song naming, automatic covers, snippets and editable review, then full tagged MP3/ZIP save to your device.

**Current state:** Stage 0 CLI implemented; local core tests and three real playlist runs passed. The native application is not implemented. Independent Android/iPhone execution remains unproven.

## Confirmed direction

Zero budget, independent Android and iPhone use, laptop support, device-only saves, and professional lavenderblush UI. No Mac/iPhone is currently available for testing. Native UI/platform adapters are proposed; the former hosted-web plan is superseded. Do not silently replace the phone requirement with a laptop companion.

## Start here

- [Stage 0 setup and commands](docs/STAGE0_GUIDE.md)
- [Current results and missing gates](docs/PROJECT_STATUS.md)
- [Implementation plan](IMPLEMENTATION_PLAN.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Product specification](docs/PRODUCT_SPEC.md)
- [Design system](docs/DESIGN_SYSTEM.md)
- [Verification strategy](docs/TEST_STRATEGY.md)
- [Zero-budget platform decision](docs/decisions/0001-stage0-feasibility.md)

`.env` was created with an empty `GROQ_API_KEY` and `GROQ_MODEL=openai/gpt-oss-120b`. Paste your own Groq key there; never commit it or share it in chat. The CLI loads only this project's .env. Future native users supply their own key through secure device settings; developer keys do not ship in binaries.

```bash
python -m stage0 preflight
python -m unittest discover -s tests -v
python -m stage0 synthetic --runs 3
```

Install the pinned requirements and FFmpeg/ffprobe/Deno first as described in the guide. Real AI naming awaits a configured key; online artwork and actual mobile export tests remain open. The optional S3 adapter/container is a future experiment, not required native infrastructure.

Coding agents start with [AGENTS.md](AGENTS.md); agent.md is a compatibility pointer. Task-specific skills live under .agents/skills/. The sibling DOT. stays reference-only; its environment, credentials and music are not imported.
