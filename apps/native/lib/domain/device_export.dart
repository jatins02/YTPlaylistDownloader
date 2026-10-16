import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/private_workspace.dart';
import 'failure.dart';
import 'models.dart';

enum ExportFileKind { mp3, zip, manifest }

final class ExportFile {
  const ExportFile({
    required this.id,
    required this.kind,
    required this.filename,
    required this.sha256,
    required this.bytes,
    this.trackId,
  });
  final String id, filename, sha256;
  final ExportFileKind kind;
  final String? trackId;
  final int bytes;
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'track_id': trackId,
    'filename': filename,
    'sha256': sha256,
    'bytes': bytes,
  };
  factory ExportFile.fromJson(Map<String, dynamic> value) => ExportFile(
    id: value['id'] as String,
    kind: ExportFileKind.values.byName(value['kind'] as String),
    trackId: value['track_id'] as String?,
    filename: value['filename'] as String,
    sha256: value['sha256'] as String,
    bytes: value['bytes'] as int,
  );
}

/// Complete verified private preparation. It is not a destination-save receipt.
final class ExportPublication {
  ExportPublication({
    required this.snapshot,
    required List<ExportFile> files,
    required this.contentManifest,
  }) : files = List.unmodifiable(files) {
    validate();
  }
  final ExportSnapshot snapshot;
  final List<ExportFile> files;
  final String contentManifest;
  ExportFile get archive =>
      files.singleWhere((f) => f.kind == ExportFileKind.zip);
  ExportFile get manifest =>
      files.singleWhere((f) => f.kind == ExportFileKind.manifest);
  List<ExportFile> get tracks =>
      files.where((f) => f.kind == ExportFileKind.mp3).toList();
  String get json => jsonEncode({
    'version': 1,
    'manifest': contentManifest,
    'files': files.map((f) => f.toJson()).toList(),
  });
  void validate() {
    try {
      PrivatePaths.validateId(snapshot.id);
      PrivatePaths.validateId(snapshot.jobId);
      if (sha256.convert(utf8.encode(snapshot.json)).toString() !=
          snapshot.hash) {
        throw const FormatException();
      }
      final frozen = jsonDecode(snapshot.json) as Map<String, dynamic>;
      final rows = frozen['tracks'] as List;
      final ids = rows.map((r) => r['track_id'] as String).toSet();
      if (ids.isEmpty ||
          ids.length != rows.length ||
          files.length != ids.length + 2 ||
          frozen['job_id'] != snapshot.jobId ||
          frozen['job_revision'] != snapshot.jobRevision ||
          tracks.map((f) => f.trackId).toSet().difference(ids).isNotEmpty ||
          tracks.length != ids.length ||
          tracks.map((f) => f.trackId).toSet().length != ids.length ||
          files.map((f) => f.id).toSet().length != files.length ||
          files.where((f) => f.kind == ExportFileKind.zip).length != 1 ||
          files.where((f) => f.kind == ExportFileKind.manifest).length != 1) {
        throw const FormatException();
      }
      final names = <String>{};
      for (final file in files) {
        PrivatePaths.validateId(file.id);
        if (file.bytes <= 0 ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(file.sha256) ||
            utf8.encode(file.filename).length > 200 ||
            RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]').hasMatch(file.filename) ||
            file.filename.endsWith('.') ||
            file.filename.endsWith(' ') ||
            !names.add(file.filename.toLowerCase()) ||
            (file.kind == ExportFileKind.mp3
                ? !file.filename.endsWith('.mp3')
                : file.trackId != null)) {
          throw const FormatException();
        }
      }
      if (manifest.filename != 'manifest.json' ||
          !archive.filename.endsWith('.zip') ||
          manifest.sha256 !=
              sha256.convert(utf8.encode(contentManifest)).toString() ||
          manifest.bytes != utf8.encode(contentManifest).length) {
        throw const FormatException();
      }
      final content = jsonDecode(contentManifest) as Map<String, dynamic>;
      if (content['version'] != 1 ||
          content['export_id'] != snapshot.id ||
          content['job_id'] != snapshot.jobId ||
          content['snapshot_hash'] != snapshot.hash ||
          jsonEncode(content['files']) !=
              jsonEncode(tracks.map((f) => f.toJson()).toList())) {
        throw const FormatException();
      }
    } catch (_) {
      throw const AppFailure(
        FailureCode.corruptData,
        'The prepared export manifest failed verification. Return to review and prepare it again.',
      );
    }
  }

  factory ExportPublication.fromJson(ExportSnapshot snapshot, String json) {
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      if (data['version'] != 1) throw const FormatException();
      return ExportPublication(
        snapshot: snapshot,
        contentManifest: data['manifest'] as String,
        files: (data['files'] as List)
            .map((f) => ExportFile.fromJson(f as Map<String, dynamic>))
            .toList(),
      );
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure(
        FailureCode.corruptData,
        'The prepared export record could not be read safely.',
      );
    }
  }
}

final class DeliveryReceipt {
  const DeliveryReceipt(this.id, this.exportId, this.fileId, this.filename);
  final String id, exportId, fileId, filename;
}
