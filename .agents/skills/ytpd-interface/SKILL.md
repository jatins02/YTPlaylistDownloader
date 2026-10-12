---
name: ytpd-interface
description: Build or review YTPlaylistDownloader responsive lavenderblush native review screens, single-snippet playback, editable drafts and device file-save interactions.
---

# Native review and save UX

Read docs/DESIGN_SYSTEM.md and docs/PRODUCT_SPEC.md. Native independent-device operation is the current direction; do not introduce a mandatory hosted backend, cloud Library destination or laptop companion. Framework choice remains provisional until platform media proof.

Use import → progress → review → save, restrained lavenderblush/white/near-black styling, visible failures/counts and touch-accessible controls. Keep stable IDs for play/edit actions. One actual bounded snippet plays after a gesture; switching stops the old one. Preserve version details and expose original titles/uncertain art.

Editing has explicit Save/Cancel, filename preview and visible pending/error states. Retain text after failures. Final Save waits for pending edits and selected-ready tracks. Frozen exports cannot change underneath a device save.

Use native document/save/share APIs. Permission denial or picker cancellation preserves recovery; show successful destination transfer only when the platform reports it. Files export does not promise insertion into every native Music library.

Test narrow/landscape/tablet/laptop layouts, long Unicode names, missing art, large text, keyboard/focus, screen readers and actual contrast/targets. Adapt the design tokens to native widgets rather than requiring CSS. Respect lifecycle/suspension and reduced motion. Actual Android/iPhone export tests are required; unavailable devices are recorded as outstanding, never inferred from desktop automation. Browser/PWA caching guidance applies only if a separate optional web frontend is later requested.
