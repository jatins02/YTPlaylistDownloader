import 'dart:convert';

import 'failure.dart';
import 'models.dart';

const namingPromptVersion = 'native-stage4-v1';
const namingSchemaVersion = 1;

final class EnrichmentOptions {
  EnrichmentOptions({
    this.model = 'openai/gpt-oss-120b',
    this.contact = 'https://github.com/jatins02/YTPlaylistDownloader',
  }) {
    final url = Uri.tryParse(contact);
    final publicUrl =
        url != null &&
        url.scheme == 'https' &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty &&
        url.query.isEmpty &&
        url.fragment.isEmpty &&
        url.port == 443;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_./-]{0,99}$').hasMatch(model) ||
        model.contains('gsk_') ||
        contact.length > 200 ||
        contact.contains('gsk_') ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(contact) ||
        !(publicUrl ||
            RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(contact))) {
      throw const AppFailure(
        FailureCode.invalidMetadata,
        'Enter a valid model ID and public project URL or contact email.',
      );
    }
  }
  final String model, contact;
  String get userAgent => 'YTPlaylistDownloader/0.1 ($contact)';
}

enum NamingState { pending, running, complete, failed, stale }

enum ArtworkState {
  pending,
  running,
  matched,
  unavailable,
  failed,
  stale,
  overridden,
}

final class EnrichmentRecord {
  const EnrichmentRecord({
    required this.trackId,
    required this.naming,
    required this.artwork,
    this.namingFailure,
    this.artworkFailure,
    this.reason,
    this.provenance,
    this.artworkAssetId,
    this.artworkOverride = false,
  });
  final String trackId;
  final NamingState naming;
  final ArtworkState artwork;
  final FailureCode? namingFailure, artworkFailure;
  final String? reason, artworkAssetId;
  final Map<String, Object?>? provenance;
  final bool artworkOverride;
}

final class NamingInput {
  NamingInput({
    required this.trackId,
    required this.title,
    this.uploader,
    this.duration,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(trackId)) _invalid();
    if (title.trim().isEmpty ||
        title.length > 500 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(title) ||
        (uploader != null &&
            (uploader!.length > 200 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(uploader!)))) {
      _invalid();
    }
    if (duration != null &&
        (!duration!.isFinite || duration! <= 0 || duration! > 1201)) {
      _invalid();
    }
  }
  final String trackId, title;
  final String? uploader;
  final double? duration;
  Map<String, Object?> toJson() => {
    'track_id': trackId,
    'title': promptText(title),
    if (uploader != null) 'uploader': promptText(uploader!),
    if (duration != null) 'duration': duration,
  };
}

String promptText(String value) => value
    .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), '[link omitted]')
    .replaceAll(RegExp(r'gsk_[A-Za-z0-9_-]+'), '[redacted]');

Never _invalid() => throw const AppFailure(
  FailureCode.aiInvalidResponse,
  'The naming response could not be validated. Original titles are kept for review.',
  retryable: true,
);

String boundedText(Object? value, int limit, {bool allowEmpty = false}) {
  if (value is! String ||
      (!allowEmpty && value.trim().isEmpty) ||
      value.length > limit ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) ||
      value.contains('gsk_')) {
    _invalid();
  }
  return value.trim();
}

Set<String> versionMarkers(String text) {
  final patterns = <String, String>{
    'live': r'\blive\b',
    'remix': r'\bremix\b',
    'slowed': r'\bslowed\b',
    'reverb': r'\breverb(?:ed)?\b',
    'verse-only': r'\bverse[\s-]*only\b',
    'cover': r'\bcover\b',
    'instrumental': r'\binstrumental\b',
    'acoustic': r'\bacoustic\b',
    'sped-up': r'\bsped[\s-]*up\b',
    'nightcore': r'\bnightcore\b',
    'remaster': r'\bremaster(?:ed)?\b',
    'radio-edit': r'\bradio[\s-]*edit\b',
    'extended': r'\bextended(?:[\s-]*mix)?\b',
    'karaoke': r'\bkaraoke\b',
    'demo': r'\bdemo\b',
    '8d': r'\b8d\b',
    'lo-fi': r'\blo[\s-]*fi\b',
  };
  return {
    for (final entry in patterns.entries)
      if (RegExp(entry.value, caseSensitive: false).hasMatch(text)) entry.key,
  };
}

final class NamingResult {
  const NamingResult(this.metadata, this.reason);
  final SongMetadata metadata;
  final String? reason;
}

Map<String, NamingResult> validateNaming(
  Object? data,
  List<NamingInput> inputs,
) {
  if (inputs.isEmpty ||
      inputs.length > 10 ||
      inputs.map((e) => e.trackId).toSet().length != inputs.length ||
      data is! Map ||
      data.length != 1 ||
      data['tracks'] is! List) {
    _invalid();
  }
  final rows = data['tracks'] as List;
  if (rows.length != inputs.length) _invalid();
  final sources = {for (final input in inputs) input.trackId: input};
  final results = <String, NamingResult>{};
  const fields = {
    'track_id',
    'title',
    'artists',
    'featured_artists',
    'album',
    'version',
    'needs_review',
    'reason',
  };
  for (final row in rows) {
    if (row is! Map ||
        row.keys.toSet().difference(fields).isNotEmpty ||
        row.length != fields.length ||
        row['track_id'] is! String ||
        !sources.containsKey(row['track_id']) ||
        results.containsKey(row['track_id']) ||
        row['needs_review'] is! bool) {
      _invalid();
    }
    List<String> names(Object? value) {
      if (value is! List || value.length > 20) _invalid();
      final list = value.map((e) => boundedText(e, 200)).toList();
      if (list.map((e) => e.toLowerCase()).toSet().length != list.length) {
        _invalid();
      }
      return list;
    }

    final id = row['track_id'] as String;
    final title = boundedText(row['title'], 500);
    final artists = names(row['artists']),
        features = names(row['featured_artists']);
    if (artists
        .map((e) => e.toLowerCase())
        .toSet()
        .intersection(features.map((e) => e.toLowerCase()).toSet())
        .isNotEmpty) {
      _invalid();
    }
    final album = row['album'] == null ? null : boundedText(row['album'], 500);
    final version = row['version'] == null
        ? null
        : boundedText(row['version'], 200);
    final reason = row['reason'] == null
        ? null
        : boundedText(row['reason'], 300);
    if (artists.isEmpty && row['needs_review'] != true) _invalid();
    var metadata = SongMetadata(
      title: title,
      artists: artists,
      featuredArtists: features,
      album: album,
      version: version,
      needsReview: row['needs_review'] as bool,
    );
    var reviewReason = reason;
    if (versionMarkers(sources[id]!.title)
        .difference(versionMarkers(metadata.songTitle))
        .isNotEmpty) {
      metadata = SongMetadata(
        title: sources[id]!.title,
        artists: const [],
        needsReview: true,
      );
      reviewReason = 'Naming omitted source version or clip details; original title retained.';
    }
    results[id] = NamingResult(metadata, reviewReason);
  }
  return Map.unmodifiable(results);
}

Map<String, Object?> get namingSchema => {
  'type': 'object',
  'additionalProperties': false,
  'required': ['tracks'],
  'properties': {
    'tracks': {
      'type': 'array',
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': [
          'track_id',
          'title',
          'artists',
          'featured_artists',
          'album',
          'version',
          'needs_review',
          'reason',
        ],
        'properties': {
          'track_id': {'type': 'string'},
          'title': {'type': 'string'},
          'artists': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'featured_artists': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'album': {
            'type': ['string', 'null'],
          },
          'version': {
            'type': ['string', 'null'],
          },
          'needs_review': {'type': 'boolean'},
          'reason': {
            'type': ['string', 'null'],
          },
        },
      },
    },
  },
};

String artworkKey(SongMetadata metadata) => jsonEncode({
  'title': metadata.songTitle,
  'artists': metadata.artists,
  'features': metadata.featuredArtists,
  'album': metadata.album,
  'version': metadata.version,
  'matcher': 1,
});

String enrichmentFailureMessage(FailureCode? failure) => switch (failure) {
  FailureCode.aiCredentialMissing =>
    'Add your own Groq key in AI key settings, then retry naming.',
  FailureCode.aiUnauthorized => 'Groq rejected the key or model permissions. Check your key and selected model.',
  FailureCode.aiRateLimited => 'The provider quota is exhausted or rate limited. Audio is kept; retry after the provider cooldown.',
  FailureCode.aiModelUnavailable => 'The configured model rejected structured naming. Select an available Groq model in Naming settings.',
  FailureCode.storageUnavailable => 'Secure storage or private files are unavailable. Unlock your keyring and check available space.',
  FailureCode.aiInvalidResponse => 'The naming reply was incomplete or invalid. Original titles are kept for review.',
  FailureCode.aiUnavailable => 'Naming is unavailable. Audio and source-title fallbacks are kept; retry when connected.',
  FailureCode.artworkUncertain =>
    'No unique recording and release match. No cover was guessed.',
  FailureCode.artworkInvalid => 'Artwork did not pass trusted-source or image validation. No cover was applied.',
  FailureCode.expiredMedia => 'Temporary artwork has expired or been removed. Metadata and device-saved copies are kept.',
  FailureCode.artworkUnavailable =>
    'Artwork is unavailable. Audio and names are kept; retry when connected.',
  _ => 'Details need review. Your audio and edits are kept.',
};

String normalizedIdentity(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'''[\s\-_–—.,!?()\[\]{}"'’]+'''), ' ')
    .trim();

void validateArtworkEvidence(
  Map<String, Object?> value,
  SongMetadata metadata,
  String digest,
) {
  final uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );
  final uri = Uri.tryParse(
    value['source_url'] is String ? value['source_url'] as String : '',
  );
  final artists = value['matched_artists'];
  final expected = [...metadata.artists, ...metadata.featuredArtists];
  if (value['sha256'] != digest ||
      value['provider'] != 'Cover Art Archive' ||
      value['matcher_version'] != 1 ||
      value['mime'] != 'image/jpeg' ||
      value['recording_id'] is! String ||
      !uuid.hasMatch(value['recording_id'] as String) ||
      value['release_id'] is! String ||
      !uuid.hasMatch(value['release_id'] as String) ||
      value['matched_title'] != metadata.songTitle ||
      artists is! List ||
      jsonEncode(artists) != jsonEncode(expected) ||
      expected.isEmpty ||
      value['album'] is! String ||
      (value['album'] as String).trim().isEmpty ||
      (value['album'] as String).length > 500 ||
      (metadata.album != null &&
          normalizedIdentity(value['album'] as String) !=
              normalizedIdentity(metadata.album!)) ||
      value['width'] is! int ||
      (value['width'] as int) < 1 ||
      (value['width'] as int) > 768 ||
      value['height'] is! int ||
      (value['height'] as int) < 1 ||
      (value['height'] as int) > 768 ||
      value['verified_at'] is! String ||
      DateTime.tryParse(value['verified_at'] as String) == null ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.toString().length > 2048 ||
      (uri.host != 'coverartarchive.org' &&
          uri.host != 'archive.org' &&
          !uri.host.endsWith('.archive.org'))) {
    throw const AppFailure(
      FailureCode.artworkInvalid,
      'Cover identity/provenance did not pass validation.',
    );
  }
}
