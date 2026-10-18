import 'dart:convert';
import 'dart:io';

import '../domain/failure.dart';
import '../domain/media_models.dart';
import 'desktop_tools.dart';
import 'guarded_process.dart';

final class AudioProbe {
  const AudioProbe(this.durationSeconds, this.codec);
  final double durationSeconds;
  final String codec;
}

final class NativeCodec {
  const NativeCodec(this.tools, this.limits);
  final DesktopTools tools;
  final PipelineLimits limits;
  // Stored source/derivative identities cover one standalone container. Never
  // let an implicit HLS/DASH/concat demuxer fetch other files or network bytes.
  static const localInputOptions = [
    '-protocol_whitelist',
    'file,pipe',
    '-format_whitelist',
    'aac,flac,matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,mp3,ogg,wav,mpegts,mpeg',
  ];
  static double snippetSeconds(double duration) =>
      (duration - (duration > 60 ? 30 : 0)).clamp(0.1, 29.9);

  Future<AudioProbe> verify(
    File file,
    ProcessScope scope,
    Directory work,
    Future<void> Function() monitor, {
    bool mp3 = false,
    double? expected,
    bool preview = false,
  }) async {
    try {
      final output = await scope.run(
        tools.ffprobe,
        [
          '-v',
          'error',
          '-show_entries',
          'format=duration:stream=codec_type,codec_name',
          '-of',
          'json',
          ...localInputOptions,
          file.path,
        ],
        directory: work,
        monitor: monitor,
        timeout: const Duration(seconds: 30),
        requireCleanStderr: true,
      );
      final data = jsonDecode(output) as Map<String, dynamic>;
      final duration = double.parse(
        (data['format'] as Map<String, dynamic>)['duration'] as String,
      );
      final streams = (data['streams'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final audio = streams.where((s) => s['codec_type'] == 'audio').toList();
      if (!duration.isFinite ||
          duration <= 0 ||
          duration > (preview ? 30 : limits.maxSeconds + 1) ||
          audio.length != 1 ||
          (mp3 && audio.single['codec_name'] != 'mp3') ||
          (expected != null && (duration - expected).abs() > 1)) {
        throw const FormatException();
      }
      await scope.run(
        tools.ffmpeg,
        [
          '-nostdin',
          '-hide_banner',
          '-loglevel',
          'error',
          '-xerror',
          ...localInputOptions,
          '-i',
          file.path,
          '-map',
          '0:a:0',
          '-vn',
          '-f',
          'null',
          '-',
        ],
        directory: work,
        timeout: limits.operationTimeout,
        requireCleanStderr: true,
        monitor: monitor,
      );
      return AudioProbe(duration, audio.single['codec_name']! as String);
    } on AppFailure catch (failure) {
      if ([
        FailureCode.operationCancelled,
        FailureCode.limitExceeded,
        FailureCode.processTimeout,
        FailureCode.storageUnavailable,
      ].contains(failure.code)) {
        rethrow;
      }
      throw const AppFailure(
        FailureCode.audioInvalid,
        'The audio could not be fully decoded.',
        retryable: true,
      );
    } catch (_) {
      throw const AppFailure(
        FailureCode.audioInvalid,
        'The audio duration or format is invalid.',
        retryable: true,
      );
    }
  }

  Future<File> convert(
    File source,
    ProcessScope scope,
    Directory work,
    Future<void> Function() monitor,
  ) async {
    final target = File('${work.path}/audio.mp3');
    await scope.run(
      tools.ffmpeg,
      [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-xerror',
        '-n',
        ...localInputOptions,
        '-i',
        source.path,
        '-map',
        '0:a:0',
        '-vn',
        '-map_metadata',
        '-1',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '320k',
        target.path,
      ],
      directory: work,
      timeout: limits.operationTimeout,
      requireCleanStderr: true,
      monitor: monitor,
    );
    return target;
  }

  Future<File> snippet(
    File audio,
    double duration,
    ProcessScope scope,
    Directory work,
    Future<void> Function() monitor,
  ) async {
    final start = duration > 60 ? 30 : 0;
    // Leave room for MP3 frame padding while keeping the actual file <= 30 s.
    final seconds = snippetSeconds(duration);
    final target = File('${work.path}/preview.mp3');
    await scope.run(
      tools.ffmpeg,
      [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-xerror',
        '-n',
        '-ss',
        '$start',
        ...localInputOptions,
        '-i',
        audio.path,
        '-t',
        '$seconds',
        '-map',
        '0:a:0',
        '-vn',
        '-map_metadata',
        '-1',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '192k',
        target.path,
      ],
      directory: work,
      timeout: limits.operationTimeout,
      requireCleanStderr: true,
      monitor: monitor,
    );
    return target;
  }
}
