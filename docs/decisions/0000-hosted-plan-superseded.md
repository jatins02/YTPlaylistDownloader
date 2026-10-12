# Previous hosted architecture: superseded baseline

The first planning package assumed a Vercel frontend, container API/worker, Postgres, Redis-compatible broker and temporary object storage. On 2026-10-12 the owner specified zero budget, standalone Android and iPhone operation, and no access to a Mac or iPhone.

That hosted topology is no longer the default implementation path. It would require online backend availability and a workable operating budget; a desktop companion also fails the independent-phone requirement. Do not provision paid services or treat the previous server-specific stage gates as the current native-app plan.

The useful design invariants remain: immutable identities, per-job isolation, structured AI output, review-before-save, human-edit precedence, partial failures, collision-safe names, full MP3 tags and covers, bounded resources, resumable state and meaningful tests.

The optional storage adapter and Docker recipe in the Stage 0 harness preserve a future hosted experiment. They are not required by the zero-budget native baseline. See IMPLEMENTATION_PLAN.md, ARCHITECTURE.md and PROJECT_STATUS.md for current decisions and open platform feasibility.
