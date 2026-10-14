import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/failure.dart';
import '../domain/models.dart';

abstract final class PrivatePaths {
  static final _uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );
  static void validateId(String value) {
    if (!_uuid.hasMatch(value)) {
      throw const AppFailure(
        FailureCode.invalidPath,
        'Invalid private file identity.',
      );
    }
  }

  static String asset(String jobId, String assetId, AssetKind kind) {
    validateId(jobId);
    validateId(assetId);
    final extension = switch (kind) {
      AssetKind.source => 'bin',
      AssetKind.audio || AssetKind.preview => 'mp3',
      AssetKind.artwork => 'jpg',
      AssetKind.zip => 'zip',
    };
    return 'jobs/$jobId/assets/$assetId.$extension';
  }
}

/// One main-isolate workspace per application process, plus an OS file lock.
final class PrivateWorkspace {
  PrivateWorkspace._(this.root, this._lock);
  final Directory root;
  final RandomAccessFile _lock;
  static final Set<String> _heldRoots = {};
  bool _closed = false;

  static Future<void> _directory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      throw const AppFailure(
        FailureCode.invalidPath,
        'Private storage contains an unsafe file path.',
      );
    }
    await directory.create(recursive: true);
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('/bin/chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw const AppFailure(
          FailureCode.storageUnavailable,
          'Could not protect private app storage.',
        );
      }
    }
  }

  static Future<PrivateWorkspace> acquire(Directory requestedRoot) async {
    RandomAccessFile? lock;
    String? canonical;
    var claimed = false;
    try {
      await _directory(requestedRoot);
      canonical = await requestedRoot.resolveSymbolicLinks();
      if (!_heldRoots.add(canonical)) {
        throw const AppFailure(
          FailureCode.storageBusy,
          'This app data is already open in another window.',
          retryable: true,
        );
      }
      claimed = true;
      final lockPath = p.join(canonical, '.session.lock');
      if (await FileSystemEntity.type(lockPath, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const AppFailure(
          FailureCode.invalidPath,
          'Private storage contains an unsafe lock path.',
        );
      }
      lock = await File(lockPath).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final root = Directory(canonical);
      await _directory(Directory(p.join(root.path, 'jobs')));
      return PrivateWorkspace._(root, lock);
    } catch (error) {
      try {
        if (lock != null) await lock.close();
      } catch (_) {
        // Preserve the original failure; still release our in-process claim.
      } finally {
        // A failed duplicate must not release the first session's guard.
        if (canonical != null && claimed) _heldRoots.remove(canonical);
      }
      if (error is AppFailure) rethrow;
      throw const AppFailure(
        FailureCode.storageBusy,
        'Could not open private storage. Close other app windows and check permissions.',
        retryable: true,
      );
    }
  }

  String get databasePath => p.join(root.path, 'drafts.sqlite');

  Future<File> installProcessGuard(Uint8List bytes) async {
    if (_closed || bytes.length > 16384) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'The private tool supervisor could not be installed.',
      );
    }
    final file = File(p.join(root.path, 'process_guard.py'));
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const AppFailure(
        FailureCode.invalidPath,
        'Unsafe tool supervisor path.',
      );
    }
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> verifyDatabasePaths() async {
    for (final suffix in ['', '-wal', '-shm']) {
      if (await FileSystemEntity.type(
            '$databasePath$suffix',
            followLinks: false,
          ) ==
          FileSystemEntityType.link) {
        throw const AppFailure(
          FailureCode.invalidPath,
          'Private storage contains an unsafe database path.',
        );
      }
    }
  }

  Future<Directory> ensureJob(String jobId) async {
    if (_closed) {
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'Private storage is closed.',
      );
    }
    PrivatePaths.validateId(jobId);
    final jobs = Directory(p.join(root.path, 'jobs'));
    await _directory(jobs);
    final job = Directory(p.join(jobs.path, jobId));
    await _directory(job);
    await _directory(Directory(p.join(job.path, 'assets')));
    return job;
  }

  Future<File> assetFile(String jobId, String assetId, AssetKind kind) async {
    final relative = PrivatePaths.asset(jobId, assetId, kind);
    await ensureJob(jobId);
    final file = File(p.joinAll([root.path, ...relative.split('/')]));
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const AppFailure(
        FailureCode.invalidPath,
        'Private storage contains an unsafe asset path.',
      );
    }
    return file;
  }

  Future<File> reserveAsset(
    String jobId,
    String assetId,
    AssetKind kind,
  ) async {
    final file = await assetFile(jobId, assetId, kind);
    try {
      return await file.create(exclusive: true);
    } on FileSystemException {
      throw const AppFailure(
        FailureCode.conflict,
        'This private asset already exists or cannot be reserved.',
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _lock.unlock();
    } finally {
      try {
        await _lock.close();
      } finally {
        _heldRoots.remove(root.path);
      }
    }
  }
}
