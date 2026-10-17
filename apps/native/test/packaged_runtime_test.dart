import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';

void main() {
  late Directory root;
  late File manifest;
  late Map<String, dynamic> tools;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ytpd-runtime-test-');
    manifest = File(p.join(root.path, 'runtime', 'media-runtime.json'));
    await manifest.parent.create();
    tools = {};
    for (final name in ['python', 'ffmpeg', 'ffprobe', 'deno']) {
      final bytes = utf8.encode('fictional $name executable');
      final file = File(p.join(manifest.parent.path, 'bin', name));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      tools[name] = {
        'path': 'bin/$name',
        'bytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      };
    }
    await manifest.writeAsString(jsonEncode({'format': 1, 'tools': tools}));
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'packaged tool paths relocate without losing immutable integrity',
    () async {
      final moved = await manifest.parent.rename(
        p.join(root.path, 'moved runtime'),
      );
      final loaded = await DesktopTools.load(
        File(p.join(moved.path, 'media-runtime.json')),
        'private guard',
      );
      // Windows may expand its temporary directory's DOS short-name alias.
      final canonical = await moved.resolveSymbolicLinks();
      expect(loaded.ffmpeg, p.join(canonical, 'bin', 'ffmpeg'));
      expect(loaded.python, p.join(canonical, 'bin', 'python'));
      expect(loaded.guard, 'private guard');
    },
  );

  test(
    'same-size corruption and missing tools never enable a package',
    () async {
      final file = File(p.join(manifest.parent.path, 'bin/ffmpeg'));
      final bytes = await file.readAsBytes();
      bytes[0] ^= 1;
      await file.writeAsBytes(bytes);
      await expectLater(
        DesktopTools.load(manifest, 'guard'),
        throwsA(isA<AppFailure>()),
      );
      await file.delete();
      await expectLater(
        DesktopTools.load(manifest, 'guard'),
        throwsA(isA<AppFailure>()),
      );
    },
  );

  test(
    'package paths reject traversal, absolute paths and malformed records',
    () async {
      for (final path in [
        '../outside',
        '/bin/sh',
        'bin//ffmpeg',
        r'bin\ffmpeg',
        'bin/./ffmpeg',
        'C:tool',
      ]) {
        tools['ffmpeg']['path'] = path;
        await manifest.writeAsString(jsonEncode({'format': 1, 'tools': tools}));
        await expectLater(
          DesktopTools.load(manifest, 'guard'),
          throwsA(isA<AppFailure>()),
        );
      }
      tools['ffmpeg']['path'] = 'bin/ffmpeg';
      tools['ffmpeg']['bytes'] = 0;
      await manifest.writeAsString(jsonEncode({'format': 1, 'tools': tools}));
      await expectLater(
        DesktopTools.load(manifest, 'guard'),
        throwsA(isA<AppFailure>()),
      );
      tools.remove('deno');
      await manifest.writeAsString(jsonEncode({'format': 1, 'tools': tools}));
      await expectLater(
        DesktopTools.load(manifest, 'guard'),
        throwsA(isA<AppFailure>()),
      );
    },
  );

  test(
    'manifest discovery preserves explicit and workspace override precedence',
    () async {
      final workspace = await Directory(p.join(root.path, 'workspace'))
          .create();
      final explicit = File(p.join(root.path, 'missing-explicit.json'));
      expect(
        (await DesktopTools.findManifest(
          explicit: explicit,
          workspace: workspace,
        )).path,
        explicit.path,
      );
      final environment = p.join(root.path, 'missing-environment.json');
      expect(
        (await DesktopTools.findManifest(
          workspace: workspace,
          environmentPath: environment,
        )).path,
        environment,
      );
      final local = File(p.join(workspace.path, 'media-runtime.json'));
      await local.writeAsString('invalid override');
      expect(
        (await DesktopTools.findManifest(
          workspace: workspace,
          executable: p.join(root.path, 'app'),
        )).path,
        local.path,
      );
      await local.delete();
      expect(
        (await DesktopTools.findManifest(
          workspace: workspace,
          executable: p.join(root.path, 'app'),
        )).path,
        manifest.path,
      );
    },
  );

  test('legacy development manifest remains supported', () async {
    await manifest.writeAsString(
      jsonEncode({
        for (final name in tools.keys)
          name: p.join(manifest.parent.path, 'bin', name),
      }),
    );
    final loaded = await DesktopTools.load(manifest, 'guard');
    expect(loaded.deno, p.join(manifest.parent.path, 'bin', 'deno'));
  });

  test(
    'packaged tools reject file and ancestor symlinks',
    () async {
      final file = File(p.join(manifest.parent.path, 'bin/ffmpeg'));
      final outside = File(p.join(root.path, 'outside'));
      await file.rename(outside.path);
      await Link(file.path).create(outside.path);
      await expectLater(
        DesktopTools.load(manifest, 'guard'),
        throwsA(isA<AppFailure>()),
      );
      await Link(file.path).delete();
      await outside.rename(file.path);
      final bin = Directory(p.join(manifest.parent.path, 'bin'));
      final moved = await bin.rename(p.join(root.path, 'outside-bin'));
      await Link(bin.path).create(moved.path);
      await expectLater(
        DesktopTools.load(manifest, 'guard'),
        throwsA(isA<AppFailure>()),
      );
    },
    skip: Platform.isWindows
        ? 'Requires Windows symlink privilege; Linux exercises this boundary.'
        : false,
  );

  final runtimePath = Platform.environment['STAGE3_TEST_RUNTIME'];
  if (Platform.isLinux && runtimePath != null) {
    test(
      'supervised isolated Python never writes beside an installed module',
      () async {
        final loaded = await DesktopTools.load(
          File(runtimePath),
          File('assets/process_guard.py').absolute.path,
        );
        final module = File(p.join(root.path, 'fictional_package_module.py'));
        await module.writeAsString('value = 42\n');
        final scope = loaded.scope();
        try {
          final output = await scope.run(loaded.python, [
            '-I',
            '-c',
            'import sys;sys.path.insert(0,sys.argv[1]);import fictional_package_module;'
                'assert fictional_package_module.value == 42;print(sys.dont_write_bytecode)',
            root.path,
          ], directory: root);
          expect(output.trim(), 'True');
          expect(
            await Directory(p.join(root.path, '__pycache__')).exists(),
            isFalse,
          );
        } finally {
          scope.cancel();
        }
      },
    );
  }
}
