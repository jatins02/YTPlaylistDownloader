# Stage 2: responsive fixture journey

Implemented and verified on 2026-10-13 with the pinned Flutter 3.47.5 / Dart 3.13.4 toolchain. Stage 2 is complete for the fixture interface. It does not complete the open Stage 0 provider/device gates or implement real native media/export.

## Try it

Follow [native setup](STAGE1_GUIDE.md), run `flutter run -d linux` (or Windows once its toolchain is available), then choose **Explore the fictional demo** from Playlist drafts. No key, account or internet is needed for the demo.

1. Keep the sample link or enter a supported playlist link. Choose Partial success, All tracks ready, Empty playlist, Expired draft or Connection lost. Every scenario uses fictional fixtures; the link is validated but never fetched.
2. Start fictional import. Advance with **Next demo step**: discovery, then one unique track per step. Counts describe the simulation. Cancel and retry states have explicit recovery actions.
3. Review five unique recordings from six occurrences. Two recordings have identical names but distinct IDs; a repeated source appears twice and exports once. Inspect Unicode/long titles, a preserved Live version, an unknown artist, missing art and an unavailable item. Exclude or retry the failed item before continuing.
4. Use **Preview demo** for a silent, single-track control simulation. Its slider is bounded to 30 seconds; switching, editing, saving and app suspension stop the previous preview. Actual audio is Stage 5 work.
5. Edit song, artists, features, version and album. Artist lists use one name per line. Save explicitly or cancel/Escape to discard. Original titles stay intact. Filename previews omit an empty feature separator and preserve versions. Confirming an artist clears uncertainty; editing a failed source does not hide its failure.
6. Choose ZIP or individual MP3s and **Save … to device · demo**. The screen freezes the selected names and demonstrates numbered collision handling. Simulate a destination save or return to review. Completion explicitly states that no files were written.

Demo settings can fail edit saves or deny destination saves. Typed edits remain available after a failure; turn the relevant switch off and retry. Cancellation retains selection and committed demo edits. Real AI-key settings remain on the drafts screen and use the existing OS vault.

## Boundaries and implementation

`FixtureJourney` is an independent in-memory state machine. Immutable fixture tracks and save previews use stable identities. It has no repository, filesystem, provider, credential or media adapter dependency. Leaving the demo discards its edits; durable playlist drafts are unchanged. Production editing/recovery belongs to Stage 5. UI-only filename previews are not Stage 6's portable, byte-bounded export algorithm or verified artifacts.

Screens, reusable components and the editor/settings dialog live in separate UI files. Shared theme tokens cover lavenderblush surfaces, white cards/dialogs, near-black primary controls, contrast-safe text/boundaries and visible keyboard focus. Controls have at least 48 px targets. Responsive wrapping, scrolling, safe areas and scrollable dialogs accommodate large text and software-keyboard insets. Player controls stay immediately below the active track, without overlays covering rows. Each journey transition starts at the top; live status/header semantics describe major changes. The app follows Flutter/OS reduced-motion settings; advancing fixtures requires no animation or timer.

## Executed acceptance checks

| Check | Actual result |
| --- | --- |
| `dart format --output=none --set-exit-if-changed lib test integration_test` | Pass |
| `flutter analyze --no-pub` | No issues |
| `flutter test --no-pub` | 80 pass, zero skipped; 32 added behavior/layout/accessibility regressions |
| `python3 scripts/test_linux_native.py` | 1 actual native plugin/restart test passes, including demo-route isolation |
| `flutter build linux --release` | Pass with official isolated Linux prerequisites |
| Release bundle check | No bundled dotenv or literal Groq key |
| Existing Python/FFmpeg suite | 30 pass, zero skipped |
| Opt-in screen rendering | Reviewed screenshots in [stage2/screens](stage2/screens) |

Layout tests traverse import, discovery, preparation, partial review, editor, save, completion, empty, expiry and connection states at **320×720, 390×844, 768×1024, 1024×768, 1440×900 and 844×390**, each with **100% and 200% text**. Additional landscape editing/settings checks include a 160 px keyboard inset. Keyboard traversal opens the editor with Enter; Escape discards edits and restores the initiating button's focus. Semantics checks cover track-specific actions, inclusion and live selection counts. Flutter's Android/iOS target-size, labeled-target and text-contrast guidelines pass on rendered review controls; palette tests verify 4.5:1 text and 3:1 essential boundary/focus contrast.

These are Flutter layout/semantics tests on Linux, not actual Android/iPhone runs or human TalkBack/VoiceOver certification. Hardware, OS keyboards, screen readers, lifecycle and real device saving remain Stage 7 and earlier platform gates. Windows execution remains pending. Existing CI automatically includes the new behavior tests; no GitHub workflow run is claimed.

## Regenerate visual evidence

From `apps/native` with the pinned SDK on PATH:

```bash
flutter test --no-pub test/fixture_widget_test.dart \
  --dart-define=STAGE2_PREVIEWS=true --plain-name 'rendered evidence'
```

PNG output goes to ignored `build/stage2-previews`. The helper loads SDK-bundled Roboto and MaterialIcons only during this opt-in check. On Linux, set `STAGE2_CJK_FONT=/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc` if installed to render Japanese in widget-test evidence; the recorded images used this font. No font download or runtime dependency was added. Native apps use OS font fallback. Copy reviewed screenshots to `docs/stage2/screens` when intentionally refreshing documentation; these images are fictional and contain no credentials or downloaded music.

Next: Stage 3 native acquisition/conversion/recovery, only on platforms whose media spike is proven. Preserve the fixture route while wiring production UI through real durable controllers and adapters; do not mistake demo completion for saved device files.
