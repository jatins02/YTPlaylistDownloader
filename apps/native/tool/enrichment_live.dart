import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/enrichment_repository.dart';
import 'package:yt_playlist_downloader/data/job_repository.dart';
import 'package:yt_playlist_downloader/data/local_database.dart';
import 'package:yt_playlist_downloader/data/media_workspace.dart';
import 'package:yt_playlist_downloader/data/private_workspace.dart';
import 'package:yt_playlist_downloader/domain/credential.dart';
import 'package:yt_playlist_downloader/domain/enrichment.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/metadata/native_metadata_tools.dart';
import 'package:yt_playlist_downloader/metadata/providers.dart';
import 'package:yt_playlist_downloader/metadata/provider_transport.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/platform/native_codec.dart';

/// Development acceptance only. Native releases use SecureCredentialVault and
/// never read dotenv. This tool receives an explicitly authorized key on stdin.
Future<void> main(List<String> args) async {
  final artworkOnly = args.length == 2 && args.last == '--artwork-only';
  if (!Platform.isLinux ||
      (args.length != 1 && !artworkOnly) ||
      args.first != '--live' ||
      Platform.environment['YTPD_MEDIA_RUNTIME'] == null) {
    stderr.writeln(
      'Requires --live and the verified Linux YTPD_MEDIA_RUNTIME.',
    );
    exitCode = 2;
    return;
  }
  final temporary = await Directory.systemTemp.createTemp('ytpd-stage4-live-');
  PrivateWorkspace? workspace;
  Database? database;
  final network = RequestScope();
  try {
    final input = BytesBuilder(copy: false);
    await for (final chunk in stdin.timeout(const Duration(seconds: 5))) {
      if (input.length + chunk.length > 65536) throw const FormatException();
      input.add(chunk);
    }
    final data =
        jsonDecode(utf8.decode(input.takeBytes())) as Map<String, dynamic>;
    final inputs = ((artworkOnly ? <Object?>[] : data['tracks']) as List)
        .map(
          (row) => NamingInput(
            trackId: row['track_id'] as String,
            title: row['title'] as String,
            uploader: row['uploader'] as String?,
            duration: (row['duration'] as num?)?.toDouble(),
          ),
        )
        .toList();
    workspace = await PrivateWorkspace.acquire(
      Directory('${temporary.path}/private'),
    );
    sqfliteFfiInit();
    database = await LocalDatabase.open(
      databaseFactoryFfi,
      workspace.databasePath,
    );
    final jobs = JobRepository(database), store = EnrichmentRepository(jobs);
    final options = EnrichmentOptions(model: data['model'] as String);
    final tools = await DesktopTools.load(
      File(Platform.environment['YTPD_MEDIA_RUNTIME']!),
      File('assets/process_guard.py').absolute.path,
    );
    await tools.verify(workspace.root);
    final metadataTools = NativeMetadataTools(
      tools,
      File('assets/metadata_tools.py').absolute.path,
    );
    await metadataTools.verify(workspace.root);
    final names = artworkOnly
        ? <String, NamingResult>{}
        : await GroqNamingProvider(
            InputVault(ApiKey.parse(data['key'] as String)),
            store,
          ).name(inputs, options, network);
    final report = <Map<String, Object?>>[];
    final files = MediaWorkspace(workspace, const PipelineLimits());
    final job = await jobs.createDraft(
      PlaylistUrl.parse(
        'https://www.youtube.com/playlist?list=PLproviderProof01',
      ),
    );
    for (final input in inputs) {
      final value = names[input.trackId]!;
      final row = <String, Object?>{
        'track_id': input.trackId,
        'valid_id_mapping': true,
        'needs_review': value.metadata.needsReview,
        'version_details_preserved': versionMarkers(input.title)
            .difference(versionMarkers(value.metadata.songTitle))
            .isEmpty,
      };
      if (['known-original', 'known-modified'].contains(input.trackId)) {
        row['known_artist_identified'] = value.metadata.artists.any(
          (a) => a.toLowerCase() == 'daft punk',
        );
        row['known_title_identified'] =
            normalizedIdentity(value.metadata.title) == 'get lucky';
      }
      if (input.trackId == 'known-original') {
        row['featured_artists_identified'] = value.metadata.featuredArtists
            .map((a) => a.toLowerCase())
            .toSet()
            .containsAll({'pharrell williams', 'nile rodgers'});
      }
      if (input.trackId == 'unknown-fictional') {
        row['unknown_is_explicit'] =
            value.metadata.needsReview && value.metadata.artists.isEmpty;
      }
      final scope = tools.scope();
      final work = await files.work(job.id, const Uuid().v4());
      try {
        final image = await MusicBrainzArtworkProvider(store)
            .find(value.metadata, options, network);
        final raw = File('${work.path}/raw');
        await raw.writeAsBytes(image.bytes);
        final verified = await metadataTools.run(scope, work, [
          'image',
          raw.path,
          '${work.path}/cover.jpg',
        ]);
        row['artwork'] = 'matched and decoded';
        row['cover_sha256'] = verified['sha256'];
        row['recording_id'] = image.provenance['recording_id'];
        row['release_id'] = image.provenance['release_id'];
      } on AppFailure catch (error) {
        row['artwork'] = error.code.name;
      } finally {
        scope.cancel();
      }
      report.add(row);
    }
    final knownArtwork = await checkKnownArtwork(
      store,
      options,
      network,
      metadataTools,
      files,
      job.id,
    );
    final qualityPassed = artworkOnly ? null : namingQualityPassed(report);
    final acceptancePassed =
        (artworkOnly || qualityPassed == true) &&
        artworkAcceptancePassed(knownArtwork);
    if (!acceptancePassed) exitCode = 1;
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'mode': 'opt-in-live-providers',
        'artwork_only': artworkOnly,
        'acceptance_passed': acceptancePassed,
        'quality_passed': qualityPassed,
        'model': options.model,
        'prompt_version': namingPromptVersion,
        'schema_version': namingSchemaVersion,
        'tracks': report,
        'known_artwork': knownArtwork,
      }),
    );
  } on AppFailure catch (error) {
    stderr.writeln('Live check could not complete: ${error.code.name}.');
    exitCode = 1;
  } catch (_) {
    stderr.writeln(
      'Live check could not complete safely. Raw diagnostics withheld.',
    );
    exitCode = 1;
  } finally {
    network.cancel();
    await database?.close();
    await workspace?.close();
    await temporary.delete(recursive: true);
  }
}

bool namingQualityPassed(List<Map<String, Object?>> rows) =>
    rows.isNotEmpty &&
    rows.every(
      (row) =>
          row['valid_id_mapping'] == true &&
          row['version_details_preserved'] == true &&
          row['known_artist_identified'] != false &&
          row['known_title_identified'] != false &&
          row['featured_artists_identified'] != false &&
          row['unknown_is_explicit'] != false,
    );

bool artworkAcceptancePassed(Map<String, Object?> row) =>
    row['identity_verified'] == true &&
    row['image_verified'] == true &&
    row['embedded_cover_verified'] == true &&
    row['full_audio_decode_verified'] == true;

/// Public catalog fixture selected from a unique recording/release, never a
/// substitute for ambiguous artist/title matches in real user jobs. The MP3
/// is a synthetic test tone; no provider music or user export is produced.
Future<Map<String, Object?>> checkKnownArtwork(
  EnrichmentRepository store,
  EnrichmentOptions options,
  RequestScope network,
  NativeMetadataTools metadataTools,
  MediaWorkspace files,
  String jobId,
) async {
  final metadata = SongMetadata(
    title: 'Foley',
    artists: ['Patricia Taxxon'],
    album: 'Foley Artist',
  );
  final row = <String, Object?>{
    'title': metadata.title,
    'artist': metadata.artists.single,
    'album': metadata.album,
    'audio_kind': 'synthetic test tone, not the original recording',
  };
  final tools = metadataTools.tools, scope = metadataTools.tools.scope();
  final work = await files.work(jobId, const Uuid().v4());
  try {
    final image = await MusicBrainzArtworkProvider(store)
        .find(metadata, options, network);
    row['recording_id'] = image.provenance['recording_id'];
    row['release_id'] = image.provenance['release_id'];
    row['identity_verified'] =
        row['recording_id'] == '7af784a9-2bd1-4a11-8712-6c2432f17b0b' &&
        row['release_id'] == 'db3b609d-3383-4675-af4c-fd5023c42367';
    if (row['identity_verified'] != true) return row;
    final raw = File('${work.path}/raw'),
        cover = File('${work.path}/cover.jpg');
    await raw.writeAsBytes(image.bytes);
    final verified = await metadataTools.run(scope, work, [
      'image',
      raw.path,
      cover.path,
    ]);
    row['image_verified'] = true;
    row['cover_sha256'] = verified['sha256'];
    row['cover_bytes'] = verified['bytes'];
    row['cover_width'] = verified['width'];
    row['cover_height'] = verified['height'];
    final audio = File('${work.path}/tone.mp3');
    await scope.run(
      tools.ffmpeg,
      [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=2.4',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '320k',
        '-n',
        audio.path,
      ],
      directory: work,
      timeout: const Duration(seconds: 30),
    );
    final request = File('${work.path}/request.json');
    await request.writeAsString(
      jsonEncode({
        'metadata': metadata.toJson(),
        'song_title': metadata.songTitle,
        'track_id': const Uuid().v4(),
        'track_revision': 0,
        'video_id': 'abcdefghijk',
        'cover_path': cover.path,
        'cover_sha256': verified['sha256'],
        'snapshot_hash': sha256
            .convert(utf8.encode(jsonEncode(metadata.toJson())))
            .toString(),
      }),
    );
    final output = File('${work.path}/tagged.mp3');
    final tagged = await metadataTools.run(scope, work, [
      'tag',
      audio.path,
      output.path,
      request.path,
    ]);
    row['embedded_cover_verified'] =
        tagged['cover_sha256'] == verified['sha256'] &&
        tagged['song_title'] == metadata.songTitle &&
        tagged['id3_version'] == 3;
    final codec = NativeCodec(tools, const PipelineLimits());
    final original = await codec.verify(
      audio,
      scope,
      work,
      () async {},
      mp3: true,
    );
    await codec.verify(
      output,
      scope,
      work,
      () async {},
      mp3: true,
      expected: original.durationSeconds,
    );
    row['full_audio_decode_verified'] = true;
    row['tagged_file_sha256'] = tagged['sha256'];
    row['artwork'] = 'matched, decoded and embedded with readback';
  } on AppFailure catch (error) {
    row['failure'] = error.code.name;
  } finally {
    scope.cancel();
  }
  return row;
}

final class InputVault implements CredentialVault {
  InputVault(this.key);
  ApiKey? key;
  @override
  Future<ApiKey?> readGroqKey() async => key;
  @override
  Future<bool> hasGroqKey() async => key != null;
  @override
  Future<void> saveGroqKey(ApiKey value) async {
    key = value;
  }

  @override
  Future<void> removeGroqKey() async {
    key = null;
  }
}
