import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/application/snippet_controller.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/platform/snippet_port.dart';

void main() {
  test(
    'rapid switching waits for output stop and skips superseded requests',
    () async {
      final port = ControlledSnippets(),
          player = SnippetController('job', port);
      await player.toggle('A');
      final gate = Completer<void>();
      port.stopGate = gate.future;
      final b = player.toggle('B'), c = player.toggle('C');
      await Future<void>.delayed(Duration.zero);
      expect(port.current, 'A');
      gate.complete();
      await Future.wait([b, c]);
      expect(port.starts, ['A', 'C']);
      expect(port.current, 'C');
      expect(port.maximumConcurrent, 1);
      player.dispose();
    },
  );

  test('late progress and completion cannot replace a newer snippet', () async {
    final port = ControlledSnippets(), player = SnippetController('job', port);
    await player.toggle('A');
    final stale = port.progress!;
    await player.toggle('B');
    stale(
      const SnippetProgress(
        'old',
        Duration(seconds: 29),
        Duration(seconds: 30),
      ),
    );
    expect(player.trackId, 'B');
    expect(player.assetId, 'asset-B');
    expect(player.position, Duration.zero);
    player.dispose();
  });

  test(
    'pause, seek and resume remain inside the same stable snippet identity',
    () async {
      final port = ControlledSnippets(),
          player = SnippetController('job', port);
      await player.toggle('A');
      port.progress!(
        const SnippetProgress(
          'asset-A',
          Duration(seconds: 7),
          Duration(seconds: 30),
        ),
      );
      await player.pause();
      await player.seek(const Duration(seconds: 10));
      expect(port.starts, ['A']);
      await player.toggle('A');
      expect(port.offsets.last, const Duration(seconds: 10));
      await player.seek(const Duration(seconds: 80));
      expect(player.playing, isFalse);
      expect(player.position, const Duration(seconds: 30));
      expect(port.current, isNull);
      player.dispose();
    },
  );

  test(
    'lifecycle stop during startup never starts a replacement or autoplays',
    () async {
      final port = ControlledSnippets(),
          player = SnippetController('job', port);
      final gate = Completer<void>();
      port.stopGate = gate.future;
      final start = player.toggle('A'), stop = player.pause();
      gate.complete();
      await Future.wait([start, stop]);
      expect(port.starts, isEmpty);
      expect(player.playing, isFalse);
      player.dispose();
    },
  );

  test('output stop failure prevents overlapping replacement and shows safe failure', () async {
    final port = ControlledSnippets(), player = SnippetController('job', port);
    await player.toggle('A');
    port.stopFailure = true;
    await player.toggle('B');
    expect(port.starts, ['A']);
    expect(player.failure?.code, FailureCode.mediaUnavailable);
    port.stopFailure = false;
    player.dispose();
  });

  test('a completed seek cannot move a newer resume request to the old end position', () async {
    final port = ControlledSnippets(), player = SnippetController('job', port);
    await player.toggle('A');
    final gate = Completer<void>();
    port.stopGate = gate.future;
    port.deferProgress = true;
    final seeking = player.seek(const Duration(seconds: 30));
    final switching = player.toggle('A');
    gate.complete();
    await Future.wait([seeking, switching]);
    expect(player.trackId, 'A');
    expect(player.position, Duration.zero);
    expect(player.loading, isTrue);
    player.dispose();
  });

  test(
    'a late pause failure cannot overwrite a newer playback result',
    () async {
      final port = ControlledSnippets(),
          player = SnippetController('job', port);
      await player.toggle('A');
      final gate = Completer<void>();
      port.stopGate = gate.future;
      port.failNextStop = true;
      final pausing = player.pause(), switching = player.toggle('B');
      gate.complete();
      await Future.wait([pausing, switching]);
      expect(player.trackId, 'B');
      expect(player.playing, isTrue);
      expect(player.failure, isNull);
      player.dispose();
    },
  );
}

final class ControlledSnippets implements SnippetPort {
  final starts = <String>[], offsets = <Duration>[];
  Completer<void>? _active;
  Future<void>? stopGate;
  bool stopFailure = false;
  bool failNextStop = false;
  bool deferProgress = false;
  String? current;
  int maximumConcurrent = 0;
  void Function(SnippetProgress)? progress;
  @override
  Future<void> playSnippet(
    String jobId,
    String trackId,
    Duration position,
    void Function(SnippetProgress) progress,
  ) {
    if (_active != null) throw StateError('Overlapping output');
    current = trackId;
    starts.add(trackId);
    offsets.add(position);
    maximumConcurrent = 1;
    this.progress = progress;
    _active = Completer<void>();
    if (!deferProgress) {
      progress(
        SnippetProgress(
          'asset-$trackId',
          position,
          const Duration(seconds: 30),
        ),
      );
    }
    return _active!.future;
  }

  @override
  Future<void> stopSnippet() async {
    await stopGate;
    if (failNextStop) {
      failNextStop = false;
      throw StateError('private backend diagnostic');
    }
    if (stopFailure) throw StateError('private backend diagnostic');
    _active?.complete();
    _active = null;
    current = null;
  }
}
