import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/processing_controller.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import '../domain/review.dart';
import '../platform/cover_picker.dart';
import '../platform/snippet_port.dart';
import 'theme.dart';
import 'workspace_components.dart';

Future<void> openReviewEditor(
  BuildContext context,
  ProcessingController state,
  TrackRecord track,
) async {
  final session = await state.beginEdit(track);
  if (session == null) return;
  try {
    if (context.mounted) {
      await showWorkspaceDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ReviewEditor(controller: state, session: session),
      );
    }
  } finally {
    await state.endEdit(session);
  }
}

class ReviewEditor extends StatefulWidget {
  const ReviewEditor({
    super.key,
    required this.controller,
    required this.session,
    this.pickImage = pickCoverImage,
  });
  final ProcessingController controller;
  final ReviewSession session;
  final Future<Uint8List?> Function() pickImage;
  @override
  State<ReviewEditor> createState() => _ReviewEditorState();
}

class _ReviewEditorState extends State<ReviewEditor> {
  late ReviewSession session = widget.session;
  late final title = TextEditingController(
    text: session.initial.metadata.title,
  );
  late final artists = TextEditingController(
    text: session.initial.metadata.artists.join('\n'),
  );
  late final features = TextEditingController(
    text: session.initial.metadata.featuredArtists.join('\n'),
  );
  late final version = TextEditingController(
    text: session.initial.metadata.version,
  );
  late final album = TextEditingController(
    text: session.initial.metadata.album,
  );
  late bool reviewed = !session.initial.metadata.needsReview;
  CoverEdit cover = const CoverEdit.keep();
  Map<String, Uint8List> choices = {};
  AppFailure? failure;
  String? coverFailure;
  bool busy = false, loadingCovers = true;
  List<TextEditingController> get fields => [
    title,
    artists,
    features,
    version,
    album,
  ];

  @override
  void initState() {
    super.initState();
    for (final field in fields) {
      field.addListener(changed);
    }
    _loadCovers();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadCovers() async {
    try {
      final media = widget.controller.media;
      if (media is ReviewMediaPort) {
        final loaded = await (media as ReviewMediaPort).reviewCovers(
          session.initial.jobId,
          session.initial.id,
        );
        if (mounted) setState(() => choices = loaded);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => coverFailure = 'Existing covers could not be loaded. You can keep the current choice or retry this editor.',
        );
      }
    } finally {
      if (mounted) setState(() => loadingCovers = false);
    }
  }

  List<String> names(String text) =>
      text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  SongMetadata candidate() => SongMetadata(
    title: title.text,
    artists: names(artists.text),
    featuredArtists: names(features.text),
    album: album.text,
    version: version.text,
    needsReview: !reviewed || names(artists.text).isEmpty,
  );

  Future<void> save() async {
    if (busy) return;
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      final error = await widget.controller.saveEdit(
        session,
        candidate(),
        cover,
      );
      if (!mounted) return;
      if (error == null) {
        Navigator.pop(context);
      } else {
        setState(() => failure = error);
      }
    } on AppFailure catch (error) {
      if (mounted) setState(() => failure = error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> choose() async {
    setState(() {
      busy = true;
      coverFailure = null;
    });
    try {
      final image = await widget.pickImage();
      if (mounted && image != null) {
        if (image.isEmpty || image.length > 5 * 1024 * 1024) {
          throw const AppFailure(
            FailureCode.artworkInvalid,
            'Choose an image up to 5 MiB.',
          );
        }
        setState(() => cover = CoverEdit.import(image));
      }
    } on AppFailure catch (error) {
      if (mounted) setState(() => coverFailure = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => coverFailure =
              'The image chooser could not finish. Your edits are kept.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> rebase() async {
    setState(() => busy = true);
    try {
      final updated = await widget.controller.review.rebase(session);
      if (mounted) {
        setState(() {
          session = updated;
          failure = null;
        });
      }
    } on AppFailure catch (error) {
      if (mounted) setState(() => failure = error);
    } catch (_) {
      if (mounted) {
        setState(
          () => failure = const AppFailure(
            FailureCode.storageUnavailable,
            'The latest revision could not be loaded. Your text is kept.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    for (final field in fields) {
      field.removeListener(changed);
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String filename;
    try {
      filename = filenamePreview(candidate());
    } on AppFailure {
      filename = 'Enter valid metadata to preview the filename.';
    }
    return PopScope(
      canPop: !busy,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (!busy) Navigator.pop(context);
          },
        },
        child: AlertDialog(
          scrollable: true,
          title: const Text('Edit track'),
          content: SizedBox(
            width: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Save applies your changes on this device. Cancel keeps the previous version.',
                ),
                const SizedBox(height: 16),
                for (final field in [
                  (title, 'Song name', 'review-title', 500),
                  (artists, 'Artists (one per line)', 'review-artists', null),
                  (features, 'Features (optional)', 'review-features', null),
                  (version, 'Version (optional)', 'review-version', 200),
                  (album, 'Album (optional)', 'review-album', 500),
                ]) ...[
                  TextField(
                    key: Key(field.$3),
                    controller: field.$1,
                    enabled: !busy,
                    autofocus: field.$1 == title,
                    maxLength: field.$4,
                    minLines: 1,
                    maxLines: field.$4 == null ? 3 : 2,
                    decoration: InputDecoration(
                      labelText: field.$2,
                      helperText: field.$1 == features
                          ? 'One name per line.'
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const Text(
                  'Keep meaningful live, remix, slowed or clip details. An unknown artist remains marked for review.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('I have reviewed these details'),
                  value: reviewed,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => reviewed = value ?? false),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Filename preview',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SelectableText(filename, key: const Key('review-filename')),
                const Text(
                  'Final saving may add a suffix to preserve files with equal names.',
                  style: TextStyle(color: mutedInk),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Original source title',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SelectableText(session.initial.sourceTitle),
                const SizedBox(height: 16),
                const Text(
                  'Cover',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(switch (cover.action) {
                  CoverAction.keep => 'Keep the current cover choice. Automatic covers are rechecked after song or artist changes.',
                  CoverAction.remove => 'No cover will be embedded.',
                  CoverAction.select =>
                    'A previously verified image is selected.',
                  CoverAction.import => 'New image selected. It will be decoded and verified when you save.',
                }),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () =>
                                setState(() => cover = const CoverEdit.keep()),
                      child: const Text('Keep current'),
                    ),
                    OutlinedButton(
                      key: const Key('remove-review-cover'),
                      onPressed: busy
                          ? null
                          : () => setState(
                              () => cover = const CoverEdit.remove(),
                            ),
                      child: const Text('Remove cover'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('choose-review-cover'),
                      onPressed:
                          busy ||
                              widget.controller.capability?.canImportArtwork !=
                                  true
                          ? null
                          : choose,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Choose image'),
                    ),
                  ],
                ),
                if (loadingCovers)
                  const WorkspaceProgress(
                    linear: true,
                    label: 'Loading verified cover choices',
                  ),
                if (choices.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Previously verified images for this track'),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final entry in choices.entries)
                        OutlinedButton(
                          onPressed: busy
                              ? null
                              : () => setState(
                                  () => cover = CoverEdit.select(entry.key),
                                ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: cover.assetId == entry.key
                                  ? ink
                                  : controlBorder,
                              width: cover.assetId == entry.key ? 3 : 1,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Image.memory(
                              entry.value,
                              width: 64,
                              height: 64,
                              semanticLabel:
                                  'Choose verified cover ${choices.keys.toList().indexOf(entry.key) + 1}',
                              errorBuilder: (_, error, stack) =>
                                  const Icon(Icons.broken_image_outlined),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                if (coverFailure != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      coverFailure!,
                      style: const TextStyle(color: errorInk),
                    ),
                  ),
                if (failure != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      failure!.message,
                      key: const Key('review-save-error'),
                      style: const TextStyle(color: errorInk),
                    ),
                  ),
                  if (failure!.code == FailureCode.conflict)
                    OutlinedButton(
                      onPressed: busy ? null : rebase,
                      child: const Text(
                        'Apply my edited fields to the latest revision',
                      ),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('save-review-edit'),
              onPressed: busy ? null : save,
              child: Text(busy ? 'Saving…' : 'Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}
