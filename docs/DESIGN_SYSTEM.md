> Native adaptation: the current baseline is independent native Android/iPhone/laptop apps. Apply these palette, typography, layout and accessibility requirements to native tokens/widgets. CSS and PWA/service-worker notes below are optional browser guidance, not required native infrastructure.

# Visual and interaction specification

## Direction

Quiet, professional and mostly monochromatic. Lavenderblush is the main surface family, white separates work areas, and near-black gives hierarchy. Album covers supply most incidental color. Prefer strong typography, spacing and alignment over decorative gradients, glass panels or glowing accents.

This is a task-focused application: playlist input, progress, review, export. Do not start with an oversized marketing hero, dashboards with invented statistics, or unnecessary onboarding.

## Initial tokens

| Token | Value | Use |
| --- | --- | --- |
| `background` | `#FFF0F5` | Lavenderblush page background |
| `surface` | `#FFFFFF` | Cards, inputs, dialogs |
| `surface-muted` | `#FAE8F0` | Quiet sections and selected backgrounds |
| `surface-hover` | `#F2DAE6` | Hover/pressed surfaces |
| `border` | `#DEC7D2` | Decorative dividers only |
| `control-border` | `#8C6B7C` | Visible input/control boundaries |
| `text` | `#211A20` | Primary text |
| `text-secondary` | `#66505D` | Secondary labels and hints |
| `primary` | `#211A20` | Primary CTA with white text |
| `focus` | `#75425F` | Keyboard focus outline |
| `error` | `#9D2349` | Restrained error text/icon |

Validate actual combinations instead of assuming tokens pass. Project targets: at least 4.5:1 ordinary text, 3:1 large text and essential control/focus indicators. Pale decorative borders must not be the only affordance for an interactive control. Status always includes text/icon, never color alone.

Use a system sans stack initially; a self-hosted font is optional after performance testing. Body 16px, secondary 14px, section titles 20–24px, main title 28–36px. Do not reduce editable input text below 16px on mobile. Use a 4px spacing scale, 12px control/card radii, modest shadows only for overlays, and 120–180ms transitions with reduced-motion support.

## Layout

- Desktop: centered workspace, maximum approximately 1120px. Compact top bar with product name and new-import action; review list carries the main visual weight. Metadata editor can be a side panel.
- Tablet: fluid single workspace with a drawer editor; avoid fixed desktop table widths.
- Phone: one column with stacked track cards, 48px cover thumbnail, clear title/artist hierarchy, visible Play and Edit controls, and full-width primary CTA. Metadata editing opens a sheet/dialog that survives the software keyboard.
- Review rows show cover, full-name access, artist/features, duration, state and selection. Truncated display text must have a way to reveal/copy the complete name; never truncate stored metadata.
- Sticky player and finalization controls need reserved layout space, safe-area padding, and a tested keyboard layout. They must not cover the last track or each other.

Initial layout breakpoints: 640, 768 and 1024px; use intrinsic sizing, wrapping, and container needs rather than device names. Required test widths: 320, 390, 768, 1024 and 1440 CSS pixels; also test landscape and 200% text zoom. “Responsive to every device” means fluid layout and documented progressive enhancement, not a guarantee for every obsolete browser.

## Interaction requirements

- Targets at least 44×44 CSS pixels where practical; no hover-only or right-click-only controls.
- Visible keyboard focus; logical tab order; Escape closes/reverts; focus returns to the initiating control after dialogs.
- Track play buttons expose the song name and current action; progress has an accessible label. Announce major status changes politely, without reading every byte update.
- Edit fields: song name, artist(s), features, live filename preview. Explicit Save/Cancel. Keep user text during transient server errors.
- Save to Device shows selected count and is disabled with a visible reason while edits are pending or selected tracks are not ready.
- Processing uses real counts and named phases. For unknown totals use an indeterminate indicator plus the actual phase, not a fake percentage.
- Export-ready state exposes Return to review / Choose remaining songs before the ZIP/MP3 list. Downloaded songs show disabled selection/save actions from confirmed receipts. Disable a ZIP containing already saved songs and explain preparing the remaining selection.
- Offer Fill missing details when saving, enabled by default; explain source-title and `-` artist fallbacks without requiring per-song edits. Preserve optional missing fields and the original review warning.
- Loading, empty, partial success, AI unavailable, no cover, expired job, lost connection, and failed export each need a designed state and a useful next action.

## Mobile/PWA boundaries

Use standard browser audio triggered by a gesture. No autoplay on navigation, uncontrolled overlapping clips, or promise of uninterrupted background playback. Native file pickers/share sheets are enhancements, with a normal download link always available. Keep private media and signed URLs out of service-worker caches.

Test on actual iOS Safari and Android Chrome; browser emulation alone cannot prove file-saving, keyboard, install, or suspension behavior. Log exact devices/browser versions and observed limits in the acceptance evidence.
