import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/data/enrichment_repository.dart';
import 'package:yt_playlist_downloader/domain/enrichment.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/metadata/providers.dart';
import 'package:yt_playlist_downloader/metadata/provider_transport.dart';

import 'enrichment_test.dart' show ReplyTransport, failure;
import 'test_support.dart';

const recordingId = '11111111-1111-4111-8111-111111111111',
    releaseId = '22222222-2222-4222-8222-222222222222';
Map<String, Object?> recording(String title) => {
  'id': recordingId,
  'title': title,
  'artist-credit': [
    {
      'artist': {'name': 'Mira Vale'},
    },
  ],
};
ProviderReply jsonReply(Object data) => ProviderReply(
  200,
  Uint8List.fromList(utf8.encode(jsonEncode(data))),
  contentType: 'application/json',
);

void main() {
  late Fixture fixture;
  late EnrichmentRepository store;
  setUp(() async {
    fixture = await Fixture.open();
    store = EnrichmentRepository(fixture.jobs);
  });
  tearDown(() async => fixture.close());
  Future<MusicBrainzArtworkProvider> provider({
    bool ambiguousRelease = false,
    bool wrongArtist = false,
    bool unapproved = false,
    bool hostileRedirect = false,
    bool versioned = false,
    bool legacyImage = false,
    bool truncatedReleases = false,
  }) async {
    var count = 0;
    final transport = ReplyTransport((uri, headers, body) async {
      // Remove test cooldowns only; production never bypasses provider pacing.
      await fixture.db.delete('provider_state');
      expect(headers['User-Agent'], contains('YTPlaylistDownloader'));
      if (uri.host == 'musicbrainz.org' && uri.path.endsWith('/recording/')) {
        count++;
        final item = recording(
          versioned ? 'Moonlit Train (Live)' : 'Moonlit Train',
        );
        if (wrongArtist) {
          item['artist-credit'] = [
            {
              'artist': {'name': 'Wrong artist'},
            },
          ];
        }
        return jsonReply({
          'count': 1,
          'recordings': [item],
        });
      }
      if (uri.host == 'musicbrainz.org') {
        return jsonReply({
          ...recording(versioned ? 'Moonlit Train (Live)' : 'Moonlit Train'),
          'releases': [
            {'id': releaseId, 'title': 'Fictional album'},
            if (ambiguousRelease)
              {
                'id': '33333333-3333-4333-8333-333333333333',
                'title': 'Fictional album',
              },
            if (truncatedReleases)
              for (var i = 0; i < 24; i++)
                {
                  'id': '33333333-3333-4333-8333-333333333333',
                  'title': 'Other release $i',
                },
          ],
        });
      }
      if (uri.host == 'coverartarchive.org') {
        return ProviderReply(
          307,
          Uint8List(0),
          location: 'https://archive.org/fictional-index.json',
        );
      }
      if (uri.path == '/fictional-index.json') {
        return jsonReply({
          'images': [
            {
              'front': true,
              'approved': !unapproved,
              'image':
                  '${legacyImage ? 'http' : 'https'}://archive.org/fictional.png',
            },
          ],
        });
      }
      if (hostileRedirect) {
        return ProviderReply(
          302,
          Uint8List(0),
          location: 'https://evil.example/cover',
        );
      }
      expect(count, 1);
      expect(uri.scheme, 'https');
      return ProviderReply(
        200,
        Uint8List.fromList([1, 2, 3]),
        contentType: 'image/png',
      );
    });
    return MusicBrainzArtworkProvider(store, transport: transport);
  }

  test('unique recording/release, approved front art and trusted JSON redirect retain provenance', () async {
    final result = await (await provider()).find(
      SongMetadata(
        title: 'Moonlit Train',
        artists: ['Mira Vale'],
        album: 'Fictional album',
      ),
      EnrichmentOptions(),
      RequestScope(),
    );
    expect(result.provenance['recording_id'], recordingId);
    expect(result.provenance['release_id'], releaseId);
    expect(result.provenance['matched_artists'], ['Mira Vale']);
    expect(result.bytes, [1, 2, 3]);
  });
  test(
    'legacy public image links are reconstructed as HTTPS before fetching',
    () async {
      final result = await (await provider(legacyImage: true)).find(
        SongMetadata(title: 'Moonlit Train', artists: ['Mira Vale']),
        EnrichmentOptions(),
        RequestScope(),
      );
      expect(
        result.provenance['source_url'],
        'https://archive.org/fictional.png',
      );
      for (final url in [
        'http://evil.example/cover.jpg',
        'http://archive.org:8080/cover.jpg',
        'http://user:password@archive.org/cover.jpg',
        'http://archive.org/cover.jpg#fragment',
      ]) {
        expect(() => canonicalArtworkUri(url), throwsA(isA<AppFailure>()));
      }
    },
  );
  test(
    'known album cannot choose between recording release editions',
    () async {
      await expectLater(
        (await provider(ambiguousRelease: true)).find(
          SongMetadata(
            title: 'Moonlit Train',
            artists: ['Mira Vale'],
            album: 'Fictional album',
          ),
          EnrichmentOptions(),
          RequestScope(),
        ),
        failure(FailureCode.artworkUncertain),
      );
    },
  );
  test(
    'a capped release subquery cannot prove a unique known album edition',
    () async {
      await expectLater(
        (await provider(truncatedReleases: true)).find(
          SongMetadata(
            title: 'Moonlit Train',
            artists: ['Mira Vale'],
            album: 'Fictional album',
          ),
          EnrichmentOptions(),
          RequestScope(),
        ),
        failure(FailureCode.artworkUncertain),
      );
    },
  );
  test('wrong artists, missing approved fronts and modified recordings never get guessed covers', () async {
    final metadata = SongMetadata(
      title: 'Moonlit Train',
      artists: ['Mira Vale'],
    );
    await expectLater(
      (await provider(wrongArtist: true))
          .find(metadata, EnrichmentOptions(), RequestScope()),
      failure(FailureCode.artworkUncertain),
    );
    await expectLater(
      (await provider(unapproved: true))
          .find(metadata, EnrichmentOptions(), RequestScope()),
      failure(FailureCode.artworkUncertain),
    );
    final live = SongMetadata(
      title: 'Moonlit Train',
      artists: ['Mira Vale'],
      version: 'Live',
    );
    await expectLater(
      (await provider()).find(live, EnrichmentOptions(), RequestScope()),
      failure(FailureCode.artworkUncertain),
    );
    expect(
      (await (await provider(versioned: true)).find(
        live,
        EnrichmentOptions(),
        RequestScope(),
      )).provenance['matched_title'],
      'Moonlit Train (Live)',
    );
  });
  test(
    'hostile redirects stop before sending a request to an arbitrary host',
    () async {
      await expectLater(
        (await provider(hostileRedirect: true)).find(
          SongMetadata(title: 'Moonlit Train', artists: ['Mira Vale']),
          EnrichmentOptions(),
          RequestScope(),
        ),
        failure(FailureCode.artworkInvalid),
      );
    },
  );
  test('unknown metadata and provider rate limits retain explicit uncertainty/cooldown', () async {
    final transport = ReplyTransport(
      (uri, headers, body) async =>
          ProviderReply(429, Uint8List(0), retryAfter: '3600'),
    );
    final port = MusicBrainzArtworkProvider(store, transport: transport);
    await expectLater(
      port.find(
        SongMetadata(title: 'Source fallback', artists: [], needsReview: true),
        EnrichmentOptions(),
        RequestScope(),
      ),
      failure(FailureCode.artworkUncertain),
    );
    expect(transport.calls, 0);
    await expectLater(
      port.find(
        SongMetadata(title: 'Moonlit Train', artists: ['Mira Vale']),
        EnrichmentOptions(),
        RequestScope(),
      ),
      failure(FailureCode.artworkUnavailable),
    );
    await expectLater(
      store.reserve('musicbrainz', const Duration(seconds: 1)),
      failure(FailureCode.aiRateLimited),
    );
  });
}
