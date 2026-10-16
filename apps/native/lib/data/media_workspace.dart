import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/failure.dart';
import '../domain/media_models.dart';
import '../domain/models.dart';
import 'private_workspace.dart';

final class MediaWorkspace {
  const MediaWorkspace(this.workspace, this.limits);
  final PrivateWorkspace workspace;
  final PipelineLimits limits;

  /// Archives aggregate multiple MP3s; individual audio keeps its original cap.
  int get maxArchiveBytes {
    final aggregate = limits.maxFileBytes * limits.maxTracks;
    return aggregate < limits.maxJobBytes ? aggregate : limits.maxJobBytes;
  }

  Future<Directory> work(String jobId, String attemptId) async {
    PrivatePaths.validateId(attemptId);
    final job = await workspace.ensureJob(jobId);
    final root = Directory(p.join(job.path, '.work'));
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const AppFailure(
        FailureCode.invalidPath,
        'Unsafe private work directory.',
      );
    }
    await root.create();
    final directory = Directory(p.join(root.path, attemptId));
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const AppFailure(
        FailureCode.conflict,
        'This attempt directory already exists.',
      );
    }
    await directory.create();
    return directory;
  }

  Future<int> bytes(Directory directory) async {
    var bytes = 0, count = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (++count > 10000 || entity is Link) {
        throw const AppFailure(
          FailureCode.limitExceeded,
          'Private storage cannot be scanned safely.',
        );
      }
      if (entity is File) {
        final size = await entity.length();
        final archive = RegExp(
          r'/(?:exports/[a-f0-9-]{36}|\.work/[a-f0-9-]{36}/bundle)/[a-f0-9-]{36}\.zip$',
        ).hasMatch(p.posix.normalize(entity.path.replaceAll('\\', '/')));
        if (size > (archive ? maxArchiveBytes : limits.maxFileBytes)) {
          throw const AppFailure(
            FailureCode.limitExceeded,
            'A private media file exceeded its byte limit.',
          );
        }
        bytes += size;
      }
    }
    return bytes;
  }

  Future<void> checkBudget(String jobId) async {
    final job = await workspace.ensureJob(jobId);
    if (await bytes(job) > limits.maxJobBytes ||
        await bytes(Directory(p.join(workspace.root.path, 'jobs'))) >
            limits.maxWorkspaceBytes) {
      throw const AppFailure(
        FailureCode.limitExceeded,
        'Private media storage reached its limit. Remove an old cancelled draft or use a smaller playlist.',
      );
    }
  }

  Future<File> file(AssetRecord asset) =>
      workspace.assetFile(asset.jobId, asset.id, asset.kind);

  Future<bool> matches(AssetRecord asset) async {
    try {
      final file = await this.file(asset);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != asset.bytes ||
          asset.bytes > limits.maxFileBytes) {
        return false;
      }
      return await digest(file.path) == asset.sha256;
    } on FileSystemException {
      return false;
    }
  }

  Future<String> digest(String path) => Isolate.run(
    () async => (await sha256.bind(File(path).openRead()).first).toString(),
  );

  Future<AssetRecord> stage(
    File source,
    String jobId,
    String trackId,
    String assetId,
    AssetKind kind,
  ) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const AppFailure(
        FailureCode.invalidPath,
        'The media tool returned an unsafe file.',
      );
    }
    final size = await source.length();
    if (size <= 0 || size > limits.maxFileBytes) {
      throw const AppFailure(
        FailureCode.limitExceeded,
        'The media file exceeds its byte limit.',
      );
    }
    final hash = await digest(source.path);
    final target = await workspace.reserveAsset(jobId, assetId, kind);
    try {
      await source.rename(target.path);
    } catch (_) {
      await target.delete();
      rethrow;
    }
    return AssetRecord(
      id: assetId,
      jobId: jobId,
      trackId: trackId,
      kind: kind,
      relativePath: PrivatePaths.asset(jobId, assetId, kind),
      sha256: hash,
      bytes: size,
    );
  }

  /// Under the sole workspace lock and with no active worker for this job.
  /// Never follows links or removes manifests/exports/user destinations.
  Future<void> cleanup(String jobId, List<AssetRecord> retained) async {
    PrivatePaths.validateId(jobId);
    final existing = Directory(p.join(workspace.root.path, 'jobs', jobId));
    if (await FileSystemEntity.type(existing.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final job = await workspace.ensureJob(jobId);
    final work = Directory(p.join(job.path, '.work'));
    if (await FileSystemEntity.type(work.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const AppFailure(
        FailureCode.invalidPath,
        'Unsafe scratch directory.',
      );
    }
    if (await work.exists()) await work.delete(recursive: true);
    final ids = retained.map((a) => p.basename(a.relativePath)).toSet();
    await for (final entity in Directory(
      p.join(job.path, 'assets'),
    ).list(followLinks: false)) {
      if (entity is Link || entity is Directory) {
        throw const AppFailure(
          FailureCode.invalidPath,
          'Unsafe asset directory.',
        );
      }
      if (!ids.contains(p.basename(entity.path))) await entity.delete();
    }
  }
}
