import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/draft_store.dart';
import '../data/private_workspace.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import '../domain/playlist_url.dart';
import '../platform/credential_vault.dart';

final class DraftsController extends ChangeNotifier {
  DraftsController({
    required this.jobs,
    required this.workspace,
    required this.vault,
  });
  final DraftStore jobs;
  final PrivateWorkspace workspace;
  final CredentialVault vault;
  List<JobRecord> _drafts = const [];
  List<JobRecord> get drafts => _drafts;
  bool loading = true;
  bool savingDraft = false;
  bool savingKey = false;
  bool hasKey = false;
  AppFailure? failure;
  AppFailure? credentialFailure;
  bool _disposed = false;
  int _draftRevision = 0;
  int _credentialRevision = 0;
  int _loadGeneration = 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (_disposed) return;
    final generation = ++_loadGeneration;
    final draftRevision = _draftRevision;
    final credentialRevision = _credentialRevision;
    loading = true;
    failure = null;
    _notify();
    try {
      final drafts = await jobs.listJobs();
      if (_disposed || generation != _loadGeneration) return;
      if (draftRevision == _draftRevision) {
        _drafts = List.unmodifiable(drafts);
      } else {
        final merged = {for (final job in _drafts) job.id: job};
        for (final job in drafts) {
          final current = merged[job.id];
          if (current == null || job.revision > current.revision) {
            merged[job.id] = job;
          }
        }
        final ordered = merged.values.toList()
          ..sort((a, b) {
            final time = b.updatedAt.compareTo(a.updatedAt);
            return time == 0 ? a.id.compareTo(b.id) : time;
          });
        _drafts = List.unmodifiable(ordered);
      }
      loading = false;
      _notify();
      try {
        final presence = await vault.hasGroqKey();
        if (!_disposed &&
            generation == _loadGeneration &&
            credentialRevision == _credentialRevision) {
          hasKey = presence;
          credentialFailure = null;
        }
      } on AppFailure catch (error) {
        if (!_disposed &&
            generation == _loadGeneration &&
            credentialRevision == _credentialRevision) {
          credentialFailure = error;
        }
      }
    } on AppFailure catch (error) {
      if (generation == _loadGeneration && draftRevision == _draftRevision) {
        failure = error;
      }
    } finally {
      if (generation == _loadGeneration) {
        loading = false;
        _notify();
      }
    }
  }

  Future<bool> saveDraft(String input) async {
    if (savingDraft || _disposed) return false;
    savingDraft = true;
    failure = null;
    _notify();
    try {
      final playlist = PlaylistUrl.parse(input);
      final id = const Uuid().v4();
      await workspace.ensureJob(id);
      final saved = await jobs.createDraft(playlist, identity: id);
      _draftRevision++;
      _drafts = List.unmodifiable([
        saved,
        ..._drafts.where((job) => job.id != saved.id),
      ]);
      return true;
    } on AppFailure catch (error) {
      failure = error;
      return false;
    } catch (_) {
      failure = const AppFailure(
        FailureCode.storageUnavailable,
        'The draft could not be saved. Try again.',
        retryable: true,
      );
      return false;
    } finally {
      savingDraft = false;
      _notify();
    }
  }

  Future<bool> saveKey(String input) async {
    if (savingKey || _disposed) return false;
    savingKey = true;
    _credentialRevision++;
    credentialFailure = null;
    _notify();
    try {
      await vault.saveGroqKey(ApiKey.parse(input));
      hasKey = true;
      return true;
    } on AppFailure catch (error) {
      credentialFailure = error;
      return false;
    } finally {
      savingKey = false;
      _notify();
    }
  }

  Future<void> removeKey() async {
    if (savingKey || _disposed) return;
    savingKey = true;
    _credentialRevision++;
    credentialFailure = null;
    _notify();
    try {
      await vault.removeGroqKey();
      hasKey = false;
    } on AppFailure catch (error) {
      credentialFailure = error;
    } finally {
      savingKey = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
