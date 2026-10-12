import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/job_repository.dart';
import '../data/local_database.dart';
import '../data/private_workspace.dart';
import '../domain/failure.dart';
import '../platform/credential_vault.dart';
import '../platform/media_port.dart';

final class AppRuntime {
  AppRuntime._({
    required this.workspace,
    required this.jobs,
    required this.vault,
    required this.media,
    required this.recoveredAttempts,
  });
  final PrivateWorkspace workspace;
  final JobRepository jobs;
  final CredentialVault vault;
  final MediaPort media;
  final int recoveredAttempts;
  bool _closed = false;

  static DevicePlatform get devicePlatform {
    if (Platform.isAndroid) return DevicePlatform.android;
    if (Platform.isIOS) return DevicePlatform.ios;
    if (Platform.isLinux) return DevicePlatform.linux;
    if (Platform.isWindows) return DevicePlatform.windows;
    if (Platform.isMacOS) return DevicePlatform.macos;
    return DevicePlatform.unknown;
  }

  static Future<AppRuntime> open({
    Directory? supportRoot,
    CredentialVault? vault,
  }) async {
    PrivateWorkspace? workspace;
    Database? database;
    try {
      final platform = devicePlatform;
      if (platform == DevicePlatform.unknown) {
        throw const AppFailure(
          FailureCode.unsupportedPlatform,
          'This application requires a supported native device.',
        );
      }
      final base = supportRoot ?? await getApplicationSupportDirectory();
      workspace = await PrivateWorkspace.acquire(
        Directory(p.join(base.path, 'ytplaylistdownloader')),
      );
      await workspace.verifyDatabasePaths();
      final DatabaseFactory factory;
      if (Platform.isLinux || Platform.isWindows) {
        sqfliteFfiInit();
        factory = databaseFactoryFfi;
      } else {
        factory = mobile.databaseFactory;
      }
      database = await LocalDatabase.open(factory, workspace.databasePath);
      final repository = JobRepository(database);
      final recovered = await repository.recoverInterruptedAttempts();
      return AppRuntime._(
        workspace: workspace,
        jobs: repository,
        vault: vault ?? SecureCredentialVault(),
        media: UnavailableMediaPort(platform),
        recoveredAttempts: recovered,
      );
    } catch (error) {
      try {
        if (database != null) await database.close();
      } catch (_) {
        // Preserve the startup error and always attempt to release the lock.
      } finally {
        try {
          if (workspace != null) await workspace.close();
        } catch (_) {
          // Secondary cleanup failures never expose raw native exceptions.
        }
      }
      if (error is AppFailure) rethrow;
      throw const AppFailure(
        FailureCode.storageUnavailable,
        'The app could not open its private storage. Check permissions and available space.',
        retryable: true,
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await jobs.db.close();
    } finally {
      await workspace.close();
    }
  }
}
