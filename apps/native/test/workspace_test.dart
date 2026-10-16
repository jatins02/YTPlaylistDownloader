import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';

void main() {
  late Directory temporary;
  late PrivateWorkspace workspace;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('ytpd-path-test-');
    workspace = await PrivateWorkspace.acquire(
      Directory('${temporary.path}/private'),
    );
  });
  tearDown(() async {
    await workspace.close();
    await temporary.delete(recursive: true);
  });

  test('database paths reject directories and special files before opening storage', () async {
    await Directory(workspace.databasePath).create();
    await expectLater(
      workspace.verifyDatabasePaths(),
      throwsA(isA<AppFailure>()),
    );
    await Directory(workspace.databasePath).delete();
    if (Platform.isLinux) {
      expect(
        (await Process.run('mkfifo', [workspace.databasePath])).exitCode,
        0,
      );
      await expectLater(
        workspace.verifyDatabasePaths(),
        throwsA(isA<AppFailure>()),
      );
    }
  });

  test(
    'bundled tool paths reject directories with a structured path error',
    () async {
      await Directory('${workspace.root.path}/metadata_tools.py').create();
      await expectLater(
        workspace.installTool('metadata_tools.py', Uint8List.fromList([1])),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.invalidPath,
          ),
        ),
      );
    },
  );

  test('jobs isolate immutable asset paths without using song names', () async {
    final first = const Uuid().v4();
    final second = const Uuid().v4();
    final asset = const Uuid().v4();
    final firstFile = await workspace.reserveAsset(
      first,
      asset,
      AssetKind.audio,
    );
    final secondFile = await workspace.reserveAsset(
      second,
      asset,
      AssetKind.audio,
    );
    expect(firstFile.path, isNot(secondFile.path));
    await firstFile.writeAsString('audio A');
    await secondFile.writeAsString('audio B');
    expect(await firstFile.readAsString(), 'audio A');
    expect(
      () => workspace.reserveAsset(first, asset, AssetKind.audio),
      throwsA(isA<AppFailure>()),
    );
    expect(await firstFile.readAsString(), 'audio A');
  });

  test('path traversal cannot create a job outside private storage', () async {
    expect(
      () => workspace.ensureJob('../../escape'),
      throwsA(isA<AppFailure>()),
    );
    expect(await Directory('${temporary.path}/escape').exists(), isFalse);
  });

  test(
    'duplicate workspace open fails without dropping the active guard',
    () async {
      expect(
        () => PrivateWorkspace.acquire(workspace.root),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => PrivateWorkspace.acquire(workspace.root),
        throwsA(isA<AppFailure>()),
      );
      await workspace.ensureJob(const Uuid().v4());
    },
  );

  test(
    'closed sessions can be reopened without a stale in-process guard',
    () async {
      await workspace.close();
      workspace = await PrivateWorkspace.acquire(workspace.root);
      await workspace.ensureJob(const Uuid().v4());
    },
  );

  test(
    'job and database symlinks are rejected instead of accessing other files',
    () async {
      final external = await Directory('${temporary.path}/external').create();
      final job = const Uuid().v4();
      await Link('${workspace.root.path}/jobs/$job').create(external.path);
      expect(() => workspace.ensureJob(job), throwsA(isA<AppFailure>()));
      expect(await external.list().isEmpty, isTrue);
      await Link(workspace.databasePath)
          .create('${external.path}/external.sqlite');
      expect(workspace.verifyDatabasePaths, throwsA(isA<AppFailure>()));
    },
    skip: Platform.isWindows
        ? 'Creating test symlinks needs Windows developer/admin privileges.'
        : false,
  );
}
