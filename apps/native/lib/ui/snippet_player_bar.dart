import 'package:flutter/material.dart';

import '../application/processing_controller.dart';
import 'theme.dart';

class SnippetPlayerBar extends StatefulWidget {
  const SnippetPlayerBar({super.key, required this.controller});
  final ProcessingController controller;
  @override
  State<SnippetPlayerBar> createState() => _SnippetPlayerBarState();
}

class _SnippetPlayerBarState extends State<SnippetPlayerBar> {
  double? dragging;
  String time(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller.player,
    builder: (context, _) {
      final player = widget.controller.player;
      final tracks = widget.controller.tracks
          .where((t) => t.id == player.trackId)
          .toList();
      if (tracks.isEmpty) return const SizedBox.shrink();
      final name = tracks.single.metadata.songTitle,
          total = player.duration.inMilliseconds.toDouble();
      return SafeArea(
        top: false,
        child: Material(
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    IconButton(
                      tooltip: player.playing || player.loading
                          ? 'Pause $name'
                          : 'Play $name',
                      onPressed: widget.controller.canPlaySnippets
                          ? () => player.toggle(tracks.single.id)
                          : null,
                      icon: Icon(
                        player.playing || player.loading
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Stop snippet',
                      onPressed: () => player.pause(clear: true),
                      icon: const Icon(Icons.stop),
                    ),
                    Text(
                      player.loading
                          ? 'Preparing snippet…'
                          : '${time(player.position)} / ${time(player.duration)}',
                    ),
                  ],
                ),
                if (total > 0)
                  Slider(
                    value:
                        (dragging ?? player.position.inMilliseconds.toDouble())
                            .clamp(0, total),
                    min: 0,
                    max: total,
                    semanticFormatterCallback: (value) =>
                        'Snippet position ${time(Duration(milliseconds: value.round()))}',
                    onChanged: widget.controller.canPlaySnippets
                        ? (value) => setState(() => dragging = value)
                        : null,
                    onChangeEnd: widget.controller.canPlaySnippets
                        ? (value) {
                            setState(() => dragging = null);
                            player.seek(Duration(milliseconds: value.round()));
                          }
                        : null,
                  ),
                if (player.failure != null)
                  Text(
                    player.failure!.message,
                    style: const TextStyle(color: errorInk),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
