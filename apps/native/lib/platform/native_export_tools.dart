import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../domain/failure.dart';
import 'desktop_tools.dart';
import 'guarded_process.dart';

final class NativeExportTools {
  const NativeExportTools(this.tools, this.script);
  final DesktopTools tools;
  final String script;
  Future<Map<String, dynamic>> run(
    String command,
    Map<String, Object?>? request,
    ProcessScope scope,
    Directory work, {
    Future<void> Function()? monitor,
  }) async {
    File? input;
    try {
      if (request != null) {
        final json = jsonEncode(request);
        if (utf8.encode(json).length > 262144) {
          throw const AppFailure(
            FailureCode.limitExceeded,
            'This export request exceeds its size limit.',
          );
        }
        input = File('${work.path}/export-${const Uuid().v4()}.json');
        await input.create(exclusive: true);
        await input.writeAsString(json, flush: true);
      }
      final output = await scope.run(
        tools.python,
        ['-I', script, command, if (input != null) input.path],
        directory: work,
        maxOutputBytes: 32768,
        timeout: const Duration(minutes: 5),
        monitor: monitor,
      );
      final result = jsonDecode(output) as Map<String, dynamic>;
      if (result['ok'] != true) {
        throw switch (result['error']) {
          'exists' => const AppFailure(
            FailureCode.destinationExists,
            'A file already exists at that destination. Choose a new filename to keep existing files.',
          ),
          'space' => const AppFailure(
            FailureCode.storageUnavailable,
            'The destination is low on space. Free storage or choose another location; prepared files are kept.',
          ),
          'permission' => const AppFailure(
            FailureCode.destinationUnavailable,
            'Permission to save was denied. Choose a writable location; prepared files are kept.',
          ),
          'cancelled' => const AppFailure(
            FailureCode.operationCancelled,
            'Saving stopped. Your prepared files are kept.',
          ),
          'limit' => const AppFailure(
            FailureCode.limitExceeded,
            'This export exceeds its storage limit. Use a smaller selection.',
          ),
          _ => AppFailure(
            command.contains('destination') || command == 'transfer'
                ? FailureCode.destinationUnavailable
                : FailureCode.exportInvalid,
            command.contains('destination') || command == 'transfer'
                ? 'This destination could not safely receive a verified file. Choose another local location.'
                : 'Export files or archive failed verification. Your review is kept.',
          ),
        };
      }
      return result;
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure(
        FailureCode.exportInvalid,
        'The export worker could not finish safely. Your review is kept.',
      );
    } finally {
      if (input != null) {
        try {
          await input.delete();
        } on FileSystemException {
          /* Private startup cleanup retries. */
        }
      }
    }
  }

  Future<void> verify(Directory root) async {
    final scope = tools.scope();
    try {
      final result = await run('versions', null, scope, root);
      if (result['version'] != 1 || result['platform'] != 'linux') {
        throw const AppFailure(
          FailureCode.toolUnavailable,
          'The verified Linux export worker is unavailable.',
        );
      }
    } finally {
      scope.cancel();
    }
  }
}
