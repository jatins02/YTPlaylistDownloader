import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../domain/device_export.dart';
import '../domain/failure.dart';

abstract interface class ExportDestination {
  Future<String?> choose(ExportFile file);
}

/// Native desktop save panel. Phone document/share adapters need device proof.
final class LinuxExportDestination implements ExportDestination {
  const LinuxExportDestination();
  @override
  Future<String?> choose(ExportFile file) async {
    if (!Platform.isLinux) {
      throw const AppFailure(
        FailureCode.unsupportedPlatform,
        'This save adapter is verified only on Linux.',
      );
    }
    try {
      final extension = file.kind == ExportFileKind.zip ? 'zip' : 'mp3';
      final location = await getSaveLocation(
        suggestedName: file.filename,
        acceptedTypeGroups: [
          XTypeGroup(
            label: extension.toUpperCase(),
            extensions: [extension],
            mimeTypes: [extension == 'zip' ? 'application/zip' : 'audio/mpeg'],
          ),
        ],
      );
      if (location == null) return null;
      if (!p.isAbsolute(location.path) ||
          p.extension(location.path).toLowerCase() != '.$extension') {
        throw const AppFailure(
          FailureCode.destinationUnavailable,
          'Choose a local filename with the requested extension. Your prepared files are kept.',
        );
      }
      final parent = await Directory(p.dirname(location.path))
          .resolveSymbolicLinks();
      return p.join(parent, p.basename(location.path));
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure(
        FailureCode.destinationUnavailable,
        'The save panel could not finish. Your prepared files are kept; retry choosing a destination.',
      );
    }
  }
}
