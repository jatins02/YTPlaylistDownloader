import 'package:flutter/material.dart';

import '../application/processing_controller.dart';
import 'theme.dart';
import 'workspace_components.dart';

class ExportPanel extends StatelessWidget {
  const ExportPanel({super.key, required this.controller});
  final ProcessingController controller;
  @override
  Widget build(BuildContext context) {
    final state = controller, publication = state.publication;
    return WorkspaceSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            publication == null
                ? (state.exportBusy
                      ? 'Preparing verified files'
                      : 'Prepared files need attention')
                : 'Verified files ready to save',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (state.exportBusy) ...[
            const WorkspaceProgress(
              linear: true,
              label: 'Preparing or saving verified files',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('stop-device-save'),
              onPressed: state.stopDeviceSave,
              icon: const Icon(Icons.stop),
              label: const Text('Stop and keep progress'),
            ),
          ],
          if (state.saveMessage != null)
            Semantics(
              liveRegion: true,
              child: Text(
                state.saveMessage!,
                key: const Key('device-save-message'),
              ),
            )
          else if (state.savedCopy != null)
            Text(
              'Previously saved verified copy: ${state.savedCopy!.filename}',
              key: const Key('device-save-receipt'),
            ),
          if (state.capability?.canExport != true)
            const Text(
              'Saving is unavailable on this runtime. Your prepared files and review are kept.',
            ),
          if (!state.exportBusy)
            OutlinedButton(
              key: const Key('return-to-review'),
              onPressed: state.returnToReview,
              child: Text(
                state.savedTrackIds.isNotEmpty && state.remainingCount > 0
                    ? 'Choose remaining songs (${state.remainingCount})'
                    : 'Return to review',
              ),
            ),
          if (publication != null) ...[
            const SizedBox(height: 12),
            Text(
              '${publication.tracks.length} full-length MP3${publication.tracks.length == 1 ? '' : 's'} · ${state.excludedCount} excluded items',
            ),
            const Text(
              'The ZIP includes these MP3s and a checksum manifest. Repeated saves reuse this verified preparation.',
            ),
            if (publication.tracks.any(
              (f) => state.savedTrackIds.contains(f.trackId),
            ))
              Text(
                state.remainingCount > 0
                    ? 'Choose remaining songs to prepare a ZIP without already downloaded songs.'
                    : 'All songs in this preparation have been downloaded.',
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('save-export-zip'),
              onPressed: !state.canSaveFile(publication.archive)
                  ? null
                  : () => state.saveExportFile(publication.archive.id),
              icon: const Icon(Icons.folder_zip_outlined),
              label: const Text('Save ZIP'),
            ),
            const SizedBox(height: 12),
            for (final file in publication.tracks)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(file.filename),
                    OutlinedButton.icon(
                      key: Key('save-mp3-${file.trackId}'),
                      onPressed: !state.canSaveFile(file)
                          ? null
                          : () => state.saveExportFile(file.id),
                      icon: const Icon(Icons.audio_file_outlined),
                      label: Text(
                        state.savedTrackIds.contains(file.trackId)
                            ? 'Downloaded'
                            : 'Save MP3',
                        semanticsLabel:
                            state.savedTrackIds.contains(file.trackId)
                            ? 'Downloaded ${file.filename}'
                            : 'Save MP3 ${file.filename}',
                      ),
                    ),
                  ],
                ),
              ),
          ],

          const SizedBox(height: 12),
          const Text(
            'Choose a new filename to preserve existing files. Cancelling the save panel keeps these prepared files. Files saved outside the app survive temporary cleanup.',
            style: TextStyle(color: mutedInk),
          ),
          const Text(
            'Saving files does not automatically add them to every Music app.',
            style: TextStyle(color: mutedInk),
          ),
        ],
      ),
    );
  }
}
