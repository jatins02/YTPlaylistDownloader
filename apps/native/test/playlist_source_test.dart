import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/platform/playlist_source.dart';

void main() {
  String listing(List<Object?> entries, {int? count}) => jsonEncode({
    '_type': 'playlist',
    'entries': entries,
    'playlist_count': count,
  });
  test('duration limits remain distinct from live and unavailable sources', () {
    final entries = parsePlaylistListing(
      listing([
        {'id': 'abcdefghijk', 'title': 'Long studio track', 'duration': 601},
        {'id': '12345678901', 'title': 'Live stream', 'live_status': 'is_live'},
        {
          'id': '12345678902',
          'title': 'Private source',
          'duration': 601,
          'availability': 'private',
        },
      ]),
      const PipelineLimits(),
    );
    expect(entries.map((entry) => entry.failure), [
      FailureCode.limitExceeded,
      FailureCode.liveUnsupported,
      FailureCode.sourceUnavailable,
    ]);
  });
  test('reported gaps and omitted entries stay visible instead of shrinking the playlist', () {
    final result = parsePlaylistListing(
      listing([
        {'id': 'abcdefghijk', 'title': 'First', 'playlist_index': 1},
        {'id': '12345678901', 'title': 'Third', 'playlist_index': 3},
      ], count: 4),
      const PipelineLimits(),
    );
    expect(result, hasLength(4));
    expect(result.map((e) => e.position), [1, 2, 3, 4]);
    expect(result[1].videoId, isNull);
    expect(result[3].failure, FailureCode.sourceUnavailable);
  });
  test(
    'source parsing keeps duplicate occurrences and missing IDs in order',
    () {
      final result = parsePlaylistListing(
        listing([
          {
            'id': 'abcdefghijk',
            'title': '夜 (Live)',
            'duration': 140,
            'uploader': 'Fictional channel',
          },
          null,
          {'id': 'abcdefghijk', 'title': 'Repeat'},
        ]),
        const PipelineLimits(),
      );
      expect(result, hasLength(3));
      expect(result[1].failure, FailureCode.sourceUnavailable);
      expect(result.map((e) => e.position), [1, 2, 3]);
      expect(result.first.title, '夜 (Live)');
      expect(result.first.uploader, 'Fictional channel');
    },
  );
  test(
    'over-capacity metadata rejects even a short bounded enumeration response',
    () {
      expect(
        () => parsePlaylistListing(
          listing([], count: 101),
          const PipelineLimits(),
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
    'private and live entries are visible failures, never silently omitted',
    () {
      final result = parsePlaylistListing(
        listing([
          {'id': 'abcdefghijk', 'title': 'Private', 'availability': 'private'},
          {'id': '12345678901', 'title': 'Live', 'live_status': 'is_live'},
          {'id': 'unicode0001', 'title': 'Overlong', 'duration': 601},
        ]),
        const PipelineLimits(),
      );
      expect(result.map((e) => e.failure), [
        FailureCode.sourceUnavailable,
        FailureCode.liveUnsupported,
        FailureCode.limitExceeded,
      ]);
    },
  );
  test('malformed values and control characters cannot become metadata', () {
    for (final entry in [
      {'id': 'abcdefghijk', 'title': 123},
      {'id': 'abcdefghijk', 'title': 'bad\u0000'},
      {'id': 'abcdefghijk', 'title': 'ok', 'duration': -1},
    ]) {
      expect(
        () => parsePlaylistListing(listing([entry]), const PipelineLimits()),
        throwsA(isA<AppFailure>()),
      );
    }
  });
  test('runtime capacity configuration is validated before processing', () {
    expect(
      () => const PipelineLimits(maxFileBytes: 0).validate(),
      throwsA(isA<AppFailure>()),
    );
    expect(
      () => const PipelineLimits(maxEntries: 1, maxTracks: 2).validate(),
      throwsA(isA<AppFailure>()),
    );
    const PipelineLimits().validate();
  });
}
