import 'dart:async';

import 'package:flutter/material.dart';

import '../application/processing_controller.dart';
import '../domain/media_models.dart';
import '../domain/enrichment.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import '../platform/media_port.dart';
import 'workspace_components.dart';
import 'theme.dart';
import 'review_editor.dart';
import 'snippet_player_bar.dart';
import 'export_panel.dart';

class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({
    super.key,
    required this.controller,
    this.onKeySettings,
  });
  final ProcessingController controller;
  final Future<void> Function()? onKeySettings;
  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.controller.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(widget.controller.player.pause());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      final job = state.job;
      return Scaffold(
        bottomNavigationBar: ListenableBuilder(
          listenable: state.player,
          builder: (context, _) => state.editing
              ? const SizedBox.shrink()
              : SnippetPlayerBar(controller: state),
        ),
        appBar: AppBar(
          actions: [
            if (widget.onKeySettings != null)
              IconButton(
                tooltip: 'AI key settings',
                onPressed: widget.onKeySettings,
                icon: const Icon(Icons.key_outlined),
              ),
          ],
          title: const Text(
            'Playlist preparation and review',
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
                      switch (job.phase) {
                        JobPhase.reviewReady => 'Review your tracks',
                        JobPhase.exporting => 'Preparing files for saving',
                        JobPhase.exportReady => 'Save your files',
                        _ => 'Prepare your tracks',
                      },
                      subtitle: 'Processing happens on this device. Keep the app open; interrupted work can resume from verified local files.',
                    ),
                    const SizedBox(height: 16),
                    WorkspaceNotice(
                      icon: Icons.info_outline,
                      title: state.capability?.canAcquire == true
                          ? 'Real Linux media pipeline'
                          : 'Media runtime unavailable',
                      message: state.capability?.canAcquire == true
                          ? state.capability?.canExport == true
                                ? 'Prepare and review your tracks, then save a verified ZIP or individual MP3s to a location you choose.'
                                : state.capability?.canEnrich == true
                                ? 'Prepare audio, then listen to snippets, review names and choose covers. Your changes stay on this device. Final MP3/ZIP saving is not available in this build.'
                                : 'This build prepares full MP3s and short previews. Review and edit your names after preparation. Naming and cover tools need setup; final saving is not available in this build.'
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
                            (state.failedCount > 0 ||
                                [
                                  FailureCode.tagInvalid,
                                  FailureCode.audioInvalid,
                                  FailureCode.exportInvalid,
                                ].contains(state.failure?.code ?? job.failure)))
                          FilledButton.icon(
                            key: const Key('retry-processing'),
                            onPressed:
                                state.commanding ||
                                    state.cancelling ||
                                    state.capability?.canAcquire != true
                                ? null
                                : () => state.start(retryFailed: true),
                            icon: const Icon(Icons.refresh),
                            label: Text(
                              state.failedCount > 0
                                  ? 'Retry failed tracks'
                                  : 'Recheck audio',
                            ),
                          ),
                        if (job.phase == JobPhase.reviewReady &&
                            state.capability?.canEnrich == true) ...[
                          FilledButton.icon(
                            key: const Key('enrich-tracks'),
                            onPressed:
                                state.exportBusy ||
                                    state.commanding ||
                                    state.cancelling
                                ? null
                                : state.enrich,
                            icon: const Icon(Icons.auto_awesome_outlined),
                            label: const Text(
                              'Prepare / retry names and covers',
                            ),
                          ),
                          OutlinedButton.icon(
                            key: const Key('metadata-options'),
                            onPressed:
                                state.exportBusy ||
                                    state.commanding ||
                                    state.cancelling
                                ? null
                                : () => _options(context, state),
                            icon: const Icon(Icons.tune),
                            label: const Text('Naming settings'),
                          ),
                        ],
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
                      Text(
                        '${state.selectedCount} selected unique tracks · ${state.excludedCount} excluded items · ${state.selectedUnavailable} selected unavailable items',
                        key: const Key('review-selection-counts'),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        key: const Key('prepare-device-export'),
                        onPressed: state.canPrepareExport
                            ? state.prepareDeviceExport
                            : null,
                        child: const Text('Save to Device'),
                      ),
                      Text(
                        state.reviewBlockedReason ??
                            (state.capability?.canExport == true
                                ? 'Your selection is ready for verified saving.'
                                : 'Review is ready. Saving files to a device destination is not available in this build.'),
                        key: const Key('review-save-reason'),
                      ),
                      if (state.capability?.canPlaySnippets != true)
                        const Text(
                          'Local snippet playback is unavailable. On Linux, check your local audio service and verified runtime.',
                        ),
                      const SizedBox(height: 12),
                      const Text(
                        'Private temporary preparation does not save a copy to your destination.',
                        style: TextStyle(color: mutedInk),
                      ),
                    ],
                    if (state.exportBusy ||
                        job.phase == JobPhase.exporting ||
                        job.phase == JobPhase.exportReady)
                      ExportPanel(controller: state),
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

class _EntryCard extends StatefulWidget {
  const _EntryCard({required this.entry, required this.state});
  final StoredEntry entry;
  final ProcessingController state;
  @override
  State<_EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends State<_EntryCard>
    with AutomaticKeepAliveClientMixin {
  final _editFocus = FocusNode(debugLabel: 'Review edit action');
  bool _editing = false;
  StoredEntry get entry => widget.entry;
  ProcessingController get state => widget.state;
  @override
  bool get wantKeepAlive => _editing;
  @override
  void dispose() {
    _editFocus.dispose();
    super.dispose();
  }

  Future<void> edit(TrackRecord track) async {
    _editing = true;
    updateKeepAlive();
    try {
      await openReviewEditor(context, state, track);
    } finally {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          final target = _editFocus.context;
          if (target != null) {
            await Scrollable.ensureVisible(target, alignment: 0.5);
          }
          if (!mounted) return;
          _editFocus.requestFocus();
          _editing = false;
          updateKeepAlive();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final matching = state.tracks.where((t) => t.id == entry.trackId).toList();
    final track = matching.isEmpty ? null : matching.single;
    final details = track == null ? null : state.enrichment[track.id];
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
          if (state.job?.phase == JobPhase.reviewReady) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                track == null
                    ? 'Include unavailable entry'
                    : 'Include ${track.metadata.songTitle}${occurrences > 1 ? ' (all occurrences)' : ''}',
              ),
              value: track?.selected ?? entry.selected,
              onChanged:
                  state.exportBusy ||
                      state.commanding ||
                      state.editing ||
                      state.cancelling
                  ? null
                  : (value) {
                      if (track == null) {
                        state.selectEntry(entry, value ?? false);
                      } else {
                        state.selectTrack(track, value ?? false);
                      }
                    },
            ),
            if (track != null && track.phase == TrackPhase.ready)
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  ListenableBuilder(
                    listenable: state.player,
                    builder: (context, _) {
                      final active =
                          state.player.trackId == track.id &&
                          (state.player.playing || state.player.loading);
                      return Semantics(
                        label: track.metadata.songTitle,
                        child: OutlinedButton.icon(
                          key: Key('review-play-${entry.position}'),
                          onPressed: state.canPlaySnippets
                              ? () => state.player.toggle(track.id)
                              : null,
                          icon: Icon(active ? Icons.pause : Icons.play_arrow),
                          label: Text('${active ? 'Pause' : 'Play'} snippet'),
                        ),
                      );
                    },
                  ),
                  Semantics(
                    label: track.metadata.songTitle,
                    child: OutlinedButton.icon(
                      key: Key('review-edit-${entry.position}'),
                      focusNode: _editFocus,
                      onPressed:
                          state.exportBusy ||
                              state.commanding ||
                              state.cancelling
                          ? null
                          : () => edit(track),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit track'),
                    ),
                  ),
                ],
              ),
          ],
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
          if (track != null &&
              (track.phase == TrackPhase.ready ||
                  track.phase == TrackPhase.enriching)) ...[
            const SizedBox(height: 8),
            SelectableText(
              track.metadata.displayName,
              key: Key('metadata-name-${track.id}'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              track.metadata.needsReview
                  ? 'Names need review · original source title retained'
                  : 'Names prepared · original source title retained',
              style: const TextStyle(color: mutedInk),
            ),
            if (details?.artworkAssetId != null &&
                state.covers[track.id] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    state.covers[track.id]!,
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    semanticLabel:
                        'Front cover for ${track.metadata.songTitle}',
                    errorBuilder: (_, error, stack) => const Icon(
                      Icons.music_note_outlined,
                      semanticLabel: 'Cover could not be displayed',
                    ),
                  ),
                ),
              ),
            if (details != null && state.covers[track.id] == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Icon(
                  Icons.music_note_outlined,
                  size: 48,
                  color: mutedInk,
                  semanticLabel:
                      'No verified front cover for ${track.metadata.songTitle}',
                ),
              ),
            if (details != null) ...[
              Text(
                'Naming: ${details.naming.name} · Cover: ${details.artwork.name}',
                style: const TextStyle(color: mutedInk),
              ),
              if (details.reason != null)
                Text(details.reason!, style: const TextStyle(color: mutedInk)),
              for (final failure in {
                ?details.namingFailure,
                ?details.artworkFailure,
              })
                Text(
                  enrichmentFailureMessage(failure),
                  style: TextStyle(
                    color: failure == FailureCode.artworkUncertain
                        ? mutedInk
                        : errorInk,
                  ),
                ),
              if (details.provenance != null)
                Text(
                  state.covers[track.id] != null
                      ? 'Approved front cover · ${details.provenance!['album']}'
                      : 'Cover identity matched; image unavailable. Retry covers to verify it.',
                  style: const TextStyle(color: mutedInk),
                ),
            ],
          ],
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

Future<void> _options(BuildContext context, ProcessingController state) async {
  if (state.media is! EnrichingMediaPort) return;
  final port = state.media as EnrichingMediaPort;
  try {
    final options = await port.metadataOptions();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _MetadataOptions(port: port, options: options),
    );
  } on AppFailure catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Settings could not be loaded. Check private storage and retry.',
          ),
        ),
      );
    }
  }
}

class _MetadataOptions extends StatefulWidget {
  const _MetadataOptions({required this.port, required this.options});
  final EnrichingMediaPort port;
  final EnrichmentOptions options;
  @override
  State<_MetadataOptions> createState() => _MetadataOptionsState();
}

class _MetadataOptionsState extends State<_MetadataOptions> {
  late final model = TextEditingController(text: widget.options.model),
      contact = TextEditingController(text: widget.options.contact);
  bool saving = false;
  String? failure;
  @override
  void dispose() {
    model.dispose();
    contact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Naming and artwork settings'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('metadata-model-input'),
              controller: model,
              decoration: const InputDecoration(labelText: 'Groq model ID'),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('metadata-contact-input'),
              controller: contact,
              decoration: const InputDecoration(
                labelText: 'Public project URL or contact email',
              ),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 12),
            const Text(
              'Artwork requests identify this app with this public contact. Your API key remains in device secure storage.',
            ),
            if (failure != null)
              Text(failure!, style: const TextStyle(color: errorInk)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: saving
            ? null
            : () async {
                setState(() {
                  saving = true;
                  failure = null;
                });
                try {
                  await widget.port.saveMetadataOptions(
                    EnrichmentOptions(
                      model: model.text.trim(),
                      contact: contact.text.trim(),
                    ),
                  );
                  if (context.mounted) Navigator.pop(context);
                } on AppFailure catch (error) {
                  if (mounted) setState(() => failure = error.message);
                } catch (_) {
                  if (mounted) {
                    setState(
                      () => failure = 'Settings could not be saved. Your entered text is kept.',
                    );
                  }
                } finally {
                  if (mounted) setState(() => saving = false);
                }
              },
        child: Text(saving ? 'Saving…' : 'Save settings'),
      ),
    ],
  );
}
