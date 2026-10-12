import 'failure.dart';

enum JobPhase {
  draft,
  queued,
  enumerating,
  processing,
  reviewReady,
  exporting,
  exportReady,
  cancelled,
  failed,
}

enum TrackPhase {
  queued,
  downloading,
  converting,
  enriching,
  ready,
  failed,
  cancelled,
}

enum MetadataField {
  title,
  artists,
  featuredArtists,
  album,
  version,
  needsReview,
}

enum TaskStage { acquisition, conversion, enrichment, export }

enum CheckpointStep { pending, acquired, converted, enriched, published }

enum AssetKind { source, audio, preview, artwork, zip }

const jobTransitions = <JobPhase, Set<JobPhase>>{
  JobPhase.draft: {JobPhase.queued, JobPhase.cancelled},
  JobPhase.queued: {JobPhase.enumerating, JobPhase.cancelled, JobPhase.failed},
  JobPhase.enumerating: {
    JobPhase.processing,
    JobPhase.cancelled,
    JobPhase.failed,
  },
  JobPhase.processing: {
    JobPhase.reviewReady,
    JobPhase.cancelled,
    JobPhase.failed,
  },
  JobPhase.reviewReady: {JobPhase.exporting, JobPhase.cancelled},
  JobPhase.exporting: {
    JobPhase.exportReady,
    JobPhase.reviewReady,
    JobPhase.cancelled,
  },
  JobPhase.exportReady: {JobPhase.reviewReady, JobPhase.cancelled},
  JobPhase.failed: {JobPhase.queued, JobPhase.cancelled},
  JobPhase.cancelled: {},
};

const trackTransitions = <TrackPhase, Set<TrackPhase>>{
  TrackPhase.queued: {
    TrackPhase.downloading,
    TrackPhase.failed,
    TrackPhase.cancelled,
  },
  TrackPhase.downloading: {
    TrackPhase.converting,
    TrackPhase.failed,
    TrackPhase.cancelled,
  },
  TrackPhase.converting: {
    TrackPhase.enriching,
    TrackPhase.ready,
    TrackPhase.failed,
    TrackPhase.cancelled,
  },
  TrackPhase.enriching: {
    TrackPhase.ready,
    TrackPhase.failed,
    TrackPhase.cancelled,
  },
  TrackPhase.ready: {TrackPhase.enriching, TrackPhase.cancelled},
  TrackPhase.failed: {TrackPhase.queued, TrackPhase.cancelled},
  TrackPhase.cancelled: {},
};

String _text(String value, int maxLength) {
  final result = value.trim();
  if (result.isEmpty ||
      result.length > maxLength ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(result)) {
    throw const AppFailure(
      FailureCode.invalidMetadata,
      'Metadata contains an empty, overlong or invalid field.',
    );
  }
  return result;
}

List<String> _names(List<String> input) {
  if (input.length > 20) {
    throw const AppFailure(
      FailureCode.invalidMetadata,
      'Too many artist names.',
    );
  }
  return List.unmodifiable(input.map((value) => _text(value, 200)));
}

final class SongMetadata {
  SongMetadata({
    required String title,
    required List<String> artists,
    List<String> featuredArtists = const [],
    String? album,
    String? version,
    this.needsReview = false,
  }) : title = _text(title, 500),
       artists = _names(artists),
       featuredArtists = _names(featuredArtists),
       album = album == null || album.trim().isEmpty ? null : _text(album, 500),
       version = version == null || version.trim().isEmpty
           ? null
           : _text(version, 200) {
    if (this.artists.isEmpty && !needsReview) {
      throw const AppFailure(
        FailureCode.invalidMetadata,
        'An unknown artist must be marked for review.',
      );
    }
  }

  factory SongMetadata.fromJson(Map<String, Object?> json) => SongMetadata(
    title: json['title']! as String,
    artists: List<String>.from(json['artists']! as List<Object?>),
    featuredArtists: List<String>.from(
      json['featured_artists']! as List<Object?>,
    ),
    album: json['album'] as String?,
    version: json['version'] as String?,
    needsReview: json['needs_review']! as bool,
  );

  final String title;
  final List<String> artists;
  final List<String> featuredArtists;
  final String? album;
  final String? version;
  final bool needsReview;

  String get songTitle =>
      version != null && !title.toLowerCase().contains(version!.toLowerCase())
      ? '$title ($version)'
      : title;

  String get displayName {
    final main = artists.isEmpty ? 'Unknown Artist' : artists.join(', ');
    final features = featuredArtists.isEmpty
        ? ''
        : ' - ${featuredArtists.join(', ')}';
    return '$songTitle - $main$features';
  }

  Map<String, Object?> toJson() => {
    'title': title,
    'artists': artists,
    'featured_artists': featuredArtists,
    'album': album,
    'version': version,
    'needs_review': needsReview,
  };

  SongMetadata merge(SongMetadata candidate, Set<MetadataField> fields) {
    final chosenArtists = fields.contains(MetadataField.artists)
        ? candidate.artists
        : artists;
    return SongMetadata(
      title: fields.contains(MetadataField.title) ? candidate.title : title,
      artists: chosenArtists,
      featuredArtists: fields.contains(MetadataField.featuredArtists)
          ? candidate.featuredArtists
          : featuredArtists,
      album: fields.contains(MetadataField.album) ? candidate.album : album,
      version: fields.contains(MetadataField.version)
          ? candidate.version
          : version,
      needsReview:
          chosenArtists.isEmpty ||
          (fields.contains(MetadataField.needsReview)
              ? candidate.needsReview
              : needsReview),
    );
  }
}

final class JobRecord {
  const JobRecord({
    required this.id,
    required this.playlistId,
    required this.sourceUrl,
    required this.title,
    required this.phase,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
  });
  final String id;
  final String playlistId;
  final String sourceUrl;
  final String title;
  final JobPhase phase;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class TrackRecord {
  TrackRecord({
    required this.id,
    required this.jobId,
    required this.videoId,
    required this.sourceTitle,
    required this.metadata,
    this.originalMetadata,
    required Set<MetadataField> overrides,
    required this.phase,
    required this.revision,
    required this.selected,
  }) : overrides = Set.unmodifiable(overrides);
  final String id;
  final String jobId;
  final String videoId;
  final String sourceTitle;
  final SongMetadata metadata;

  /// Null for legacy rows whose original structured fields were not recorded.
  final SongMetadata? originalMetadata;
  final Set<MetadataField> overrides;
  final TrackPhase phase;
  final int revision;
  final bool selected;
}

final class Checkpoint {
  Checkpoint({required this.step, this.assetId, this.completedBytes = 0}) {
    if (completedBytes < 0) {
      throw const AppFailure(
        FailureCode.invalidMetadata,
        'Checkpoint byte counts cannot be negative.',
      );
    }
  }
  final CheckpointStep step;
  final String? assetId;
  final int completedBytes;
  Map<String, Object?> toJson() => {
    'step': step.name,
    'asset_id': assetId,
    'completed_bytes': completedBytes,
  };
}

final class AttemptToken {
  const AttemptToken({
    required this.id,
    required this.jobId,
    required this.stage,
    required this.generation,
    this.trackId,
  });
  final String id;
  final String jobId;
  final String? trackId;
  final TaskStage stage;
  final int generation;
}

final class ExportSnapshot {
  const ExportSnapshot({
    required this.id,
    required this.jobId,
    required this.jobRevision,
    required this.hash,
    required this.json,
  });
  final String id;
  final String jobId;
  final int jobRevision;
  final String hash;
  final String json;
}

final class AssetRecord {
  const AssetRecord({
    required this.id,
    required this.jobId,
    required this.kind,
    required this.relativePath,
    required this.sha256,
    required this.bytes,
    this.trackId,
  });
  final String id;
  final String jobId;
  final String? trackId;
  final AssetKind kind;
  final String relativePath;
  final String sha256;
  final int bytes;
}
