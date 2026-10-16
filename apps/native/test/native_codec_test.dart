import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/platform/native_codec.dart';

void main() {
  if (!Platform.isLinux) return;
  for (final failingTool in ['probe', 'decode']) {
    test('zero-exit $failingTool errors cannot verify audio', () async {
      final root = await Directory.systemTemp.createTemp('ytpd-codec-errors-');
      final python = Platform.environment['STAGE3_TEST_PYTHON'] ?? 'python3';
      final tools = DesktopTools(
        python: python,
        ffmpeg: '${root.path}/decode',
        ffprobe: '${root.path}/probe',
        deno: '',
        guard: File('assets/process_guard.py').absolute.path,
      );
      final scope = tools.scope();
      try {
        for (final name in ['probe', 'decode']) {
          final tool = File('${root.path}/$name');
          await tool.writeAsString(
            '#!/usr/bin/env python3\nimport json,sys\n'
            '${name == failingTool ? 'print("private decoder diagnostic",file=sys.stderr)\n' : ''}'
            '${name == 'probe' ? 'print(json.dumps({"format":{"duration":"2"},"streams":[{"codec_type":"audio","codec_name":"mp3"}]}))\n' : ''}',
          );
          expect(
            (await Process.run('/bin/chmod', ['700', tool.path])).exitCode,
            0,
          );
        }
        final file = await File('${root.path}/audio.mp3')
            .writeAsString('fixture');
        await expectLater(
          NativeCodec(
            tools,
            const PipelineLimits(),
          ).verify(file, scope, root, () async {}, mp3: true),
          throwsA(
            isA<AppFailure>()
                .having((e) => e.code, 'code', FailureCode.audioInvalid)
                .having(
                  (e) => e.message,
                  'message',
                  isNot(contains('private decoder diagnostic')),
                ),
          ),
        );
      } finally {
        scope.cancel();
        await root.delete(recursive: true);
      }
    });
  }
}
