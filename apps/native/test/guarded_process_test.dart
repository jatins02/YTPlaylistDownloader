import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/platform/guarded_process.dart';

void main() {
  if (!Platform.isLinux) {
    return; // This is a Linux process primitive, not a phone/Windows proof.
  }
  late Directory directory;
  late ProcessScope scope;
  final python = Platform.environment['STAGE3_TEST_PYTHON'] ?? 'python3';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ytpd-guard-test-');
    scope = ProcessScope(
      python: python,
      guard: File('assets/process_guard.py').absolute.path,
    );
  });
  tearDown(() async {
    scope.cancel();
    await directory.delete(recursive: true);
  });

  test(
    'source tools receive an allowlisted environment without inherited secrets',
    () async {
      final output = await scope.run(python, [
        '-I',
        '-c',
        'import os;print("GROQ_API_KEY" in os.environ, "STAGE3_TEST_SECRET" in os.environ, "PATH" in os.environ)',
      ], directory: directory);
      expect(output.trim(), 'False False True');
    },
  );
  test(
    'fast final stdout overflow is stopped even after the process exits',
    () async {
      await expectLater(
        scope.run(
          python,
          ['-I', '-c', 'print("a"*100000)'],
          directory: directory,
          maxOutputBytes: 1024,
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.limitExceeded,
          ),
        ),
      );
    },
  );
  test(
    'timeouts stop a guarded process without exposing raw diagnostics',
    () async {
      await expectLater(
        scope.run(
          python,
          ['-I', '-c', 'import time;time.sleep(30)'],
          directory: directory,
          timeout: const Duration(milliseconds: 150),
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.processTimeout,
          ),
        ),
      );
    },
  );
  test('OS-enforced file size cap cannot leave an oversized file', () async {
    final limited = ProcessScope(
      python: python,
      guard: File('assets/process_guard.py').absolute.path,
      maxFileBytes: 1024,
    );
    try {
      await expectLater(
        limited.run(python, [
          '-I',
          '-c',
          'open("large.bin","wb").write(b"a"*100000)',
        ], directory: directory),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.limitExceeded,
          ),
        ),
      );
      expect(
        await File('${directory.path}/large.bin').length(),
        lessThanOrEqualTo(1024),
      );
    } finally {
      limited.cancel();
    }
  });
  test(
    'cancellation stops the whole tool process group and retains no busy task',
    () async {
      final task = scope.run(python, [
        '-I',
        '-c',
        'import subprocess,sys,time;subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"]);print("started",flush=True);time.sleep(30)',
      ], directory: directory);
      final expected = expectLater(
        task,
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.operationCancelled,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      scope.cancel();
      await expected.timeout(const Duration(seconds: 4));
    },
  );
}
