import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../domain/failure.dart';

Future<Uint8List?> pickCoverImage() async {
  try {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Cover image',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
        ),
      ],
    );
    if (file == null) return null;
    const limit = 5 * 1024 * 1024;
    if (await file.length() > limit) {
      throw const AppFailure(
        FailureCode.artworkInvalid,
        'Choose a cover image up to 5 MiB.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, limit + 1)) {
      if (bytes.length + chunk.length > limit) {
        throw const AppFailure(
          FailureCode.artworkInvalid,
          'Choose a cover image up to 5 MiB.',
        );
      }
      bytes.add(chunk);
    }
    if (bytes.isEmpty) {
      throw const AppFailure(
        FailureCode.artworkInvalid,
        'The chosen image is empty. Choose another file.',
      );
    }
    return bytes.takeBytes();
  } on AppFailure {
    rethrow;
  } catch (_) {
    throw const AppFailure(
      FailureCode.artworkUnavailable,
      'The cover could not be opened. Your edits are kept; retry the file chooser.',
    );
  }
}
