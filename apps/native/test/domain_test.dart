import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';
import 'package:yt_playlist_downloader/platform/media_port.dart';

void main() {
  test(
    'YouTube and music links become the same canonical playlist identity',
    () {
      for (final host in [
        'www.youtube.com',
        'music.youtube.com',
        'm.youtube.com',
      ]) {
        expect(
          PlaylistUrl.parse(
            'https://$host/watch?v=ignored&list=PL1234567890&si=ignored',
          ).canonical,
          'https://www.youtube.com/playlist?list=PL1234567890',
        );
      }
    },
  );

  test(
    'invalid URLs, credentials, nondefault ports and mixes are rejected',
    () {
      for (final input in [
        'http://youtube.com/playlist?list=PL1234567890',
        'https://youtube.com.evil.example/playlist?list=PL1234567890',
        'https://name:password@youtube.com/playlist?list=PL1234567890',
        'https://youtube.com:8080/playlist?list=PL1234567890',
        'https://127.0.0.1/playlist?list=PL1234567890',
        'https://youtube.com/playlist?list=RD1234567890',
        'https://youtube.com/playlist?list=PL1234567890&list=PLabcdefghij',
        'https://youtube.com/playlist?list=%FF',
      ]) {
        expect(() => PlaylistUrl.parse(input), throwsA(isA<AppFailure>()));
      }
    },
  );

  test('song-first names preserve versions and omit empty features', () {
    final metadata = SongMetadata(
      title: 'Moonlit Train',
      artists: ['Mira Vale'],
      version: 'Slowed + Reverbed',
    );
    expect(
      metadata.displayName,
      'Moonlit Train (Slowed + Reverbed) - Mira Vale',
    );
    expect(
      SongMetadata(
        title: metadata.songTitle,
        artists: ['Mira Vale'],
        version: metadata.version,
      ).songTitle,
      metadata.songTitle,
    );
    expect(
      SongMetadata(
        title: 'Moonlit Train',
        artists: ['Mira Vale'],
        featuredArtists: ['Jun Park'],
      ).displayName,
      'Moonlit Train - Mira Vale - Jun Park',
    );
  });

  test('artist lists are immutable and missing artists require review', () {
    final artists = ['Mira Vale'];
    final metadata = SongMetadata(title: 'Moonlit Train', artists: artists);
    artists.add('Mutated');
    expect(metadata.artists, ['Mira Vale']);
    expect(() => metadata.artists.add('Mutated'), throwsUnsupportedError);
    expect(
      () => SongMetadata(title: 'Unknown', artists: []),
      throwsA(isA<AppFailure>()),
    );
    expect(
      SongMetadata(
        title: 'Unknown',
        artists: [],
        needsReview: true,
      ).displayName,
      'Unknown - Unknown Artist',
    );
  });

  test('a suggestion cannot clear uncertainty for a human-overridden unknown artist', () {
    final original = SongMetadata(
      title: 'Original',
      artists: [],
      needsReview: true,
    );
    final model = SongMetadata(title: 'Model', artists: ['Model artist']);
    final merged = original.merge(model, {
      MetadataField.title,
      MetadataField.needsReview,
    });
    expect(merged.artists, isEmpty);
    expect(merged.needsReview, isTrue);
  });

  test(
    'API-key debugging is redacted and malformed credentials are rejected',
    () {
      final secret = 'gsk_${List.filled(40, 'x').join()}';
      final key = ApiKey.parse(secret);
      expect(key.value, secret);
      expect(key.toString(), isNot(contains(secret)));
      expect(key.toString(), contains('redacted'));
      expect(
        () => ApiKey.parse('GROQ_API_KEY=$secret'),
        throwsA(isA<AppFailure>()),
      );
    },
  );

  test(
    'unsupported native media never reports a fake acquisition success',
    () async {
      const port = UnavailableMediaPort(DevicePlatform.ios);
      final capabilities = await port.capabilities();
      expect(capabilities.canAcquire, isFalse);
      expect(capabilities.canExport, isFalse);
      expect(
        () => port.acquire(
          playlist: PlaylistUrl.parse(
            'https://youtube.com/playlist?list=PL1234567890',
          ),
          jobId: 'fixture',
        ),
        throwsA(
          isA<AppFailure>().having(
            (value) => value.code,
            'code',
            FailureCode.mediaUnavailable,
          ),
        ),
      );
    },
  );
}
