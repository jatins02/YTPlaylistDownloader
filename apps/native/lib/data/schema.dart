import 'package:sqflite_common/sqlite_api.dart';

/// Append migrations; never edit a version that has shipped.
abstract final class Schema {
  static const version = 4;

  static Future<void> migrate(DatabaseExecutor db, int from, int to) async {
    for (var target = from + 1; target <= to; target++) {
      switch (target) {
        case 1:
          // Historical migrations must not change when the runtime enums grow.
          const phases =
              "'draft','queued','enumerating','processing','reviewReady','exporting','exportReady','cancelled','failed'";
          const tracks =
              "'queued','downloading','converting','enriching','ready','failed','cancelled'";
          await db.execute('''CREATE TABLE jobs (
            id TEXT PRIMARY KEY,
            playlist_id TEXT NOT NULL,
            source_url TEXT NOT NULL,
            title TEXT NOT NULL,
            phase TEXT NOT NULL CHECK (phase IN ($phases)),
            revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )''');
          await db.execute('''CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
            video_id TEXT NOT NULL,
            source_title TEXT NOT NULL,
            metadata TEXT NOT NULL,
            suggestion TEXT,
            overrides TEXT NOT NULL DEFAULT '[]',
            phase TEXT NOT NULL CHECK (phase IN ($tracks)),
            revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
            selected INTEGER NOT NULL DEFAULT 1 CHECK (selected IN (0,1)),
            UNIQUE(job_id, video_id),
            UNIQUE(job_id, id)
          )''');
          await db.execute('''CREATE TABLE playlist_entries (
            id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
            position INTEGER NOT NULL CHECK (position > 0),
            track_id TEXT,
            error_code TEXT,
            UNIQUE(job_id, position),
            FOREIGN KEY (job_id, track_id) REFERENCES tracks(job_id, id)
          )''');
          await db.execute(
            'CREATE INDEX jobs_updated ON jobs(updated_at DESC, id)',
          );
          await db.execute('CREATE INDEX tracks_job ON tracks(job_id)');
        case 2:
          await db.execute('''CREATE TABLE attempts (
            id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
            track_id TEXT,
            stage TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            status TEXT NOT NULL CHECK (status IN ('running','retryable','complete','cancelled')),
            checkpoint TEXT NOT NULL,
            error_code TEXT,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (job_id, track_id) REFERENCES tracks(job_id, id)
          )''');
          await db.execute(
            'CREATE INDEX attempts_owner ON attempts(job_id, track_id, stage, status)',
          );
          await db.execute('''CREATE TABLE assets (
            id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
            track_id TEXT,
            kind TEXT NOT NULL,
            relative_path TEXT NOT NULL UNIQUE,
            sha256 TEXT NOT NULL,
            bytes INTEGER NOT NULL CHECK (bytes >= 0),
            FOREIGN KEY (job_id, track_id) REFERENCES tracks(job_id, id)
          )''');
          await db.execute('''CREATE TABLE exports (
            id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
            job_revision INTEGER NOT NULL CHECK (job_revision >= 0),
            snapshot_hash TEXT NOT NULL,
            snapshot TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','complete','failed')),
            created_at INTEGER NOT NULL,
            UNIQUE(job_id, job_revision),
            UNIQUE(job_id, snapshot_hash)
          )''');
        case 3:
          // Legacy effective metadata may already be edited. Keep NULL rather
          // than misrepresenting it as the originally acquired metadata.
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN original_metadata TEXT',
          );
        case 4:
          await db.execute(
            'ALTER TABLE jobs ADD COLUMN enumerated INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute('ALTER TABLE jobs ADD COLUMN error_code TEXT');
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN duration_seconds REAL',
          );
          await db.execute('ALTER TABLE tracks ADD COLUMN error_code TEXT');
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN source_uploader TEXT',
          );
          await db.execute(
            'ALTER TABLE playlist_entries ADD COLUMN source_title TEXT',
          );
          await db.execute(
            'ALTER TABLE playlist_entries ADD COLUMN selected INTEGER NOT NULL DEFAULT 1',
          );
          await db.execute(
            'ALTER TABLE assets ADD COLUMN active INTEGER NOT NULL DEFAULT 1',
          );
        default:
          throw StateError('Unknown schema version $target');
      }
    }
  }
}
