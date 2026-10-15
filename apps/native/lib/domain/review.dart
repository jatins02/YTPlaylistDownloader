import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

enum CoverAction { keep, remove, select, import }

final class CoverEdit {
  const CoverEdit.keep()
    : action = CoverAction.keep,
      assetId = null,
      bytes = null;
  const CoverEdit.remove()
    : action = CoverAction.remove,
      assetId = null,
      bytes = null;
  const CoverEdit.select(String id)
    : action = CoverAction.select,
      assetId = id,
      bytes = null;
  CoverEdit.import(Uint8List image)
    : action = CoverAction.import,
      assetId = null,
      bytes = Uint8List.fromList(image).asUnmodifiableView();
  final CoverAction action;
  final String? assetId;
  final Uint8List? bytes;
}

final class ReviewSession {
  const ReviewSession(this.token, this.initial, this.revision);
  final AttemptToken token;
  final TrackRecord initial;
  final int revision;
}

/// Preview only. Stage 6 allocates final collision-safe names for a snapshot.
String filenamePreview(SongMetadata metadata) {
  var stem = metadata.displayName
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(stem)) {
    stem = '_$stem';
  }
  final output = StringBuffer();
  var length = 0;
  for (final rune in stem.runes) {
    final value = String.fromCharCode(rune),
        size = utf8.encode(String.fromCharCode(rune)).length;
    if (length + size > 180) break;
    output.write(value);
    length += size;
  }
  stem = output.toString().replaceAll(RegExp(r'[. ]+$'), '');
  return '${stem.isEmpty ? 'Track' : stem}.mp3';
}

Set<MetadataField> editedFields(SongMetadata before, SongMetadata after) => {
  for (final field in MetadataField.values)
    if (jsonEncode(
          before.toJson()[switch (field) {
            MetadataField.featuredArtists => 'featured_artists',
            MetadataField.needsReview => 'needs_review',
            _ => field.name,
          }],
        ) !=
        jsonEncode(
          after.toJson()[switch (field) {
            MetadataField.featuredArtists => 'featured_artists',
            MetadataField.needsReview => 'needs_review',
            _ => field.name,
          }],
        ))
      field,
};
