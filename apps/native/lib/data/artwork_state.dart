import 'package:sqflite_common/sqlite_api.dart';

/// Automatically matched covers belong to one metadata identity. A deliberate
/// human cover/removal choice is retained across later metadata/provider changes.
Future<void> invalidateAutomaticArtwork(
  DatabaseExecutor db,
  String trackId,
) async {
  final rows = await db.query(
    'enrichment',
    where: 'track_id=?',
    whereArgs: [trackId],
  );
  if (rows.isEmpty || rows.single['artwork_override'] == 1) return;
  await db.update(
    'assets',
    {'active': 0},
    where: "track_id=? AND kind='artwork'",
    whereArgs: [trackId],
  );
  await db.update(
    'enrichment',
    {
      'artwork': 'stale',
      'artwork_asset_id': null,
      'provenance': null,
      'artwork_failure': null,
    },
    where: 'track_id=?',
    whereArgs: [trackId],
  );
}
