import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/job_repository.dart';
import '../data/media_workspace.dart';
import '../data/pipeline_repository.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import 'desktop_tools.dart';
import 'guarded_process.dart';
import 'native_codec.dart';
import 'snippet_port.dart';

/// Proven Linux adapter: the pinned FFmpeg decodes only a verified private
/// preview to a local PulseAudio/PipeWire Unix socket. No remote audio sink.
final class NativeSnippetPlayer implements SnippetPort {
  NativeSnippetPlayer(
    this.jobs,
    this.files,
    this.tools,
    this.codec, {
    String? socket,
  }) : socket = socket ?? defaultSocket();
  final JobRepository jobs;
  final MediaWorkspace files;
  final DesktopTools tools;
  final NativeCodec codec;
  final String? socket;
  ProcessScope? _scope;
  Future<void>? _task;
  String? jobId;
  bool _closed = false;
  bool _verifiedOutput = false;

  Future<void> verifyOutput() async {
    final scope = tools.scope();
    try {
      final output = await scope.run(
        tools.ffmpeg,
        ['-hide_banner', '-h', 'muxer=pulse'],
        directory: files.workspace.root,
        timeout: const Duration(seconds: 10),
        maxOutputBytes: 8192,
      );
      if (!output.contains('Pulse audio output')) {
        throw const AppFailure(
          FailureCode.toolUnavailable,
          'The pinned media runtime has no local audio output adapter.',
        );
      }
      _verifiedOutput = true;
    } finally {
      scope.cancel();
    }
  }

  static String? defaultSocket() {
    final explicit = Platform.environment['YTPD_AUDIO_SOCKET'];
    final runtime = Platform.environment['XDG_RUNTIME_DIR'];
    return explicit ??
        (runtime == null ? null : p.join(runtime, 'pulse', 'native'));
  }

  Future<bool> available() async {
    if (_closed ||
        !_verifiedOutput ||
        !Platform.isLinux ||
        socket == null ||
        !p.isAbsolute(socket!) ||
        socket!.length > 4096 ||
        socket!.contains('\x00')) {
      return false;
    }
    try {
      return await FileSystemEntity.type(socket!, followLinks: false) ==
          FileSystemEntityType.unixDomainSock;
    } on FileSystemException {
      // An inaccessible audio socket must not disable acquisition or editing.
      return false;
    }
  }

  @override
  Future<void> playSnippet(
    String jobId,
    String trackId,
    Duration position,
    void Function(SnippetProgress) progress,
  ) {
    if (_closed || _task != null) {
      return Future.error(
        const AppFailure(
          FailureCode.conflict,
          'Stop the current snippet before starting another.',
        ),
      );
    }
    final scope = tools.scope();
    this.jobId = jobId;
    _scope = scope;
    return _task = _play(jobId, trackId, position, progress, scope)
        .whenComplete(() {
          this.jobId = null;
          _scope = null;
          _task = null;
        });
  }

  Future<void> _play(
    String jobId,
    String trackId,
    Duration position,
    void Function(SnippetProgress) progress,
    ProcessScope scope,
  ) async {
    Directory? work;
    try {
      if (!await available()) {
        throw const AppFailure(
          FailureCode.mediaUnavailable,
          'Local audio output is unavailable. Start your desktop audio service and retry.',
        );
      }
      final job = await jobs.getJob(jobId),
          track = await jobs.getTrack(trackId);
      if (job.phase != JobPhase.reviewReady ||
          track.jobId != jobId ||
          track.phase != TrackPhase.ready) {
        throw const AppFailure(
          FailureCode.audioInvalid,
          'This track has no ready snippet. Prepare or retry its audio first.',
        );
      }
      final repository = PipelineRepository(jobs);
      final assets = await repository.assets(jobId, trackId: trackId);
      final previews = assets
              .where((a) => a.kind == AssetKind.preview)
              .toList(),
          audio = assets.where((a) => a.kind == AssetKind.audio).toList();
      if (previews.length != 1 ||
          audio.length != 1 ||
          !await files.matches(previews.single)) {
        throw const AppFailure(
          FailureCode.audioInvalid,
          'The saved snippet changed or expired. Retry audio processing.',
        );
      }
      final preview = previews.single;
      work = await files.work(jobId, const Uuid().v4());
      final file = await files.file(preview);
      final probe = await codec.verify(
        file,
        scope,
        work,
        () => files.checkBudget(jobId),
        mp3: true,
        preview: true,
        expected: track.durationSeconds == null
            ? null
            : NativeCodec.snippetSeconds(track.durationSeconds!),
      );
      final duration = Duration(
        microseconds:
            (probe.durationSeconds.clamp(0, 30) *
                    Duration.microsecondsPerSecond)
                .round(),
      );
      if (position.isNegative || position >= duration) {
        throw const AppFailure(
          FailureCode.invalidMetadata,
          'Choose a position inside the snippet.',
        );
      }
      final current = await repository.assets(jobId, trackId: trackId);
      if (!current.any(
            (a) => a.id == preview.id && a.kind == AssetKind.preview,
          ) ||
          !current.any(
            (a) => a.id == audio.single.id && a.kind == AssetKind.audio,
          ) ||
          !await files.matches(preview)) {
        throw const AppFailure(
          FailureCode.audioInvalid,
          'The snippet was replaced before playback. Retry with current audio.',
        );
      }
      scope.check();
      var buffered = '';
      final offset = position.inMicroseconds / Duration.microsecondsPerSecond;
      await scope.run(
        tools.ffmpeg,
        [
          '-nostdin',
          '-hide_banner',
          '-loglevel',
          'error',
          '-xerror',
          '-progress',
          'pipe:1',
          '-stats_period',
          '0.1',
          '-readrate',
          '1',
          '-ss',
          '$offset',
          '-i',
          file.path,
          '-t',
          '${(duration - position).inMicroseconds / Duration.microsecondsPerSecond}',
          '-map',
          '0:a:0',
          '-vn',
          '-c:a',
          'pcm_s16le',
          '-ar',
          '44100',
          '-ac',
          '2',
          '-f',
          'pulse',
          '-server',
          'unix:$socket',
          '-name',
          'YTPlaylistDownloader',
          '-stream_name',
          'Snippet',
          '-buffer_duration',
          '100',
          'default',
        ],
        directory: work,
        timeout: duration - position + const Duration(seconds: 10),
        maxOutputBytes: 128 * 1024,
        localAudio: true,
        requireCleanStderr: true,
        onOutput: (bytes) {
          buffered += utf8.decode(bytes, allowMalformed: true);
          final lines = buffered.split('\n');
          buffered = lines.removeLast();
          for (final line in lines) {
            if (!line.startsWith('out_time_us=')) continue;
            final microseconds = int.tryParse(
              line.substring('out_time_us='.length).trim(),
            );
            if (microseconds != null) {
              progress(
                SnippetProgress(
                  preview.id,
                  Duration(
                    microseconds: (position.inMicroseconds + microseconds)
                        .clamp(0, duration.inMicroseconds),
                  ),
                  duration,
                ),
              );
            }
          }
        },
      );
    } on AppFailure catch (error) {
      if ([
        FailureCode.operationCancelled,
        FailureCode.audioInvalid,
        FailureCode.conflict,
        FailureCode.invalidMetadata,
      ].contains(error.code)) {
        rethrow;
      }
      throw const AppFailure(
        FailureCode.mediaUnavailable,
        'Snippet playback could not finish. Check local audio output and retry.',
      );
    } catch (_) {
      throw const AppFailure(
        FailureCode.mediaUnavailable,
        'The private snippet could not be played. Retry after checking local audio and storage.',
      );
    } finally {
      scope.cancel();
      try {
        if (work != null && await work.exists()) {
          await work.delete(recursive: true);
        }
      } on FileSystemException {
        /* Retry private scratch cleanup at startup. */
      }
    }
  }

  @override
  Future<void> stopSnippet() async {
    _scope?.cancel();
    try {
      await _task;
    } on AppFailure catch (error) {
      if (error.code != FailureCode.operationCancelled) rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    await stopSnippet();
  }
}
