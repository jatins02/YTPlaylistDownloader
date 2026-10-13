import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/fixture_journey.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import 'theme.dart';

class FixtureTrackEditor extends StatefulWidget {
  const FixtureTrackEditor({
    super.key,
    required this.journey,
    required this.initial,
  });
  final FixtureJourney journey;
  final FixtureTrack initial;
  @override
  State<FixtureTrackEditor> createState() => _FixtureTrackEditorState();
}

class _FixtureTrackEditorState extends State<FixtureTrackEditor> {
  late final title = TextEditingController(text: widget.initial.metadata.title);
  late final artists = TextEditingController(
    text: widget.initial.metadata.artists.join('\n'),
  );
  late final features = TextEditingController(
    text: widget.initial.metadata.featuredArtists.join('\n'),
  );
  late final version = TextEditingController(
    text: widget.initial.metadata.version,
  );
  late final album = TextEditingController(text: widget.initial.metadata.album);
  String? error;
  List<TextEditingController> get fields => [
    title,
    artists,
    features,
    version,
    album,
  ];

  List<String> names(String text) =>
      text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  SongMetadata metadata() => SongMetadata(
    title: title.text,
    artists: names(artists.text),
    featuredArtists: names(features.text),
    version: version.text,
    album: album.text,
    needsReview: names(artists.text).isEmpty,
  );

  @override
  void initState() {
    super.initState();
    for (final field in fields) {
      field.addListener(changed);
    }
  }

  void changed() => setState(() {
    error = null;
  });

  @override
  void dispose() {
    for (final field in fields) {
      field.removeListener(changed);
      field.dispose();
    }
    super.dispose();
  }

  void save() {
    try {
      final failure = widget.journey.commitEdit(
        widget.initial.id,
        widget.initial.revision,
        metadata(),
      );
      if (failure == null) {
        Navigator.pop(context);
      } else {
        setState(() => error = failure);
      }
    } on AppFailure catch (failure) {
      setState(() => error = failure.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    String preview;
    try {
      preview = '${metadata().displayName}.mp3';
    } on AppFailure {
      preview = 'Enter valid metadata to preview the filename.';
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: AlertDialog(
        scrollable: true,
        title: const Text('Edit track · demo'),
        content: SizedBox(
          width: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Explicit Save keeps these demo changes; Cancel discards them.',
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('edit-title'),
                controller: title,
                autofocus: true,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Song name'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('edit-artists'),
                controller: artists,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Artists (one per line)',
                  helperText: 'Leave empty only if the artist is unknown.',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('edit-features'),
                controller: features,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Features (one per line, optional)',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('edit-version'),
                controller: version,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Version (optional)',
                  helperText: 'Keep live, remix, slowed or clip details.',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('edit-album'),
                controller: album,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Album (optional)',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Filename preview',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SelectableText(preview, key: const Key('edit-filename')),
              const SizedBox(height: 16),
              const Text(
                'Original source title',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SelectableText(widget.initial.originalTitle),
              if (error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(error!, style: const TextStyle(color: errorInk)),
                ),
                TextButton(
                  onPressed: () => showDemoSettings(context, widget.journey),
                  child: const Text('Open demo settings'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('cancel-edit'),
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('commit-edit'),
            onPressed: save,
            child: const Text('Save edits'),
          ),
        ],
      ),
    );
  }
}

Future<void> showDemoSettings(BuildContext context, FixtureJourney journey) =>
    showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: journey,
        builder: (context, _) => AlertDialog(
          scrollable: true,
          title: const Text('Demo settings'),
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          titlePadding: const EdgeInsets.all(12),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          actionsPadding: const EdgeInsets.all(8),
          content: SizedBox(
            width: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'These switches simulate recoverable errors. No credentials or real device permissions are used.',
                ),
                const SizedBox(height: 16),
                CheckboxListTile(
                  key: const Key('simulate-edit-failure'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fail edit saves'),
                  subtitle: const Text('Keep typed text and allow retry.'),
                  value: journey.simulateEditFailure,
                  onChanged: (value) => journey.configureFailures(
                    edits: value!,
                    saves: journey.simulateSaveFailure,
                  ),
                ),
                CheckboxListTile(
                  key: const Key('simulate-save-failure'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Deny destination save'),
                  subtitle: const Text(
                    'Keep the frozen review and allow cancellation.',
                  ),
                  value: journey.simulateSaveFailure,
                  onChanged: (value) => journey.configureFailures(
                    edits: journey.simulateEditFailure,
                    saves: value!,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Real AI-key settings remain in Playlist drafts. This demo does not read a key or call a provider.',
                  style: TextStyle(color: mutedInk),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
