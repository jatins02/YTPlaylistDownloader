> Historical hosted alternative: this document describes the earlier web deployment proposal. The owner subsequently confirmed zero budget and independent Android/iPhone operation. It is not the current implementation baseline; no paid infrastructure is to be provisioned. Read ARCHITECTURE.md and IMPLEMENTATION_PLAN.md for the native direction and unresolved iOS gates.

# Hosting, reliability, and operations

Research checked 2026-10-12. Architecture recommendations below are engineering judgments; provider facts are linked. Recheck plans, limits, regions, pricing and terms before purchasing or deploying.

## Website or native app?

Start with a **responsive website/PWA**: one codebase covers phones and laptops, users open a URL, and supported browsers can install it. Installation behavior varies by browser/platform; a usable normal website remains the fallback. [MDN installation guide](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Making_PWAs_installable)

A native app can later improve OS integration, background playback, and local file management, but would introduce separate platform work and still need a reliable backend if downloads/AI remain server-side. It would not solve upstream source failures or hosting downtime by itself. Build it later only if measured mobile limitations justify it.

The owner chose device downloads, not a cloud library. Use temporary processing storage and standard ZIP/MP3 downloads. Do not depend on `showSaveFilePicker`: it has limited browser availability. Direct insertion into a device's native music library is not a v1 promise. [MDN file-picker reference](https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker)

## Will Vercel do it?

**For the frontend and short API gateway, yes. For this design's complete media pipeline, use a separate worker.** Ordinary Vercel Functions have bounded execution duration and a 4.5 MB request/response payload limit. The current documented Fluid Compute limits include 300 seconds on Hobby and 800 seconds on Pro/Enterprise, with an extended 1800-second beta subject to conditions. This is a poor default for unpredictable playlist conversion jobs and large ZIP responses. Vercel also has longer-lived workflow offerings; this recommendation is about the simplest fit for Python/native media tools, not a claim that Vercel has no background-work products. [Vercel function limits](https://vercel.com/docs/functions/limitations)

Recommended initial production topology:

| Component | Proposed host | Reason |
| --- | --- | --- |
| Next.js UI and JSON gateway | Vercel, appropriate current plan | Web deployment/CDN; no media payload proxying |
| FastAPI service | Paid Render web service | Container runtime and stable control API |
| Celery worker | Render background worker | Native audio tools and long jobs outside HTTP requests |
| Postgres | Managed Render Postgres | Durable job, draft, outbox and export records |
| Broker | Compatible managed Redis/Render Key Value tier | Task dispatch; database reconciliation handles lost delivery |
| Temporary files | Private Cloudflare R2 bucket | Media delivery independent of app process disk |
| AI | Groq via adapter | Continuity with DOT., structured metadata responses |
| Artwork metadata | MusicBrainz and Cover Art Archive | Recording/release matching and known front covers |

Render's background workers run continuously and consume queued work, including media processing. Free web services can sleep after 15 minutes idle and lose local files on restart; they are suitable for experiments, not the intended always-available processing service. Avoid keeping files on disposable service filesystems regardless of tier. [Workers](https://render.com/docs/background-workers), [free-tier behavior](https://render.com/docs/free)

An alternative is one paid container host/VPS for frontend, API and workers plus managed storage/state. It reduces the number of vendors but increases operating responsibility and may create a single failure point. Stage 0 should select based on measured source access, cost, maintainability and region—not frontend convenience alone.

## The important feasibility risk

An online website can remain reachable while YouTube downloads fail. yt-dlp documents IP blocking/throttling and source-dependent requirements. Validate the actual worker hosting network, not only the developer's laptop. Include current runtime dependencies and a tested update path; the yt-dlp EJS documentation describes supported JavaScript runtimes such as Deno. [yt-dlp FAQ](https://github.com/yt-dlp/yt-dlp/wiki/FAQ), [runtime setup](https://github.com/yt-dlp/yt-dlp/wiki/EJS)

Do not turn failures into unlimited retries or promise access to every private/restricted video. If hosted access is unsuitable, document a user-controlled worker or a narrower supported-source deployment as an explicit alternative. Do not silently change the public product into a local-only tool.

## What “always online” can realistically mean

No architecture guarantees never being offline. Define separate indicators:

- **Site/control availability:** proposed target 99.9% monthly successful synthetic checks for page load and owned-job status, approximately 43 minutes of error budget in a 30-day month. This is a target, not a measured result or provider SLA.
- **Processing reliability:** successful eligible tracks divided by eligible attempted tracks; report all failures separately, including upstream failures, rather than hiding them in an availability number.
- **Recovery:** target stale-worker recovery within 5 minutes and no committed draft loss on an ordinary worker restart. Proposed database-disaster targets are RPO ≤1 hour and RTO ≤4 hours, conditional on purchased backup/PITR capabilities and tested restore procedures.
- **Media delivery:** probe object-store reachability, valid signed downloads, and export integrity independently.

Production controls: non-sleeping compute, process auto-restart, readiness/liveness separation, durable queues plus database reconciliation, bounded retries, admission control, worker heartbeats, scheduled cleanup, external health checks, alerts, database backups, and rollback-capable releases. Start with one worker if budget requires; do not call that highly available. Two API instances/workers and managed database failover can reduce single-instance risk later, but need capacity/cost evidence.

If AI or artwork lookup is unavailable, keep audio and show reviewable fallbacks. If the queue is delayed, show waiting status. If the source provider is unavailable, show the cause and retain an eligible retry path. Do not report “service online” as “all downloads guaranteed”.

## Temporary delivery and retention

Private R2 presigned URLs act as bearer tokens: anyone possessing one can use it until expiry. Issue short-lived URLs only after authorization and never log them. Store media privately and deliver directly to the browser. [R2 signed URL documentation](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)

Apply the 24-hour phase expiry/48-hour total ceiling from PRODUCT_SPEC.md and garbage collection rules in ARCHITECTURE.md. Display actual expiry times. A periodic cleanup worker and orphan sweep must be monitored. Do not rely solely on process exit or a user clicking Done to delete temporary media. Keep operational metadata redacted with finite retention; document backup retention separately.

## Cost model and capacity

Do not quote a fixed monthly price before choosing current plans and running Stage 0. Budget separately for frontend, API, workers, database, broker, storage, object requests, media transfer, AI requests/tokens, monitoring and backups.

At 320 kbps, a four-minute MP3 is approximately 9.6 MB before small metadata overhead. One hundred such tracks are about 960 MB; MP3 compression means a ZIP is roughly the same size. Source media, converted MP3s, tagged copies, previews and ZIPs can coexist, so peak temporary storage can be several times the final archive. Measure the actual peak and set worker scratch/object quotas accordingly.

Track per-job CPU minutes, bytes stored/downloaded, AI tokens, cache-hit rate, and export retention. Enforce per-session and IP/global admission limits; anonymous sessions are not a sufficient abuse or budget control alone. Start with limited audience access, provider spend caps where available, and alerts at 50/80/100% of the agreed budget. Never fake traffic to keep a free tier awake.

## Operating procedure

Before release: pin a tested yt-dlp/FFmpeg/runtime combination; run a small authorized source smoke test on the hosting network; verify all secret scopes; test migrations, rollback, queue recovery and cleanup; verify actual mobile downloads. Migrations should be backward-compatible with the previous release during rolling deployment.

During incidents: stop admitting new expensive jobs if storage or error thresholds are exceeded; retain status pages and safe retry instructions; record affected job IDs without private titles/URLs where unnecessary. Roll back a broken worker image or provider configuration and resume recoverable phases. Never delete active files merely to free disk without checking their references.

On dependency updates: reproduce with synthetic fixtures first, then a bounded live-source smoke test. Keep an image rollback path. Run a restore exercise periodically and after backup-policy changes. Review provider support, source access and costs regularly.

## Integration sources for implementers

- [Groq structured outputs](https://console.groq.com/docs/structured-outputs): select a supported model/schema mode; semantic and ID validation still belong to this app.
- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API): client identification and shared request-rate limit.
- [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API): release-linked artwork and front-cover selection.
- [Mutagen ID3 guide](https://mutagen.readthedocs.io/en/latest/user/id3.html): explicit tag-version and frame handling.
- [yt-dlp project](https://github.com/yt-dlp/yt-dlp): supported configuration and current dependency information.

Use authorized test material and confirm the intended public service fits source/hosting provider rules before launch. This plan does not make a legal determination or promise unrestricted source availability.
