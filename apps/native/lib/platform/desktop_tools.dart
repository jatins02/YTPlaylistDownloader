import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/failure.dart';
import 'guarded_process.dart';

abstract final class MediaToolPins {
  static const python = '3.14.4',
      ytDlp = '2026.8.19',
      ejs = '0.8.0',
      deno = '2.5.4';
  static const ffmpeg = 'n8.1.3-17-gc389840894-20261011';
}

/// Explicit development paths or integrity-checked package-relative tools.
/// Runtime version checks still run before enabling any media capabilities.
final class DesktopTools {
  const DesktopTools({
    required this.python,
    required this.ffmpeg,
    required this.ffprobe,
    required this.deno,
    required this.guard,
  });
  final String python, ffmpeg, ffprobe, deno, guard;

  /// An explicit override never silently falls back to another runtime.
  static Future<File> findManifest({
    File? explicit,
    required Directory workspace,
    String? environmentPath,
    String? executable,
  }) async {
    if (explicit != null) return explicit;
    final configured =
        environmentPath ?? Platform.environment['YTPD_MEDIA_RUNTIME'];
    if (configured != null) return File(configured);
    final local = File(p.join(workspace.path, 'media-runtime.json'));
    if (await FileSystemEntity.type(local.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return local;
    }
    return File(
      p.join(
        p.dirname(executable ?? Platform.resolvedExecutable),
        'runtime',
        'media-runtime.json',
      ),
    );
  }

  static Future<DesktopTools> load(File manifest, String guard) async {
    try {
      if (p.extension(manifest.path).toLowerCase() != '.json' ||
          await FileSystemEntity.type(manifest.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const FormatException();
      }
      if (await manifest.length() > 8192) throw const FormatException();
      final data =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      final Map<String, String> paths;
      if (data['format'] == 1) {
        paths = await Isolate.run(() => _packagedPaths(manifest.path, data));
      } else {
        if (data.keys.toSet().difference({
              'python',
              'ffmpeg',
              'ffprobe',
              'deno',
            }).isNotEmpty ||
            data.length != 4) {
          throw const FormatException();
        }
        paths = <String, String>{};
        for (final name in ['python', 'ffmpeg', 'ffprobe', 'deno']) {
          final value = data[name];
          if (value is! String ||
              !p.isAbsolute(value) ||
              value.length > 4096 ||
              value.contains('\u0000') ||
              !await File(value).exists()) {
            throw const FormatException();
          }
          paths[name] = value;
        }
      }
      return DesktopTools(
        python: paths['python']!,
        ffmpeg: paths['ffmpeg']!,
        ffprobe: paths['ffprobe']!,
        deno: paths['deno']!,
        guard: guard,
      );
    } catch (_) {
      throw const AppFailure(
        FailureCode.toolUnavailable,
        'Configure a valid local media runtime manifest and reopen the app.',
      );
    }
  }

  static Future<Map<String, String>> _packagedPaths(
    String manifestPath,
    Map<String, dynamic> data,
  ) async {
    if (data.length != 2 || data['tools'] is! Map<String, dynamic>) {
      throw const FormatException();
    }
    final tools = data['tools'] as Map<String, dynamic>;
    if (tools.length != 4 ||
        !tools.keys.toSet().containsAll([
          'python',
          'ffmpeg',
          'ffprobe',
          'deno',
        ])) {
      throw const FormatException();
    }
    final root = await File(manifestPath).parent.resolveSymbolicLinks();
    final result = <String, String>{};
    for (final entry in tools.entries) {
      final record = entry.value;
      if (record is! Map<String, dynamic> ||
          record.length != 3 ||
          record['path'] is! String ||
          record['bytes'] is! int ||
          record['sha256'] is! String) {
        throw const FormatException();
      }
      final relative = record['path'] as String;
      final bytes = record['bytes'] as int;
      final hash = record['sha256'] as String;
      if (relative.isEmpty ||
          relative.length > 512 ||
          relative.contains(RegExp(r'[\\:\x00-\x1f]')) ||
          p.posix.isAbsolute(relative) ||
          relative.split('/').any((v) => v.isEmpty || v == '.' || v == '..') ||
          bytes <= 0 ||
          bytes > 256 * 1024 * 1024 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const FormatException();
      }
      var current = root;
      final parts = relative.split('/');
      for (var i = 0; i < parts.length; i++) {
        current = p.join(current, parts[i]);
        final expected = i == parts.length - 1
            ? FileSystemEntityType.file
            : FileSystemEntityType.directory;
        if (await FileSystemEntity.type(current, followLinks: false) !=
            expected) {
          throw const FormatException();
        }
      }
      final file = File(current);
      if (await file.length() != bytes ||
          (await sha256.bind(file.openRead()).first).toString() != hash) {
        throw const FormatException();
      }
      result[entry.key] = current;
    }
    return result;
  }

  ProcessScope scope({int maxFileBytes = 50 * 1024 * 1024}) =>
      ProcessScope(python: python, guard: guard, maxFileBytes: maxFileBytes);
  List<String> get sourceArguments => [
    '-I',
    '-m',
    'yt_dlp',
    '--ignore-config',
    '--no-config-locations',
    '--no-cache-dir',
    '--no-plugin-dirs',
    '--no-remote-components',
    '--no-js-runtimes',
    '--js-runtimes',
    'deno:$deno',
    '--quiet',
    '--no-warnings',
    '--socket-timeout',
    '15',
    '--retries',
    '1',
    '--extractor-retries',
    '1',
    '--fragment-retries',
    '1',
    '--abort-on-unavailable-fragments',
    '--concurrent-fragments',
    '1',
    '--ffmpeg-location',
    p.dirname(ffmpeg),
  ];

  Future<void> verify(Directory directory) async {
    final scope = this.scope();
    try {
      final metadata = await scope.run(
        python,
        [
          '-I',
          '-c',
          'import sys,importlib.metadata,json;print(json.dumps([sys.version.split()[0],importlib.metadata.version("yt-dlp"),importlib.metadata.version("yt-dlp-ejs")]))',
        ],
        directory: directory,
        timeout: const Duration(seconds: 15),
      );
      if (jsonEncode(jsonDecode(metadata)) !=
          jsonEncode([
            MediaToolPins.python,
            MediaToolPins.ytDlp,
            MediaToolPins.ejs,
          ])) {
        throw const FormatException();
      }
      for (final check in [(ffmpeg, 'ffmpeg'), (ffprobe, 'ffprobe')]) {
        final version = await scope.run(
          check.$1,
          ['-version'],
          directory: directory,
          timeout: const Duration(seconds: 10),
        );
        if (!version.startsWith(
          '${check.$2} version ${MediaToolPins.ffmpeg} ',
        )) {
          throw const FormatException();
        }
      }
      final version = await scope.run(
        deno,
        ['--version'],
        directory: directory,
        timeout: const Duration(seconds: 10),
      );
      if (!version.startsWith('deno ${MediaToolPins.deno} ')) {
        throw const FormatException();
      }
    } catch (_) {
      throw const AppFailure(
        FailureCode.toolUnavailable,
        'The media runtime does not match the recorded versions. Repair the local tools before processing.',
      );
    } finally {
      scope.cancel();
    }
  }
}
