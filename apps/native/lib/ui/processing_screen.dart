import 'dart:async';

import 'package:flutter/material.dart';

import '../application/processing_controller.dart';
import '../domain/media_models.dart';
import '../domain/models.dart';
import '../platform/media_port.dart';
import 'workspace_components.dart';
import 'theme.dart';

class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key, required this.controller});
  final ProcessingController controller;
  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      final job = state.job;
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'Playlist processing',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (job == null)
                    if (state.failure != null) ...[
                      WorkspaceNotice(
                        icon: Icons.error_outline,
                        title: 'Playlist could not be opened',
                        message: state.failure!.message,
                        error: true,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => state.refresh(force: true),
                        child: const Text('Retry loading playlist'),
                      ),
                    ] else
                      const CircularProgressIndicator(
                        semanticsLabel: 'Loading this playlist',
                      )
                  else ...[
                    WorkspaceHeading(
                      'Prepare your tracks',
                      subtitle: 'Processing happens on this device. Keep the app open; interrupted work can resume from verified local files.',
                    ),
                    const SizedBox(height: 16),
                    WorkspaceNotice(
                      icon: Icons.info_outline,
                      title: state.capability?.canAcquire == true
                          ? 'Real Linux media pipeline'
                          : 'Media runtime unavailable',
                      message: state.capability?.canAcquire == true
                          ? 'This build prepares full MP3s and short previews. AI naming, covers, playback and final device saving are still being built.'
                          : state.capability?.platform == DevicePlatform.linux
                          ? 'Media tools need setup on this device. Follow the local setup guide and reopen the app; your playlist remains saved.'
                          : 'Media processing is not available on this platform in this build. Your playlist remains saved; the fictional demo is separate.',
                    ),
                    const SizedBox(height: 16),
                    SelectableText(job.sourceUrl),
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        'Phase: ${_jobPhaseLabel(job.phase)} · ${state.readyCount} ready · ${state.failedCount} failed tracks · ${state.unmappedCount} unavailable entries · ${state.entries.length} playlist entries',
                        key: const Key('real-processing-counts'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (job.failure != null || state.failure != null) ...[
                      const SizedBox(height: 12),
                      WorkspaceNotice(
                        icon: Icons.error_outline,
                        title: 'Processing needs attention',
                        error: true,
                        message:
                            state.failure?.message ??
                            mediaFailureMessage(job.failure),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        if ([
                          JobPhase.draft,
                          JobPhase.queued,
                          JobPhase.failed,
                        ].contains(job.phase))
                          FilledButton.icon(
                            key: const Key('start-processing'),
                            onPressed:
                                state.commanding ||
                                    state.cancelling ||
                                    state.capability?.canAcquire != true
                                ? null
                                : state.start,
                            icon: const Icon(Icons.download_outlined),
                            label: Text(
                              job.phase == JobPhase.draft
                                  ? 'Process playlist'
                                  : 'Resume processing',
                            ),
                          ),
                        if (job.phase == JobPhase.reviewReady &&
                            state.failedCount > 0)
                          FilledButton.icon(
                            key: const Key('retry-processing'),
                            onPressed:
                                state.commanding ||
                                    state.cancelling ||
                                    state.capability?.canAcquire != true
                                ? null
                                : () => state.start(retryFailed: true),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry failed tracks'),
                          ),
                        if (state.processing && state.media is ManagedMediaPort)
                          OutlinedButton(
                            key: const Key('pause-processing'),
                            onPressed: state.cancelling ? null : state.pause,
                            child: const Text('Pause and keep progress'),
                          ),
                        if (job.phase == JobPhase.cancelled &&
                            state.media is ManagedMediaPort)
                          OutlinedButton(
                            key: const Key('discard-private-media'),
                            onPressed: state.cancelling
                                ? null
                                : state.discardMedia,
                            child: const Text('Remove temporary media'),
                          ),
                        if (state.capability?.canAcquire == true &&
                            ![
                              JobPhase.cancelled,
                              JobPhase.exporting,
                              JobPhase.exportReady,
                            ].contains(job.phase))
                          OutlinedButton(
                            key: const Key('cancel-processing'),
                            onPressed: state.cancelling ? null : state.cancel,
                            child: Text(
                              state.cancelling
                                  ? 'Stopping…'
                                  : 'Cancel processing',
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    if (job.phase == JobPhase.reviewReady &&
                        state.tracks.isEmpty &&
                        state.entries.isEmpty)
                      const Text(
                        'This playlist is empty. Return to drafts to import another link.',
                      ),
                    if (job.phase == JobPhase.cancelled)
                      const Text(
                        'This job was cancelled. Verified files are kept privately until cleanup; import a new draft to start again.',
                      ),
                    for (final entry in state.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _EntryCard(entry: entry, state: state),
                      ),
                    if (job.phase == JobPhase.reviewReady) ...[
                      const SizedBox(height: 16),
                      const Text(
                        'Prepared files remain private temporary assets. No files have been saved to your device destination yet.',
                        style: TextStyle(color: mutedInk),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry, required this.state});
  final StoredEntry entry;
  final ProcessingController state;
  @override
  Widget build(BuildContext context) {
    final matching = state.tracks.where((t) => t.id == entry.trackId).toList();
    final track = matching.isEmpty ? null : matching.single;
    final occurrences = state.entries
        .where((e) => e.trackId != null && e.trackId == entry.trackId)
        .length;
    return WorkspaceSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${entry.position}. ${entry.title}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            track == null
                ? 'Unavailable playlist entry'
                : 'Track state: ${_trackPhaseLabel(track.phase)}${occurrences > 1 ? ' · $occurrences occurrences, one audio copy' : ''}',
            style: const TextStyle(color: mutedInk),
          ),
          if (track?.durationSeconds != null)
            Text('${track!.durationSeconds!.toStringAsFixed(1)} seconds'),
          for (final failure in {?entry.failure, ?track?.failure})
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                mediaFailureMessage(failure),
                style: const TextStyle(color: errorInk),
              ),
            ),
          if (track?.phase == TrackPhase.ready)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Full audio and preview verified · source-title fallback · artist needs review',
                style: TextStyle(color: mutedInk),
              ),
            ),
        ],
      ),
    );
  }
}

String _jobPhaseLabel(JobPhase phase) => switch (phase) {
  JobPhase.draft => 'Saved draft',
  JobPhase.queued => 'Paused / ready to resume',
  JobPhase.enumerating => 'Reading playlist',
  JobPhase.processing => 'Preparing audio',
  JobPhase.reviewReady => 'Ready to review',
  JobPhase.exporting => 'Saving files',
  JobPhase.exportReady => 'Files ready',
  JobPhase.cancelled => 'Cancelled',
  JobPhase.failed => 'Needs attention',
};
String _trackPhaseLabel(TrackPhase phase) => switch (phase) {
  TrackPhase.queued => 'Waiting',
  TrackPhase.downloading => 'Preparing source',
  TrackPhase.converting => 'Preparing / verifying audio',
  TrackPhase.enriching => 'Updating details',
  TrackPhase.ready => 'Audio ready',
  TrackPhase.failed => 'Unavailable',
  TrackPhase.cancelled => 'Cancelled',
};
