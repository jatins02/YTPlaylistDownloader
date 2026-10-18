import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/platform/native_codec.dart';

void main() {
  if (!Platform.isLinux) return;
  final manifest = Platform.environment['STAGE3_TEST_RUNTIME'];
  if (manifest != null) {
    test('standalone audio containers verify but local playlists cannot substitute another file', () async {
      final root = await Directory.systemTemp.createTemp(
        'ytpd-codec-boundary-',
      );
      final tools = await DesktopTools.load(
        File(manifest),
        File('assets/process_guard.py').absolute.path,
      );
      final scope = tools.scope();
      final codec = NativeCodec(tools, const PipelineLimits());
      try {
        for (final format in [
          ('mp3', 'libmp3lame'),
          ('m4a', 'aac'),
          ('webm', 'libopus'),
        ]) {
          final audio = File('${root.path}/peer.${format.$1}');
          await scope.run(tools.ffmpeg, [
            '-nostdin',
            '-v',
            'error',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:duration=2',
            '-c:a',
            format.$2,
            audio.path,
          ], directory: root);
          final result = await codec.verify(
            audio,
            scope,
            root,
            () async {},
            expected: 2,
          );
          expect(result.durationSeconds, closeTo(2, 0.1));
        }
        final playlist = await File('${root.path}/source.m3u8').writeAsString(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:2,\n${File('${root.path}/peer.mp3').uri}\n#EXT-X-ENDLIST\n',
        );
        await expectLater(
          codec.verify(playlist, scope, root, () async {}),
          throwsA(
            isA<AppFailure>().having(
              (e) => e.code,
              'code',
              FailureCode.audioInvalid,
            ),
          ),
        );
        await expectLater(
          codec.convert(playlist, scope, root, () async {}),
          throwsA(isA<AppFailure>()),
        );
        expect(await File('${root.path}/audio.mp3').exists(), isFalse);
      } finally {
        scope.cancel();
        await root.delete(recursive: true);
      }
    });
  }
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
