import 'package:flutter/material.dart';

import '../application/fixture_journey.dart';
import 'theme.dart';
import 'fixture_components.dart';
import 'workspace_components.dart';
import 'fixture_editor.dart';

/// A deliberately separate, disposable fixture route. No media port is called.
class FixtureScreen extends StatefulWidget {
  const FixtureScreen({super.key, this.journey});
  final FixtureJourney? journey;
  @override
  State<FixtureScreen> createState() => _FixtureScreenState();
}

class _FixtureScreenState extends State<FixtureScreen>
    with WidgetsBindingObserver {
  late final FixtureJourney journey = widget.journey ?? FixtureJourney();
  final playlist = TextEditingController(
    text: 'https://www.youtube.com/playlist?list=PLfictionalDemo01',
  );
  FixtureExportFormat format = FixtureExportFormat.zip;
  final scroll = ScrollController();
  FixturePhase lastPhase = FixturePhase.import;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    lastPhase = journey.phase;
    journey.addListener(onJourneyChanged);
  }

  void onJourneyChanged() {
    if (journey.phase == lastPhase) return;
    lastPhase = journey.phase;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) scroll.jumpTo(0);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) journey.stopPreview();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    journey.removeListener(onJourneyChanged);
    scroll.dispose();
    playlist.dispose();
    if (widget.journey == null) journey.dispose();
    super.dispose();
  }

  Future<void> edit(FixtureTrack track) async {
    final initial = journey.beginEdit(track.id);
    if (initial == null) return;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => FixtureTrackEditor(journey: journey, initial: initial),
      );
    } finally {
      journey.cancelEdit(track.id);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: journey,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text(
          'Playlist workspace',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Demo settings',
            onPressed: () => showDemoSettings(context, journey),
            icon: const Icon(Icons.tune),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: ListView(
              key: const Key('fixture-scroll'),
              controller: scroll,
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 640 ? 16 : 24,
              ),
              children: [
                WorkspaceNotice(
                  icon: Icons.science_outlined,
                  title: 'Fictional demo · Stage 2',
                  message: journey.phase == FixturePhase.import
                      ? 'Try the journey with made-up tracks. No playlist is fetched, no audio plays and no music files are saved. Demo edits are temporary.'
                      : 'Fictional tracks · no audio or file writes · temporary edits.',
                ),
                const SizedBox(height: 20),
                FixtureStepTrail(phase: journey.phase),
                const SizedBox(height: 24),
                if (journey.error != null) ...[
                  WorkspaceNotice(
                    icon: Icons.error_outline,
                    title: 'Action needed',
                    message: journey.error!,
                    error: true,
                  ),
                  const SizedBox(height: 16),
                ],
                ...switch (journey.phase) {
                  FixturePhase.import => importContent(context),
                  FixturePhase.loading ||
                  FixturePhase.processing => progressContent(context),
                  FixturePhase.review => reviewContent(context),
                  FixturePhase.saving ||
                  FixturePhase.saved => saveContent(context),
                  FixturePhase.expired => stateContent(
                    'This demo draft has expired',
                    'Temporary audio would need to be prepared again. Already exported device files would remain yours.',
                    'Start a new demo',
                    journey.reset,
                  ),
                  FixturePhase.offline => stateContent(
                    'Connection lost · simulated',
                    'Processing is paused. Completed work would be kept on your device; retry when you are connected.',
                    'Retry connection',
                    journey.retryConnection,
                  ),
                  FixturePhase.cancelled => stateContent(
                    'Demo processing cancelled',
                    '${journey.completedCount} of ${journey.tracks.length} fixture tracks finished before cancellation. No files were changed.',
                    'Start a new demo',
                    journey.reset,
                  ),
                },
              ],
            ),
          ),
        ),
      ),
    ),
  );

  List<Widget> importContent(BuildContext context) => [
    WorkspaceHeading(
      'Bring your playlist',
      subtitle: 'Paste a playlist link to try the interface. This demo always uses the fictional sample.',
    ),
    const SizedBox(height: 20),
    WorkspaceSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('demo-playlist'),
            controller: playlist,
            decoration: const InputDecoration(
              labelText: 'YouTube playlist link',
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => journey.start(playlist.text),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<FixtureScenario>(
            key: const Key('demo-scenario'),
            initialValue: journey.scenario,
            isExpanded: true,
            itemHeight: null,
            decoration: const InputDecoration(labelText: 'Demo scenario'),
            items: [
              for (final scenario in FixtureScenario.values)
                DropdownMenuItem(value: scenario, child: Text(scenario.label)),
            ],
            onChanged: (value) {
              if (value != null) journey.chooseScenario(value);
            },
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('start-demo'),
            onPressed: () => journey.start(playlist.text),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Start fictional import'),
          ),
        ],
      ),
    ),
  ];

  List<Widget> progressContent(BuildContext context) {
    final loading = journey.phase == FixturePhase.loading;
    return [
      WorkspaceHeading(
        loading ? 'Reading the demo playlist' : 'Preparing fixture tracks',
        subtitle: loading
            ? 'The real app will discover playlist entries here.'
            : '${journey.completedCount} of ${journey.tracks.length} unique tracks finished · ${journey.occurrenceCount} playlist entries',
      ),
      const SizedBox(height: 20),
      WorkspaceSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                loading
                    ? 'Discovering entries · simulated'
                    : 'Acquisition, conversion and naming · simulated',
              ),
            ),
            const SizedBox(height: 12),
            if (loading)
              const LinearProgressIndicator(
                semanticsLabel: 'Demo playlist discovery; total not yet known',
              )
            else
              LinearProgressIndicator(
                value: journey.completedCount / journey.tracks.length,
                semanticsLabel:
                    'Fixture preparation: ${journey.completedCount} of ${journey.tracks.length} finished',
              ),
            const SizedBox(height: 16),
            const Text(
              'Use Next demo step to advance this simulation. Real processing will use measured progress.',
              style: TextStyle(color: mutedInk),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  key: const Key('next-demo-step'),
                  onPressed: journey.advance,
                  icon: const Icon(Icons.skip_next_outlined),
                  label: const Text('Next demo step'),
                ),
                OutlinedButton(
                  onPressed: journey.cancelProcessing,
                  child: const Text('Cancel processing'),
                ),
              ],
            ),
          ],
        ),
      ),
      if (!loading) ...[
        const SizedBox(height: 20),
        for (final track in journey.tracks)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: WorkspaceSurface(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.music_note_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track.metadata.songTitle),
                        const SizedBox(height: 4),
                        Text(
                          fixtureTrackStateLabel(track.state),
                          style: const TextStyle(color: mutedInk),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ];
  }

  List<Widget> reviewContent(BuildContext context) {
    if (journey.tracks.isEmpty) {
      return stateContent(
        'This playlist is empty',
        'No songs are available to review. Try another playlist or demo scenario.',
        'Start a new demo',
        journey.reset,
      );
    }
    return [
      WorkspaceHeading(
        'Make it yours',
        subtitle: 'Review names, inspect original titles and choose the tracks to keep.',
      ),
      const SizedBox(height: 16),
      Semantics(
        liveRegion: true,
        child: Text(
          '${journey.selectedCount} selected · ${journey.excludedCount} excluded · ${journey.failedCount} unavailable',
          key: const Key('selection-summary'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        '${journey.occurrenceCount} playlist entries · ${journey.tracks.length} unique recordings. Repeated sources export once; equal titles remain separate.',
        style: const TextStyle(color: mutedInk),
      ),
      const SizedBox(height: 20),
      for (final track in journey.tracks) ...[
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FixtureTrackCard(
            key: Key('track-card-${track.id}'),
            track: track,
            journey: journey,
            onEdit: () => edit(track),
          ),
        ),
        if (journey.activeTrackId == track.id)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: FixturePlayer(journey: journey),
          ),
      ],
      WorkspaceSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Save to your device',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Preview the final save step. Actual file verification and the device destination chooser arrive in Stage 6.',
              style: TextStyle(color: mutedInk),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<FixtureExportFormat>(
              initialValue: format,
              isExpanded: true,
              itemHeight: null,
              decoration: const InputDecoration(labelText: 'File format'),
              items: const [
                DropdownMenuItem(
                  value: FixtureExportFormat.zip,
                  child: Text('ZIP with MP3 files'),
                ),
                DropdownMenuItem(
                  value: FixtureExportFormat.mp3,
                  child: Text('Individual MP3 files'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => format = value);
              },
            ),
            const SizedBox(height: 16),
            if (journey.saveBlockedReason != null) ...[
              Text(
                journey.saveBlockedReason!,
                key: const Key('save-blocked-reason'),
                style: const TextStyle(color: mutedInk),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              key: const Key('demo-save-device'),
              onPressed: journey.saveBlockedReason == null
                  ? () => journey.beginSave(format)
                  : null,
              icon: const Icon(Icons.save_alt),
              label: Text(
                'Save ${journey.selectedCount} tracks to device · demo',
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> saveContent(BuildContext context) {
    final preview = journey.savePreview!;
    final saved = journey.phase == FixturePhase.saved;
    return [
      WorkspaceHeading(
        saved ? 'Demo journey complete' : 'Confirm your demo save',
        subtitle: saved
            ? 'No files were written. Your fictional review is ready for another look.'
            : '${preview.items.length} selected tracks · ${journey.excludedCount} excluded · ${preview.format == FixtureExportFormat.zip ? 'ZIP with MP3 files' : 'Individual MP3 files'}',
      ),
      const SizedBox(height: 20),
      WorkspaceNotice(
        icon: saved ? Icons.check_circle_outline : Icons.folder_outlined,
        title: saved
            ? 'Simulation completed; no device download'
            : 'Destination chooser preview',
        message: 'The real app will ask where to save verified full-length files. Closing or denying that chooser will preserve your review.',
      ),
      const SizedBox(height: 20),
      WorkspaceSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Frozen filename preview',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Illustrative names only. Equal names keep separate numbered copies.',
              style: TextStyle(color: mutedInk),
            ),
            const SizedBox(height: 12),
            for (final item in preview.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(item.filename),
              ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          if (!saved)
            FilledButton.icon(
              key: const Key('finish-demo-save'),
              onPressed: journey.finishSave,
              icon: const Icon(Icons.check),
              label: Text(
                journey.error == null
                    ? 'Simulate destination save'
                    : 'Retry demo save',
              ),
            ),
          OutlinedButton(
            key: const Key('return-to-review'),
            onPressed: journey.cancelSave,
            child: Text(saved ? 'Back to review' : 'Cancel · return to review'),
          ),
          if (saved)
            TextButton(
              onPressed: journey.reset,
              child: const Text('Start a new demo'),
            ),
        ],
      ),
    ];
  }

  List<Widget> stateContent(
    String title,
    String message,
    String action,
    VoidCallback callback,
  ) => [
    WorkspaceSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WorkspaceHeading(title, subtitle: message),
          const SizedBox(height: 24),
          FilledButton(onPressed: callback, child: Text(action)),
        ],
      ),
    ),
  ];
}
