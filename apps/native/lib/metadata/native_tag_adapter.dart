import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/media_workspace.dart';
import '../data/private_workspace.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import '../platform/guarded_process.dart';
import '../platform/native_codec.dart';
import 'native_metadata_tools.dart';

final class VerifiedTagFile {
  const VerifiedTagFile(
    this.file,
    this.snapshotHash,
    this.trackId,
    this.sha256,
    this.coverSha256,
  );
  final File file;
  final String snapshotHash, trackId, sha256;
  final String? coverSha256;
}

/// Stage 4 adapter only: new frozen-revision derivatives are verified here.
/// Publication, ZIPs and destination transfer still require Stage 6.
final class NativeTagAdapter {
  const NativeTagAdapter(this.tools, this.files, this.codec);
  final NativeMetadataTools tools;
  final MediaWorkspace files;
  final NativeCodec codec;

  Future<VerifiedTagFile> prepare(
    ExportSnapshot snapshot,
    String trackId,
    ProcessScope scope,
    Directory work,
    Future<void> Function() monitor,
  ) async {
    if (sha256.convert(utf8.encode(snapshot.json)).toString() !=
        snapshot.hash) {
      throw const AppFailure(
        FailureCode.tagInvalid,
        'The frozen metadata snapshot failed verification.',
      );
    }
    try {
      PrivatePaths.validateId(snapshot.jobId);
      final base = Directory(
        p.join(files.workspace.root.path, 'jobs', snapshot.jobId, '.work'),
      );
      if (await FileSystemEntity.type(base.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(work.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          !p.isWithin(
            await base.resolveSymbolicLinks(),
            await work.resolveSymbolicLinks(),
          )) {
        throw const FormatException();
      }
      final data = jsonDecode(snapshot.json) as Map<String, dynamic>;
      if (data['job_id'] != snapshot.jobId ||
          data['job_revision'] != snapshot.jobRevision) {
        throw const FormatException();
      }
      final rows = (data['tracks'] as List)
          .where((t) => t['track_id'] == trackId)
          .toList();
      if (rows.length != 1) throw const FormatException();
      final track = rows.single as Map<String, dynamic>;
      final metadata = SongMetadata.fromJson(
        track['metadata'] as Map<String, dynamic>,
      );
      if (!RegExp(r'^[A-Za-z0-9_-]{11}$')
              .hasMatch(track['video_id'] as String) ||
          track['track_revision'] is! int) {
        throw const FormatException();
      }
      AssetRecord asset(String id, AssetKind kind) {
        final matches = (data['assets'] as List)
            .where(
              (a) =>
                  a['id'] == id &&
                  a['kind'] == kind.name &&
                  a['job_id'] == snapshot.jobId &&
                  a['track_id'] == trackId,
            )
            .toList();
        if (matches.length != 1) throw const FormatException();
        final a = matches.single;
        if (a['relative_path'] !=
            PrivatePaths.asset(snapshot.jobId, id, kind)) {
          throw const FormatException();
        }
        return AssetRecord(
          id: id,
          jobId: snapshot.jobId,
          trackId: trackId,
          kind: kind,
          relativePath: a['relative_path'] as String,
          sha256: a['sha256'] as String,
          bytes: a['bytes'] as int,
        );
      }

      final audio = asset(track['audio_asset_id'] as String, AssetKind.audio);
      final coverId = track['artwork_asset_id'] as String?;
      final cover = coverId == null ? null : asset(coverId, AssetKind.artwork);
      if (!await files.matches(audio) ||
          (cover != null && !await files.matches(cover))) {
        throw const FormatException();
      }
      final input = await files.file(audio);
      final original = await codec.verify(
        input,
        scope,
        work,
        monitor,
        mp3: true,
      );
      final output = File('${work.path}/tagged-$trackId.mp3');
      final request = File('${work.path}/tag-request-$trackId.json');
      await request.create(exclusive: true);
      await request.writeAsString(
        jsonEncode({
          'metadata': metadata.toJson(),
          'track_id': trackId,
          'track_revision': track['track_revision'],
          'video_id': track['video_id'],
          'cover_path': cover == null ? null : (await files.file(cover)).path,
          'cover_sha256': cover?.sha256,
          'snapshot_hash': snapshot.hash,
        }),
        flush: true,
      );
      final result = await tools.run(scope, work, [
        'tag',
        input.path,
        output.path,
        request.path,
      ], monitor: monitor);
      scope.check();
      if (result['snapshot_hash'] != snapshot.hash ||
          result['track_id'] != trackId ||
          result['track_revision'] != track['track_revision'] ||
          result['cover_sha256'] != cover?.sha256 ||
          result['id3_version'] != 3 ||
          result['sha256'] != await files.digest(output.path) ||
          result['bytes'] != await output.length()) {
        throw const FormatException();
      }
      await codec.verify(
        output,
        scope,
        work,
        monitor,
        mp3: true,
        expected: original.durationSeconds,
      );
      await monitor();
      scope.check();
      if (!await files.matches(audio) ||
          (cover != null && !await files.matches(cover))) {
        throw const FormatException();
      }
      return VerifiedTagFile(
        output,
        snapshot.hash,
        trackId,
        result['sha256'] as String,
        cover?.sha256,
      );
    } on AppFailure catch (error) {
      if ([
        FailureCode.operationCancelled,
        FailureCode.processTimeout,
        FailureCode.limitExceeded,
        FailureCode.storageUnavailable,
      ].contains(error.code)) {
        rethrow;
      }
      throw const AppFailure(
        FailureCode.tagInvalid,
        'MP3 tags, embedded cover or audio did not pass verification.',
      );
    } catch (_) {
      throw const AppFailure(
        FailureCode.tagInvalid,
        'The frozen MP3 derivative could not be verified.',
      );
    }
  }
}
