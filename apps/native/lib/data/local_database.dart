import 'package:sqflite_common/sqlite_api.dart';

import '../domain/failure.dart';
import 'schema.dart';

abstract final class LocalDatabase {
  static Future<Database> open(DatabaseFactory factory, String path) async {
    try {
      return await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: Schema.version,
          singleInstance: false,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
            await db.execute('PRAGMA busy_timeout = 5000');
            if (path != inMemoryDatabasePath) {
              await db.rawQuery('PRAGMA journal_mode = WAL');
            }
          },
          onCreate: (db, version) => Schema.migrate(db, 0, version),
          onUpgrade: Schema.migrate,
          onDowngrade: (db, old, current) async => throw const AppFailure(
            FailureCode.corruptData,
            'This data was created by a newer app version. Update the app before opening it.',
          ),
        ),
      );
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'Could not open the local database. Check available storage and permissions.',
        retryable: true,
      );
    }
  }
}
