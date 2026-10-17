import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// Development-only, sampled Linux measurements of this process and descendants.
/// Summed RSS double-counts shared pages; short-lived workers may escape sampling.
final class LinuxQaMetrics {
  LinuxQaMetrics(this.privateRoot, this.destinationRoot);
  final Directory privateRoot, destinationRoot;
  final _clock = Stopwatch();
  final _ticks = <String, int>{};
  Timer? _timer;
  Future<void>? _pending;
  int _cpu = 0, _hz = 0, _rss = 0, _private = 0, _destination = 0, _samples = 0;
  Object? _error;

  Future<void> start() async {
    if (!Platform.isLinux) throw UnsupportedError('Linux QA only');
    final result = await Process.run('getconf', ['CLK_TCK']);
    _hz = int.parse((result.stdout as String).trim());
    if (result.exitCode != 0 || _hz <= 0) {
      throw StateError('CPU clock unavailable');
    }
    await _sample(baseline: true);
    _clock.start();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_pending != null) return;
      _pending = _sample()
          .catchError((Object error) {
            _error = error;
          })
          .whenComplete(() => _pending = null);
    });
  }

  Future<Map<String, Object>> finish() async {
    _timer?.cancel();
    await _pending;
    await _sample();
    _clock.stop();
    if (_error != null) throw StateError('Resource sampling failed');
    return {
      'elapsed_seconds': _clock.elapsedMilliseconds / 1000,
      'sampling_interval_ms': 100,
      'samples': _samples,
      'peak_summed_rss_bytes': _rss,
      'observed_cpu_seconds_lower_bound': _cpu / _hz,
      'peak_private_bytes': _private,
      'peak_destination_bytes': _destination,
    };
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _pending;
    _clock.stop();
  }

  Future<void> _sample({bool baseline = false}) async {
    var rss = 0;
    final queue = [pid], visited = <int>{};
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!visited.add(current)) continue;
      try {
        final base = '/proc/$current';
        final stat = await File('$base/stat').readAsString();
        final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
        final identity = '$current:${fields[19]}';
        final ticks = int.parse(fields[11]) + int.parse(fields[12]);
        _cpu += baseline ? 0 : math.max(0, ticks - (_ticks[identity] ?? 0));
        _ticks[identity] = ticks;
        final status = await File('$base/status').readAsString();
        final kb = RegExp(
          r'^VmRSS:\s+(\d+) kB',
          multiLine: true,
        ).firstMatch(status);
        rss += kb == null ? 0 : int.parse(kb[1]!) * 1024;
        // Linux attributes children to the spawning thread. Dart can start a
        // codec from an I/O thread, so inspecting only task/<pid> misses it.
        await for (final task in Directory('$base/task').list()) {
          try {
            final children = await File('${task.path}/children').readAsString();
            queue.addAll(
              children
                  .trim()
                  .split(RegExp(r'\s+'))
                  .where((v) => v.isNotEmpty)
                  .map(int.parse),
            );
          } on FileSystemException {
            // A thread may finish while the process remains alive.
          }
        }
      } on FileSystemException {
        // A supervised child can exit between /proc reads.
      }
    }
    _rss = math.max(_rss, rss);
    _private = math.max(_private, await _bytes(privateRoot));
    _destination = math.max(_destination, await _bytes(destinationRoot));
    _samples++;
  }

  Future<int> _bytes(Directory root) async {
    var total = 0;
    if (!await root.exists()) return total;
    try {
      await for (final entry in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is! File) continue;
        try {
          total += await entry.length();
        } on FileSystemException {
          // Test-owned scratch may be retired during a sample.
        }
      }
    } on FileSystemException {
      // Retiring a work directory can interrupt its listing, too. As with CPU
      // sampling, observed storage peaks are lower bounds, not a quota proof.
    }
    return total;
  }
}
