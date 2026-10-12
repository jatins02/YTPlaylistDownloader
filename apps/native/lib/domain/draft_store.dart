import 'models.dart';
import 'playlist_url.dart';

/// The draft screen depends on persistence behavior, not SQLite internals.
abstract interface class DraftStore {
  Future<List<JobRecord>> listJobs();
  Future<JobRecord> createDraft(PlaylistUrl playlist, {String? identity});
}
