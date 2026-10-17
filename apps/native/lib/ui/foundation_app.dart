import 'package:flutter/material.dart';

import '../application/drafts_controller.dart';
import '../application/processing_controller.dart';
import '../data/job_repository.dart';
import '../platform/media_port.dart';
import 'processing_screen.dart';
import 'fixture_screen.dart';
import 'theme.dart';
import 'workspace_components.dart';

class FoundationApp extends StatelessWidget {
  const FoundationApp({
    super.key,
    required this.controller,
    this.recoveredAttempts = 0,
    this.media,
  });
  final DraftsController controller;
  final int recoveredAttempts;
  final MediaPort? media;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'YTPlaylistDownloader',
    theme: appTheme,
    home: DraftsScreen(
      controller: controller,
      recoveredAttempts: recoveredAttempts,
      media: media,
    ),
  );
}

class DraftsScreen extends StatefulWidget {
  const DraftsScreen({
    super.key,
    required this.controller,
    required this.recoveredAttempts,
    this.media,
  });
  final DraftsController controller;
  final int recoveredAttempts;
  final MediaPort? media;
  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final submitted = input.text;
    final saved = await widget.controller.saveDraft(submitted);
    if (!mounted || !saved) return;
    if (input.text == submitted) input.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Playlist draft saved on this device.')),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      return Scaffold(
        appBar: AppBar(
          backgroundColor: blush,
          title: const Text(
            'YTPlaylistDownloader',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: 'AI key settings',
              onPressed: () => showWorkspaceDialog<void>(
                context: context,
                builder: (_) => _KeySettings(controller: state),
              ),
              icon: const Icon(Icons.key_outlined),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    'Playlist drafts',
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Keep playlist links and your personal AI key privately on this device.',
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: input,
                    key: const Key('playlist-input'),
                    decoration: const InputDecoration(
                      labelText: 'YouTube playlist link',
                      hintText: 'https://www.youtube.com/playlist?list=…',
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    onSubmitted: state.savingDraft ? null : (_) => _save(),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const Key('save-draft'),
                      onPressed: state.savingDraft ? null : _save,
                      icon: const Icon(Icons.add),
                      label: Text(state.savingDraft ? 'Saving…' : 'Save draft'),
                    ),
                  ),
                  if (state.failure != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          state.failure!.message,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  Text(
                    widget.media == null
                        ? 'Downloads and previews are not enabled in this foundation build.'
                        : 'Open a saved playlist to see the processing, review and device-save actions available on this device. Naming uses your own configured AI key.',
                    style: TextStyle(color: mutedInk),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const Key('open-fixture-journey'),
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => const FixtureScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('Explore the fictional demo'),
                    ),
                  ),
                  if (widget.recoveredAttempts > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        '${widget.recoveredAttempts} interrupted processing steps were recovered.',
                      ),
                    ),
                  const SizedBox(height: 24),
                  if (state.loading)
                    const Center(
                      child: WorkspaceProgress(label: 'Loading saved drafts'),
                    )
                  else if (state.drafts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'No drafts yet. Paste a playlist link to begin.',
                      ),
                    )
                  else
                    for (final job in state.drafts)
                      Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                job.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              SelectableText(job.sourceUrl),
                              const SizedBox(height: 8),
                              Text(
                                'Saved draft · ${job.phase.name}',
                                style: const TextStyle(color: mutedInk),
                              ),
                              if (widget.media != null &&
                                  state.jobs is JobRepository) ...[
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  key: Key('open-job-${job.id}'),
                                  onPressed: () async {
                                    await Navigator.of(context).push<void>(
                                      MaterialPageRoute(
                                        builder: (_) => ProcessingScreen(
                                          onKeySettings: () =>
                                              showWorkspaceDialog<void>(
                                                context: context,
                                                builder: (_) => _KeySettings(
                                                  controller: state,
                                                ),
                                              ),
                                          controller: ProcessingController(
                                            jobId: job.id,
                                            jobs: state.jobs as JobRepository,
                                            media: widget.media!,
                                          ),
                                        ),
                                      ),
                                    );
                                    if (mounted) await state.load();
                                  },
                                  icon: const Icon(Icons.folder_open),
                                  label: const Text('Open playlist'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _KeySettings extends StatefulWidget {
  const _KeySettings({required this.controller});
  final DraftsController controller;
  @override
  State<_KeySettings> createState() => _KeySettingsState();
}

class _KeySettingsState extends State<_KeySettings> {
  final keyInput = TextEditingController();
  bool hidden = true;
  @override
  void dispose() {
    keyInput.clear();
    keyInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      return AlertDialog(
        title: const Text('Your AI key'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.hasKey
                      ? 'A Groq key is stored securely on this device.'
                      : 'Add your own Groq key to prepare for AI naming.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: keyInput,
                  key: const Key('groq-key-input'),
                  obscureText: hidden,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Groq API key',
                    hintText: 'gsk_…',
                    suffixIcon: IconButton(
                      tooltip: hidden ? 'Show API key' : 'Hide API key',
                      onPressed: () => setState(() => hidden = !hidden),
                      icon: Icon(
                        hidden
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'The key stays in your device’s secure storage. No account or shared developer key is used.',
                  style: TextStyle(color: mutedInk),
                ),
                if (state.credentialFailure != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        state.credentialFailure!.message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (state.hasKey)
            TextButton(
              onPressed: state.savingKey ? null : state.removeKey,
              child: const Text('Remove key'),
            ),
          TextButton(
            onPressed: state.savingKey ? null : () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: state.savingKey
                ? null
                : () async {
                    final saved = await state.saveKey(keyInput.text);
                    if (!context.mounted || !saved) return;
                    keyInput.clear();
                    Navigator.pop(context);
                  },
            child: Text(state.savingKey ? 'Saving…' : 'Save key'),
          ),
        ],
      );
    },
  );
}
