import 'failure.dart';

final class PipelineLimits {
  const PipelineLimits({
    this.maxEntries = 100,
    this.maxTracks = 10,
    this.maxSeconds = 600,
    this.maxFileBytes = 50 * 1024 * 1024,
    this.maxJobBytes = 512 * 1024 * 1024,
    this.maxWorkspaceBytes = 1024 * 1024 * 1024,
    this.freeReserveBytes = 64 * 1024 * 1024,
    this.operationTimeout = const Duration(minutes: 5),
    this.jobTimeout = const Duration(minutes: 20),
  });
  final int maxEntries,
      maxTracks,
      maxSeconds,
      maxFileBytes,
      maxJobBytes,
      maxWorkspaceBytes,
      freeReserveBytes;
  final Duration operationTimeout, jobTimeout;
  void validate() {
    if (maxEntries < 1 ||
        maxEntries > 10000 ||
        maxTracks < 1 ||
        maxTracks > maxEntries ||
        maxSeconds < 1 ||
        maxSeconds > 1200 ||
        maxFileBytes < 1 ||
        maxFileBytes > 512 * 1024 * 1024 ||
        maxJobBytes < maxFileBytes ||
        maxWorkspaceBytes < maxJobBytes ||
        freeReserveBytes < 0 ||
        operationTimeout <= Duration.zero ||
        operationTimeout > const Duration(minutes: 10) ||
        jobTimeout <= Duration.zero ||
        jobTimeout > const Duration(hours: 1)) {
      throw const AppFailure(
        FailureCode.limitExceeded,
        'Invalid media capacity configuration.',
      );
    }
  }
}

/// One original playlist occurrence, including entries with no usable identity.
final class SourceEntry {
  const SourceEntry({
    required this.position,
    required this.title,
    this.videoId,
    this.durationSeconds,
    this.uploader,
    this.failure,
  });
  final int position;
  final String title;
  final String? videoId;
  final double? durationSeconds;
  final String? uploader;
  final FailureCode? failure;
}

final class StoredEntry {
  const StoredEntry({
    required this.position,
    required this.title,
    this.trackId,
    this.failure,
    this.selected = true,
  });
  final int position;
  final String title;
  final String? trackId;
  final FailureCode? failure;
  final bool selected;
}

String mediaFailureMessage(FailureCode? code) => switch (code) {
  FailureCode.expiredMedia => 'Temporary media has expired. Your source titles and edits remain; import a new draft to prepare audio again. Files already saved outside the app are unaffected.',
  FailureCode.limitExceeded => 'A configured track, duration or storage limit was reached. Free space or use a smaller playlist.',
  FailureCode.sourceUnavailable => 'This source could not be downloaded. It may be unavailable or your connection may have failed. Retry when connected.',
  FailureCode.processTimeout => 'The operation timed out. Your verified work is preserved; retry when connected.',
  FailureCode.audioInvalid => 'Audio did not pass verification. Retry this track; playable peers are preserved.',
  FailureCode.operationCancelled =>
    'Processing was stopped. Verified work is preserved.',
  FailureCode.toolUnavailable => 'The pinned media tools are missing or incompatible. Configure the local runtime and reopen the app.',
  FailureCode.storageUnavailable => 'Private storage is unavailable. Check permissions and free space, then retry.',
  FailureCode.liveUnsupported =>
    'Live, upcoming or overlong sources are not supported by this build.',
  _ => 'Processing was interrupted. Resume from verified local work.',
};
