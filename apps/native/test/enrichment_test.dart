import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/enrichment_repository.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/domain/enrichment.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/metadata/providers.dart';
import 'package:yt_playlist_downloader/metadata/provider_transport.dart';
import 'package:yt_playlist_downloader/platform/credential_vault.dart';

import 'test_support.dart';

Map<String, Object?> responseRow(
  String id, {
  String title = 'Moonlit Train',
  String? version,
  List<String> artists = const ['Mira Vale'],
  bool review = false,
}) => {
  'track_id': id,
  'title': title,
  'artists': artists,
  'featured_artists': <String>[],
  'album': null,
  'version': version,
  'needs_review': review,
  'reason': null,
};
Matcher failure(FailureCode code) =>
    throwsA(isA<AppFailure>().having((e) => e.code, 'safe code', code));

Map<String, Object?> artworkEvidence(SongMetadata metadata, String hash) => {
  'sha256': hash,
  'provider': 'Cover Art Archive',
  'matcher_version': 1,
  'mime': 'image/jpeg',
  'recording_id': '11111111-1111-4111-8111-111111111111',
  'release_id': '22222222-2222-4222-8222-222222222222',
  'source_url': 'https://archive.org/fictional.jpg',
  'matched_title': metadata.songTitle,
  'matched_artists': [...metadata.artists, ...metadata.featuredArtists],
  'album': metadata.album ?? 'Fictional album',
  'width': 16,
  'height': 16,
  'verified_at': '2026-10-15T00:00:00Z',
};

void main() {
  test('stable IDs map reordered multilingual replies and preserve feature formatting', () {
    final sources = [
      NamingInput(trackId: 'a', title: '夜の歌'),
      NamingInput(trackId: 'b', title: 'Moonlit Train (Live)'),
    ];
    final rows = [
      responseRow('b', version: 'Live'),
      responseRow('a', title: '夜の歌'),
    ];
    rows[1]['featured_artists'] = ['Jun Park'];
    final data = validateNaming({'tracks': rows}, sources);
    expect(data['a']!.metadata.displayName, '夜の歌 - Mira Vale - Jun Park');
    expect(data['b']!.metadata.displayName, 'Moonlit Train (Live) - Mira Vale');
    expect(data['b']!.metadata.displayName.endsWith(' - '), isFalse);
  });
  test(
    'missing, extra, duplicate, wrong-type and unknown IDs fail atomically',
    () {
      final inputs = [
        NamingInput(trackId: 'a', title: 'Source'),
        NamingInput(trackId: 'b', title: 'Peer'),
      ];
      for (final data in [
        {
          'tracks': [responseRow('a')],
        },
        {
          'tracks': [responseRow('a'), responseRow('b'), responseRow('extra')],
        },
        {
          'tracks': [responseRow('a'), responseRow('a')],
        },
        {
          'tracks': [responseRow('a'), responseRow('other')],
        },
        {
          'tracks': [
            responseRow('a'),
            {...responseRow('b'), 'artists': 'invented'},
          ],
        },
        {
          'tracks': [
            responseRow('a'),
            {...responseRow('b'), 'unexpected': 1},
          ],
        },
        {
          'tracks': [
            responseRow('a'),
            {...responseRow('b'), 'needs_review': 0},
          ],
        },
        {
          'tracks': [
            responseRow('a'),
            responseRow('b', artists: [], review: false),
          ],
        },
        {
          'tracks': [
            responseRow('a'),
            {...responseRow('b'), 'title': 'bad\nfield'},
          ],
        },
      ]) {
        expect(
          () => validateNaming(data, inputs),
          failure(FailureCode.aiInvalidResponse),
        );
      }
    },
  );
  test(
    'omitted source variants retain original titles and unknown artists',
    () {
      for (final version in [
        'Live',
        'Remix',
        'Slowed + Reverb',
        'Verse-only',
        'Sped up',
        'Acoustic',
        'Cover',
        'Instrumental',
        'Nightcore',
        '2020 Remaster',
        'Radio edit',
        'Extended mix',
        'Karaoke',
        'Demo',
        '8D',
        'Lo-fi',
      ]) {
        final source = 'Moonlit Train ($version)';
        final result = validateNaming(
          {
            'tracks': [responseRow('a')],
          },
          [NamingInput(trackId: 'a', title: source)],
        )['a']!;
        expect(result.metadata.title, source);
        expect(result.metadata.needsReview, isTrue);
        expect(result.metadata.artists, isEmpty);
        expect(result.reason, isNotNull);
      }
    },
  );
  test(
    'provider input allowlists fields and redacts URLs and key-shaped text',
    () {
      final input = NamingInput(
        trackId: 'a',
        title:
            'Fictional gsk_abcdefghijklmnopqrst https://private.example/link',
        uploader: 'Uploader',
        duration: 3,
      );
      final data = jsonEncode(input.toJson());
      expect(data, isNot(contains('gsk_')));
      expect(data, isNot(contains('private.example')));
      expect(data, contains('track_id'));
      expect(
        () => EnrichmentOptions(model: 'bad model'),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => EnrichmentOptions(contact: 'private\nheader'),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test('provider URLs and DNS reject local, reserved, downgrade and hostile destinations', () {
    for (final value in [
      'https://evilarchive.org/x',
      'https://archive.org.evil/x',
      'http://archive.org/x',
      'https://user:password@archive.org/x',
      'https://archive.org:444/x',
      'https://127.0.0.1/x',
      'https://archive.org/x#fragment',
    ]) {
      expect(
        () => SafeProviderTransport.validate(Uri.parse(value)),
        failure(FailureCode.artworkInvalid),
      );
    }
    for (final ip in [
      '127.0.0.1',
      '10.0.0.1',
      '192.168.1.1',
      '169.254.169.254',
      '100.64.1.1',
      '198.18.0.1',
      '::1',
      'fe80::1',
      'fc00::1',
      '::ffff:127.0.0.1',
      '2001:db8::1',
    ]) {
      expect(
        SafeProviderTransport.publicAddress(InternetAddress(ip)),
        isFalse,
        reason: ip,
      );
    }
    expect(
      SafeProviderTransport.publicAddress(InternetAddress('8.8.8.8')),
      isTrue,
    );
    expect(
      SafeProviderTransport.publicAddress(
        InternetAddress('2606:4700:4700::1111'),
      ),
      isTrue,
    );
  });

  group('durable enrichment', () {
    late Fixture fixture;
    late EnrichmentRepository store;
    late TrackRecord track;
    setUp(() async {
      fixture = await Fixture.open();
      store = EnrichmentRepository(fixture.jobs);
      final job = await fixture.draft();
      track = await fixture.ready(await fixture.track(job));
      await fixture.review(job);
    });
    tearDown(() async => fixture.close());
    test(
      'late names cannot overwrite a human edit; stale attempt cannot publish',
      () async {
        final ticket = await store.begin(track.id);
        final during = await fixture.jobs.getTrack(track.id);
        await fixture.jobs.editMetadata(
          trackId: track.id,
          revision: during.revision,
          candidate: SongMetadata(
            title: 'Human title',
            artists: ['Human artist'],
          ),
          fields: {MetadataField.title, MetadataField.artists},
        );
        expect(
          await store.naming(
            ticket,
            EnrichmentOptions(),
            result: NamingResult(
              SongMetadata(title: 'Late guess', artists: ['Model']),
              null,
            ),
          ),
          isFalse,
        );
        await store.finish(ticket);
        expect(
          (await fixture.jobs.getTrack(track.id)).metadata.title,
          'Human title',
        );
        expect(
          (await store.records(track.jobId))[track.id]!.naming,
          NamingState.stale,
        );
        await expectLater(
          store.naming(
            ticket,
            EnrichmentOptions(),
            failure: FailureCode.aiUnavailable,
          ),
          failure(FailureCode.conflict),
        );
      },
    );
    test(
      'earlier field overrides win while remaining fields can enrich',
      () async {
        track = await fixture.jobs.editMetadata(
          trackId: track.id,
          revision: track.revision,
          candidate: SongMetadata(title: 'Human title', artists: ['Mira Vale']),
          fields: {MetadataField.title},
        );
        final ticket = await store.begin(track.id);
        await store.naming(
          ticket,
          EnrichmentOptions(),
          result: NamingResult(
            SongMetadata(
              title: 'Candidate',
              artists: ['AI artist'],
              featuredArtists: ['Jun Park'],
            ),
            null,
          ),
        );
        await store.finish(ticket);
        final actual = await fixture.jobs.getTrack(track.id);
        expect(actual.metadata.title, 'Human title');
        expect(actual.metadata.artists, ['AI artist']);
        expect(actual.metadata.featuredArtists, ['Jun Park']);
      },
    );
    test(
      'rate/provider failure keeps ready audio and visible review warnings',
      () async {
        final before = await PipelineRepository(fixture.jobs)
            .assets(track.jobId);
        final ticket = await store.begin(track.id);
        await store.naming(
          ticket,
          EnrichmentOptions(),
          failure: FailureCode.aiRateLimited,
        );
        await store.finish(ticket);
        final actual = await fixture.jobs.getTrack(track.id),
            record = (await store.records(track.jobId))[track.id]!;
        expect(actual.phase, TrackPhase.ready);
        expect(actual.metadata.needsReview, isTrue);
        expect(actual.metadata.title, track.metadata.title);
        expect(record.namingFailure, FailureCode.aiRateLimited);
        expect(
          (await PipelineRepository(fixture.jobs).assets(track.jobId))
              .map((a) => a.id),
          before.map((a) => a.id),
        );
      },
    );
    test(
      'pause fences workers while preserving playable files and human metadata',
      () async {
        final ticket = await store.begin(track.id);
        await PipelineRepository(fixture.jobs).stop(track.jobId);
        expect((await fixture.jobs.getTrack(track.id)).phase, TrackPhase.ready);
        await expectLater(
          store.naming(
            ticket,
            EnrichmentOptions(),
            failure: FailureCode.aiUnavailable,
          ),
          failure(FailureCode.conflict),
        );
        expect(
          (await store.records(track.jobId))[track.id]!.namingFailure,
          FailureCode.operationCancelled,
        );
      },
    );
    test(
      'restart marks unfinished naming retryable and keeps ready peers',
      () async {
        final ticket = await store.begin(track.id);
        expect(await fixture.jobs.recoverInterruptedAttempts(), 1);
        expect((await fixture.jobs.getTrack(track.id)).phase, TrackPhase.ready);
        expect(
          (await store.records(track.jobId))[track.id]!.naming,
          NamingState.pending,
        );
        await expectLater(store.finish(ticket), failure(FailureCode.conflict));
        await store.begin(track.id);
      },
    );
    test('a human cover removal wins over late artwork and metadata', () async {
      final ticket = await store.begin(track.id);
      await store.naming(
        ticket,
        EnrichmentOptions(),
        result: NamingResult(
          SongMetadata(title: 'New name', artists: ['Mira Vale']),
          null,
        ),
      );
      final revision = (await fixture.jobs.getTrack(track.id)).revision;
      await fixture.jobs.overrideArtwork(trackId: track.id, revision: revision);
      expect(
        await store.artwork(
          ticket,
          revision,
          failure: FailureCode.artworkUncertain,
        ),
        isFalse,
      );
      await store.finish(ticket);
      final record = (await store.records(track.jobId))[track.id]!;
      expect(record.artwork, ArtworkState.overridden);
      expect(record.artworkAssetId, isNull);
    });
    test(
      'ambiguous artwork writes preserve an already verified cover',
      () async {
        final ticket = await store.begin(track.id);
        final id = const Uuid().v4();
        final asset = AssetRecord(
          id: id,
          jobId: track.jobId,
          trackId: track.id,
          kind: AssetKind.artwork,
          relativePath: PrivatePaths.asset(track.jobId, id, AssetKind.artwork),
          sha256: 'c' * 64,
          bytes: 100,
        );
        final provenance = artworkEvidence(track.metadata, asset.sha256);
        await store.artwork(
          ticket,
          ticket.revision,
          asset: asset,
          provenance: provenance,
        );
        for (final operation in [
          () => store.artwork(ticket, ticket.revision),
          () => store.artwork(
            ticket,
            ticket.revision,
            asset: asset,
            provenance: provenance,
            failure: FailureCode.artworkUnavailable,
          ),
          () => store.artwork(
            ticket,
            ticket.revision,
            provenance: provenance,
            failure: FailureCode.artworkUnavailable,
          ),
        ]) {
          await expectLater(operation(), failure(FailureCode.artworkInvalid));
          expect(
            (await store.records(track.jobId))[track.id]!.artworkAssetId,
            asset.id,
          );
          expect(
            (await PipelineRepository(fixture.jobs).assets(track.jobId))
                .where((a) => a.kind == AssetKind.artwork)
                .single
                .id,
            asset.id,
          );
        }
        await store.finish(ticket);
      },
    );
    test('automatic cover is invalidated by an identity edit and freezes with its audio', () async {
      final ticket = await store.begin(track.id);
      await store.naming(
        ticket,
        EnrichmentOptions(),
        result: NamingResult(track.metadata, null),
      );
      final updated = await fixture.jobs.getTrack(track.id),
          id = const Uuid().v4();
      final asset = AssetRecord(
        id: id,
        jobId: track.jobId,
        trackId: track.id,
        kind: AssetKind.artwork,
        relativePath: PrivatePaths.asset(track.jobId, id, AssetKind.artwork),
        sha256: List.filled(64, 'c').join(),
        bytes: 100,
      );
      await store.artwork(
        ticket,
        updated.revision,
        asset: asset,
        provenance: artworkEvidence(updated.metadata, asset.sha256),
      );
      await store.finish(ticket);
      var current = await fixture.jobs.getTrack(track.id);
      await fixture.jobs.editMetadata(
        trackId: track.id,
        revision: current.revision,
        candidate: SongMetadata(
          title: 'Another recording',
          artists: ['Other artist'],
        ),
        fields: {MetadataField.title, MetadataField.artists},
      );
      expect(
        (await store.records(track.jobId))[track.id]!.artworkAssetId,
        isNull,
      );
      expect(
        (await PipelineRepository(fixture.jobs).assets(track.jobId))
            .where((a) => a.kind == AssetKind.artwork),
        isEmpty,
      );
    });
    test('quota cooldown, bounded cache and settings survive repository recreation', () async {
      await store.cooldown('groq', const Duration(hours: 1));
      await expectLater(
        EnrichmentRepository(fixture.jobs)
            .reserve('groq', const Duration(seconds: 2)),
        failure(FailureCode.aiRateLimited),
      );
      final options = EnrichmentOptions(model: 'openai/gpt-oss-20b');
      await store.saveOptions(options);
      expect(
        (await EnrichmentRepository(fixture.jobs).options()).model,
        options.model,
      );
      final bytes = Uint8List.fromList([1, 2, 3]),
          hash = sha256.convert([1, 2, 3]).toString();
      await store.cache(
        track.metadata,
        bytes,
        artworkEvidence(track.metadata, hash),
      );
      expect(
        (await EnrichmentRepository(fixture.jobs).cached(track.metadata))!
            .bytes,
        bytes,
      );
      await fixture.db.update('artwork_cache', {
        'image': Uint8List.fromList([9]),
      });
      expect(await store.cached(track.metadata), isNull);
      for (var i = 0; i < 20; i++) {
        await store.cache(
          SongMetadata(title: 'Track $i', artists: ['Artist']),
          bytes,
          artworkEvidence(
            SongMetadata(title: 'Track $i', artists: ['Artist']),
            hash,
          ),
        );
      }
      expect((await fixture.db.query('artwork_cache')).length, 16);
      await expectLater(
        store.cache(track.metadata, Uint8List(1024 * 1024 + 1), {
          'sha256': hash,
        }),
        failure(FailureCode.artworkInvalid),
      );
    });
    test(
      'Groq redacts keys from requests and validates ordered schema replies',
      () async {
        final vault = MemoryVault();
        await vault.saveGroqKey(ApiKey.parse('gsk_abcdefghijklmnopqrstuvwx'));
        final transport = ReplyTransport(
          (uri, headers, body) async => ProviderReply(
            200,
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'choices': [
                    {
                      'finish_reason': 'stop',
                      'message': {
                        'content': jsonEncode({
                          'tracks': [responseRow(track.id)],
                        }),
                      },
                    },
                  ],
                }),
              ),
            ),
          ),
        );
        final provider = GroqNamingProvider(vault, store, transport: transport);
        final result = await provider.name(
          [NamingInput(trackId: track.id, title: 'Source')],
          EnrichmentOptions(),
          RequestScope(),
        );
        expect(result[track.id]!.metadata.artists, ['Mira Vale']);
        expect(jsonEncode(transport.body), isNot(contains('gsk_')));
        expect(transport.uri!.host, 'api.groq.com');
      },
    );
    test('Groq handles missing key, auth rejection, 429 and refusal without provider diagnostics', () async {
      final vault = MemoryVault();
      final transport = ReplyTransport(
        (uri, headers, body) async =>
            ProviderReply(429, Uint8List(0), retryAfter: '3600'),
      );
      final provider = GroqNamingProvider(vault, store, transport: transport);
      final inputs = [NamingInput(trackId: track.id, title: 'Source')];
      await expectLater(
        provider.name(inputs, EnrichmentOptions(), RequestScope()),
        failure(FailureCode.aiCredentialMissing),
      );
      expect(transport.calls, 0);
      await vault.saveGroqKey(ApiKey.parse('gsk_abcdefghijklmnopqrstuvwx'));
      await expectLater(
        provider.name(inputs, EnrichmentOptions(), RequestScope()),
        failure(FailureCode.aiRateLimited),
      );
      await expectLater(
        provider.name(inputs, EnrichmentOptions(), RequestScope()),
        failure(FailureCode.aiRateLimited),
      );
      expect(transport.calls, 1);
      await fixture.db.delete('provider_state');
      transport.reply = (uri, headers, body) async => ProviderReply(
        401,
        Uint8List.fromList(utf8.encode('private provider diagnostic')),
      );
      await expectLater(
        provider.name(inputs, EnrichmentOptions(), RequestScope()),
        failure(FailureCode.aiUnauthorized),
      );
      await fixture.db.delete('provider_state');
      transport.reply = (uri, headers, body) async => ProviderReply(
        200,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'length',
                  'message': {'content': '{}'},
                },
              ],
            }),
          ),
        ),
      );
      await expectLater(
        provider.name(inputs, EnrichmentOptions(), RequestScope()),
        failure(FailureCode.aiInvalidResponse),
      );
    });
  });
}

final class ReplyTransport implements ProviderTransport {
  ReplyTransport(this.reply);
  Future<ProviderReply> Function(
    Uri,
    Map<String, String>,
    Map<String, Object?>?,
  )
  reply;
  int calls = 0;
  Uri? uri;
  Map<String, Object?>? body;
  @override
  Future<ProviderReply> request(
    Uri uri,
    RequestScope scope, {
    Map<String, String> headers = const {},
    Map<String, Object?>? body,
    int maxBytes = 256 * 1024,
  }) async {
    scope.check();
    calls++;
    this.uri = uri;
    this.body = body;
    return reply(uri, headers, body);
  }
}
