import 'package:flutter/material.dart';

import '../application/fixture_journey.dart';
import 'theme.dart';

class FixtureStepTrail extends StatelessWidget {
  const FixtureStepTrail({super.key, required this.phase});
  final FixturePhase phase;
  @override
  Widget build(BuildContext context) {
    final index = switch (phase) {
      FixturePhase.import => 0,
      FixturePhase.loading ||
      FixturePhase.processing ||
      FixturePhase.offline ||
      FixturePhase.cancelled => 1,
      FixturePhase.review || FixturePhase.expired => 2,
      FixturePhase.saving || FixturePhase.saved => 3,
    };
    const labels = ['Import', 'Prepare', 'Review', 'Save'];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < labels.length; i++)
          Semantics(
            selected: i == index,
            child: Chip(
              backgroundColor: i == index ? surfaceMuted : Colors.white,
              side: BorderSide(color: i == index ? focus : decorativeBorder),
              label: Text('${i + 1}  ${labels[i]}'),
            ),
          ),
      ],
    );
  }
}

class FixtureHeading extends StatelessWidget {
  const FixtureHeading(this.title, {super.key, required this.subtitle});
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        liveRegion: true,
        child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
      ),
      const SizedBox(height: 8),
      Text(subtitle, style: const TextStyle(color: mutedInk)),
    ],
  );
}

class FixtureSurface extends StatelessWidget {
  const FixtureSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class FixtureNotice extends StatelessWidget {
  const FixtureNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.error = false,
  });
  final IconData icon;
  final String title;
  final String message;
  final bool error;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: error,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceMuted,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: error ? errorInk : ink),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: error ? errorInk : ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(message, style: const TextStyle(color: mutedInk)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String fixtureTrackStateLabel(FixtureTrackState state) => switch (state) {
  FixtureTrackState.waiting => 'Waiting',
  FixtureTrackState.ready => 'Ready for review',
  FixtureTrackState.failed => 'Unavailable',
};

class FixtureTrackCard extends StatelessWidget {
  const FixtureTrackCard({
    super.key,
    required this.track,
    required this.journey,
    required this.onEdit,
  });
  final FixtureTrack track;
  final FixtureJourney journey;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) => FixtureSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: track.hasCover
                  ? 'Fictional cover illustration'
                  : 'No cover available',
              image: true,
              child: ExcludeSemantics(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: track.hasCover ? surfaceHover : surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    track.hasCover
                        ? Icons.nightlight_outlined
                        : Icons.album_outlined,
                    color: mutedInk,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.metadata.songTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    track.metadata.artists.isEmpty
                        ? 'Unknown Artist'
                        : track.metadata.artists.join(', '),
                    style: const TextStyle(color: mutedInk),
                  ),
                  if (track.metadata.featuredArtists.isNotEmpty)
                    Text(
                      'Featuring ${track.metadata.featuredArtists.join(', ')}',
                      style: const TextStyle(color: mutedInk),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${track.durationSeconds ~/ 60}:${(track.durationSeconds % 60).toString().padLeft(2, '0')} · ${fixtureTrackStateLabel(track.state)}${track.occurrences > 1 ? ' · ${track.occurrences} playlist occurrences' : ''}',
          style: const TextStyle(color: mutedInk),
        ),
        if (!track.hasCover)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('No reliable cover', style: TextStyle(color: mutedInk)),
          ),
        if (track.warning != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              track.warning!,
              style: TextStyle(
                color: track.state == FixtureTrackState.failed
                    ? errorInk
                    : mutedInk,
              ),
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              label: 'Include ${track.metadata.songTitle}',
              child: Checkbox(
                key: Key('select-${track.id}'),
                value: track.selected,
                onChanged: journey.editingId != null
                    ? null
                    : (value) => journey.select(track.id, value!),
              ),
            ),
            const Text('Include'),
            if (track.state == FixtureTrackState.ready)
              Semantics(
                label:
                    '${journey.activeTrackId == track.id ? 'Stop preview for' : 'Preview'} ${track.metadata.songTitle}; silent demo',
                child: OutlinedButton.icon(
                  key: Key('play-${track.id}'),
                  onPressed: () => journey.togglePreview(track.id),
                  icon: Icon(
                    journey.activeTrackId == track.id
                        ? Icons.stop
                        : Icons.play_arrow,
                  ),
                  label: Text(
                    journey.activeTrackId == track.id
                        ? 'Stop demo'
                        : 'Preview demo',
                  ),
                ),
              )
            else
              OutlinedButton.icon(
                key: Key('retry-${track.id}'),
                onPressed: () => journey.retryTrack(track.id),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry demo'),
              ),
            Semantics(
              label: 'Edit ${track.metadata.songTitle}',
              child: OutlinedButton.icon(
                key: Key('edit-${track.id}'),
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
            ),
            TextButton(
              key: Key('details-${track.id}'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  scrollable: true,
                  title: const Text('Track details'),
                  content: SizedBox(
                    width: 560,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Full name',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(track.metadata.displayName),
                        const SizedBox(height: 20),
                        const Text(
                          'Original source title',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(track.originalTitle),
                        const SizedBox(height: 16),
                        const Text(
                          'Fictional fixture. Cover illustrations are placeholders; no online artwork lookup has run.',
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
              child: const Text('Full details'),
            ),
          ],
        ),
      ],
    ),
  );
}

class FixturePlayer extends StatelessWidget {
  const FixturePlayer({super.key, required this.journey});
  final FixtureJourney journey;
  @override
  Widget build(BuildContext context) {
    final track = journey.track(journey.activeTrackId!);
    return FixtureSurface(
      key: const Key('demo-player'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Preview controls · silent simulation',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(track.metadata.songTitle),
          const SizedBox(height: 8),
          const Text(
            'No audio plays in Stage 2. Move the slider to try a bounded 30-second preview.',
            style: TextStyle(color: mutedInk),
          ),
          Slider(
            key: const Key('demo-preview-seek'),
            value: journey.previewSeconds.toDouble(),
            min: 0,
            max: 30,
            divisions: 30,
            semanticFormatterCallback: (value) =>
                '${value.round()} of 30 seconds; silent demo',
            onChanged: (value) => journey.seekPreview(value.round()),
          ),
          Text(
            '${journey.previewSeconds.toString().padLeft(2, '0')} / 30 seconds',
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: journey.stopPreview,
            icon: const Icon(Icons.stop),
            label: const Text('Stop preview demo'),
          ),
        ],
      ),
    );
  }
}
