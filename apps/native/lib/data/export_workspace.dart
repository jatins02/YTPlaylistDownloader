import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/device_export.dart';
import '../domain/failure.dart';
import 'media_workspace.dart';
import 'private_workspace.dart';

final class ExportWorkspace {
  const ExportWorkspace(this.media);
  final MediaWorkspace media;
  Future<Directory> root(String jobId) async {
    final job = await media.workspace.ensureJob(jobId);
    final exports = Directory(p.join(job.path, 'exports'));
    final type = await FileSystemEntity.type(exports.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const AppFailure(
        FailureCode.invalidPath,
        'Unsafe private export storage.',
      );
    }
    await exports.create();
    return exports;
  }

  static String basename(ExportFile file) {
    PrivatePaths.validateId(file.id);
    return '${file.id}.${switch (file.kind) {
      ExportFileKind.mp3 => 'mp3',
      ExportFileKind.zip => 'zip',
      ExportFileKind.manifest => 'json',
    }}';
  }

  Future<Directory> directory(String jobId, String exportId) async {
    PrivatePaths.validateId(exportId);
    return Directory(p.join((await root(jobId)).path, exportId));
  }

  Future<File> file(ExportPublication publication, ExportFile file) async {
    final directory = await this.directory(
      publication.snapshot.jobId,
      publication.snapshot.id,
    );
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const AppFailure(
        FailureCode.exportInvalid,
        'Prepared files are missing or expired. Return to review and prepare them again.',
      );
    }
    final result = File(p.join(directory.path, basename(file)));
    final cap = file.kind == ExportFileKind.zip
        ? media.maxArchiveBytes
        : media.limits.maxFileBytes;
    if (await FileSystemEntity.type(result.path, followLinks: false) !=
            FileSystemEntityType.file ||
        file.bytes > cap ||
        await result.length() != file.bytes ||
        await media.digest(result.path) != file.sha256) {
      throw const AppFailure(
        FailureCode.exportInvalid,
        'Prepared bytes changed or expired. Return to review and prepare them again.',
      );
    }
    return result;
  }

  Future<void> cleanup(String jobId, Set<String> retained) async {
    PrivatePaths.validateId(jobId);
    final path = p.join(media.workspace.root.path, 'jobs', jobId, 'exports');
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final base = await root(jobId);
    await for (final entity in base.list(followLinks: false)) {
      PrivatePaths.validateId(p.basename(entity.path));
      if (entity is! Directory) {
        throw const AppFailure(
          FailureCode.invalidPath,
          'Unsafe private export directory.',
        );
      }
      if (!retained.contains(p.basename(entity.path))) {
        await entity.delete(recursive: true);
      }
    }
  }
}
