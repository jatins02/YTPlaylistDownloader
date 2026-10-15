import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/failure.dart';
import '../platform/snippet_port.dart';

/// All replacements wait for native output to stop. Generations fence pending
/// preparation, late progress and completion; a lifecycle stop never autoplays.
final class SnippetController extends ChangeNotifier {
  SnippetController(this.jobId, this.port);
  final String jobId;
  final SnippetPort? port;
  String? trackId, assetId;
  Duration position = Duration.zero, duration = Duration.zero;
  bool loading = false, playing = false, _disposed = false;
  AppFailure? failure;
  int _generation = 0;
  Future<void> _commands = Future.value();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> toggle(String id) async {
    if (_disposed) return;
    if (trackId == id && (playing || loading)) {
      await pause();
      return;
    }
    final offset = trackId == id && position < duration
        ? position
        : Duration.zero;
    await _start(id, offset);
  }

  Future<void> _start(String id, Duration offset) async {
    if (_disposed) return;
    final generation = ++_generation;
    if (trackId != id) duration = Duration.zero;
    trackId = id;
    assetId = null;
    position = offset;
    loading = true;
    playing = false;
    failure = null;
    _notify();
    _commands = _commands.then((_) async {
      try {
        await port?.stopSnippet();
        if (_disposed || generation != _generation) return;
        if (port == null) {
          throw const AppFailure(
            FailureCode.mediaUnavailable,
            'Snippet playback is unavailable on this platform.',
          );
        }
        unawaited(_play(id, offset, generation));
      } catch (error) {
        _failed(error, generation);
      }
    });
    await _commands;
  }

  Future<void> _play(String id, Duration offset, int generation) async {
    try {
      await port!.playSnippet(jobId, id, offset, (event) {
        if (_disposed || generation != _generation) return;
        assetId = event.assetId;
        position = event.position;
        duration = event.duration;
        loading = false;
        playing = true;
        _notify();
      });
      if (!_disposed && generation == _generation) {
        loading = playing = false;
        position = duration;
        _notify();
      }
    } catch (error) {
      _failed(error, generation);
    }
  }

  void _failed(Object error, int generation) {
    if (_disposed || generation != _generation) return;
    loading = playing = false;
    failure = error is AppFailure
        ? error
        : const AppFailure(
            FailureCode.mediaUnavailable,
            'Playback stopped safely. Check local audio output and retry.',
          );
    _notify();
  }

  Future<void> pause({bool clear = false}) async {
    ++_generation;
    loading = playing = false;
    if (clear) {
      trackId = assetId = null;
      position = duration = Duration.zero;
    }
    _notify();
    _commands = _commands.then((_) async {
      try {
        await port?.stopSnippet();
      } catch (error) {
        if (!_disposed) {
          failure = error is AppFailure
              ? error
              : const AppFailure(
                  FailureCode.mediaUnavailable,
                  'Audio output could not be stopped safely.',
                );
          _notify();
        }
      }
    });
    await _commands;
  }

  Future<void> seek(Duration target) async {
    if (_disposed || trackId == null || duration <= Duration.zero) return;
    final bounded = Duration(
      microseconds: target.inMicroseconds.clamp(0, duration.inMicroseconds),
    );
    if (bounded >= duration) {
      await pause();
      position = duration;
      _notify();
      return;
    }
    if (playing || loading) {
      await _start(trackId!, bounded);
    } else {
      position = bounded;
      _notify();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    unawaited(pause(clear: true));
    super.dispose();
  }
}
