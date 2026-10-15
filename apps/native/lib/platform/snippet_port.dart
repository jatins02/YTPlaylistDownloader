import 'dart:typed_data';

import '../domain/models.dart';
import '../domain/review.dart';

final class SnippetProgress {
  const SnippetProgress(this.assetId, this.position, this.duration);
  final String assetId;
  final Duration position, duration;
}

abstract interface class SnippetPort {
  /// Completes only when the native player has stopped and released output.
  Future<void> playSnippet(
    String jobId,
    String trackId,
    Duration position,
    void Function(SnippetProgress) progress,
  );
  Future<void> stopSnippet();
}

abstract interface class ReviewMediaPort implements SnippetPort {
  Future<void> saveReview(
    ReviewSession session,
    SongMetadata candidate,
    CoverEdit cover,
  );
  Future<Map<String, Uint8List>> reviewCovers(String jobId, String trackId);
}
