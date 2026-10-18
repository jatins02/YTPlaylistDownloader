import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../domain/failure.dart';
import '../domain/media_models.dart';
import '../domain/playlist_url.dart';
import 'desktop_tools.dart';
import 'guarded_process.dart';

abstract interface class PlaylistSource {
  Future<List<SourceEntry>> enumerate(
    PlaylistUrl playlist,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  );
  Future<File> download(
    String videoId,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  );
}

final class YoutubePlaylistSource implements PlaylistSource {
  const YoutubePlaylistSource(this.tools);
  final DesktopTools tools;

  @override
  Future<List<SourceEntry>> enumerate(
    PlaylistUrl playlist,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) async {
    final output = await scope.run(
      tools.python,
      [
        ...tools.sourceArguments,
        '--flat-playlist',
        '--dump-single-json',
        '--ignore-errors',
        '--playlist-end',
        '${limits.maxEntries + 1}',
        playlist.canonical,
      ],
      directory: work,
      timeout: const Duration(seconds: 120),
      monitor: monitor,
    );
    return Isolate.run(() => parsePlaylistListing(output, limits));
  }

  @override
  Future<File> download(
    String videoId,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
      throw const AppFailure(
        FailureCode.invalidPlaylist,
        'Invalid source video identity.',
      );
    }
    await scope.run(
      tools.python,
      [
        ...tools.sourceArguments,
        '--no-playlist',
        '--no-part',
        '--no-mtime',
        '--no-progress',
        '--max-filesize',
        '${limits.maxFileBytes}',
        '--match-filter',
        '!is_live & duration <= ${limits.maxSeconds}',
        '-f',
        'bestaudio/best',
        '-o',
        '${work.path}/source.%(ext)s',
        'https://www.youtube.com/watch?v=$videoId',
      ],
      directory: work,
      timeout: limits.operationTimeout,
      monitor: monitor,
    );
    final files = await work
        .list(followLinks: false)
        .where(
          (entity) =>
              entity is File &&
              entity.uri.pathSegments.last.startsWith('source.') &&
              !entity.path.endsWith('.part'),
        )
        .toList();
    if (files.length != 1) {
      throw const AppFailure(
        FailureCode.sourceUnavailable,
        'The source was unavailable or rejected by a duration/byte limit.',
        retryable: true,
      );
    }
    return files.single as File;
  }
}

List<SourceEntry> parsePlaylistListing(String output, PipelineLimits limits) {
  try {
    final data = jsonDecode(output) as Map<String, dynamic>;
    final entries = data['entries'] as List<dynamic>;
    final count = data['playlist_count'];
    if (count != null && (count is! int || count < 0)) {
      throw const FormatException();
    }
    if (entries.length > limits.maxEntries ||
        (count is num && count > limits.maxEntries)) {
      throw const AppFailure(
        FailureCode.limitExceeded,
        'This playlist exceeds the entry limit. Nothing was truncated.',
      );
    }
    final result = <SourceEntry>[];
    for (var index = 0; index < entries.length; index++) {
      final raw = entries[index];
      if (raw == null) {
        result.add(
          SourceEntry(
            position: result.length + 1,
            title: 'Unavailable playlist entry',
            failure: FailureCode.sourceUnavailable,
          ),
        );
        continue;
      }
      final entry = raw as Map<String, dynamic>;
      final reportedPosition = entry['playlist_index'];
      if (reportedPosition != null &&
          (reportedPosition is! int ||
              reportedPosition <= result.length ||
              reportedPosition > limits.maxEntries)) {
        throw const FormatException();
      }
      final position = reportedPosition as int? ?? result.length + 1;
      while (result.length < position - 1) {
        result.add(
          SourceEntry(
            position: result.length + 1,
            title: 'Unavailable playlist entry; source did not return it',
            failure: FailureCode.sourceUnavailable,
          ),
        );
      }
      final rawId = entry['id'];
      final id =
          rawId is String && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(rawId)
          ? rawId
          : null;
      final title = entry['title'];
      if (title != null &&
          (title is! String ||
              title.length > 500 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(title))) {
        throw const FormatException();
      }
      final uploader = entry['uploader'];
      if (uploader != null &&
          (uploader is! String ||
              uploader.length > 200 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(uploader))) {
        throw const FormatException();
      }
      final duration = entry['duration'];
      if (duration != null &&
          (duration is! num || !duration.isFinite || duration <= 0)) {
        throw const FormatException();
      }
      final live = entry['live_status'];
      final unavailable =
          id == null ||
          [
            'private',
            'premium_only',
            'subscriber_only',
            'needs_auth',
          ].contains(entry['availability']);
      final liveUnsupported = ['is_live', 'is_upcoming'].contains(live);
      final tooLong = duration is num && duration > limits.maxSeconds;
      result.add(
        SourceEntry(
          position: position,
          videoId: id,
          title: title is String && title.trim().isNotEmpty
              ? title.trim()
              : 'Unavailable source',
          uploader: uploader as String?,
          durationSeconds: (duration as num?)?.toDouble(),
          failure: unavailable
              ? FailureCode.sourceUnavailable
              : liveUnsupported
              ? FailureCode.liveUnsupported
              : tooLong
              ? FailureCode.limitExceeded
              : null,
        ),
      );
    }
    if (count is int) {
      while (result.length < count) {
        result.add(
          SourceEntry(
            position: result.length + 1,
            title: 'Unavailable playlist entry; source position unreported',
            failure: FailureCode.sourceUnavailable,
          ),
        );
      }
    }
    if (result.map((e) => e.videoId).whereType<String>().toSet().length >
        limits.maxTracks) {
      throw const AppFailure(
        FailureCode.limitExceeded,
        'This playlist exceeds the unique-track limit. Nothing was truncated.',
      );
    }
    return List.unmodifiable(result);
  } on AppFailure {
    rethrow;
  } catch (_) {
    throw const AppFailure(
      FailureCode.invalidMetadata,
      'The source returned malformed playlist information. Try again later.',
    );
  }
}
