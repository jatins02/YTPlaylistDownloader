import 'dart:convert';
import 'dart:io';

import '../domain/failure.dart';
import '../platform/desktop_tools.dart';
import '../platform/guarded_process.dart';

final class NativeMetadataTools {
  const NativeMetadataTools(this.tools, this.script);
  final DesktopTools tools;
  final String script;
  Future<void> verify(Directory root) async {
    final scope = tools.scope();
    try {
      final value = await run(scope, root, ['versions']);
      if (value['mutagen'] != '1.48.1' || value['pillow'] != '12.3.0') {
        throw const FormatException();
      }
    } catch (_) {
      throw const AppFailure(
        FailureCode.toolUnavailable,
        'The metadata runtime must contain the pinned Mutagen and Pillow versions.',
      );
    } finally {
      scope.cancel();
    }
  }

  Future<Map<String, dynamic>> run(
    ProcessScope scope,
    Directory work,
    List<String> args, {
    Future<void> Function()? monitor,
  }) async {
    final String output;
    try {
      output = await scope.run(
        tools.python,
        ['-I', script, ...args],
        directory: work,
        timeout: const Duration(seconds: 45),
        maxOutputBytes: 16384,
        monitor: monitor,
      );
    } on AppFailure catch (error) {
      if (['image', 'verify-image'].contains(args.first) &&
          ![
            FailureCode.operationCancelled,
            FailureCode.processTimeout,
            FailureCode.limitExceeded,
            FailureCode.storageUnavailable,
          ].contains(error.code)) {
        throw const AppFailure(
          FailureCode.artworkInvalid,
          'Artwork bytes did not pass decoding and normalization.',
        );
      }
      rethrow;
    }
    try {
      return jsonDecode(output) as Map<String, dynamic>;
    } catch (_) {
      throw const AppFailure(
        FailureCode.corruptData,
        'The metadata worker returned an invalid verification result.',
      );
    }
  }
}
