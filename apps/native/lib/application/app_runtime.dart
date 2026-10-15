import 'dart:io';

import 'package:flutter/services.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/job_repository.dart';
import '../data/enrichment_repository.dart';
import '../data/local_database.dart';
import '../data/private_workspace.dart';
import '../domain/failure.dart';
import '../platform/credential_vault.dart';
import '../platform/media_port.dart';
import '../platform/desktop_media_port.dart';
import '../platform/desktop_tools.dart';
import '../metadata/native_metadata_tools.dart';
import '../metadata/provider_transport.dart';
import '../platform/playlist_source.dart';

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
    File? mediaManifest,
    PlaylistSource? source,
    ProviderTransport? metadataTransport,
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
      final credentialVault = vault ?? SecureCredentialVault();
      final repository = JobRepository(database);
      final recovered = await repository.recoverInterruptedAttempts();
      await EnrichmentRepository(repository).pruneCache();
      MediaPort media = UnavailableMediaPort(platform);
      if (platform == DevicePlatform.linux) {
        final manifest =
            mediaManifest ??
            File(
              Platform.environment['YTPD_MEDIA_RUNTIME'] ??
                  p.join(workspace.root.path, 'media-runtime.json'),
            );
        if (await manifest.exists()) {
          try {
            final guardBytes = await rootBundle.load('assets/process_guard.py');
            final guard = await workspace.installProcessGuard(
              guardBytes.buffer.asUint8List(
                guardBytes.offsetInBytes,
                guardBytes.lengthInBytes,
              ),
            );
            final tools = await DesktopTools.load(manifest, guard.path);
            final helperBytes = await rootBundle.load(
              'assets/metadata_tools.py',
            );
            final helper = await workspace.installTool(
              'metadata_tools.py',
              helperBytes.buffer.asUint8List(
                helperBytes.offsetInBytes,
                helperBytes.lengthInBytes,
              ),
            );
            final desktop = DesktopMediaPort(
              jobs: repository,
              workspace: workspace,
              tools: tools,
              metadataTools: NativeMetadataTools(tools, helper.path),
              vault: credentialVault,
              source: source,
              metadataTransport: metadataTransport,
            );
            await desktop.initialize();
            media = desktop;
          } on AppFailure {
            // Drafts and secure settings remain usable after a bad local runtime.
            media = UnavailableMediaPort(platform);
          } on FileSystemException {
            // A media-directory failure must not disable durable drafts/settings.
            media = UnavailableMediaPort(platform);
          }
        }
      }
      return AppRuntime._(
        workspace: workspace,
        jobs: repository,
        vault: credentialVault,
        media: media,
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
      if (media is ManagedMediaPort) await (media as ManagedMediaPort).close();
    } finally {
      try {
        await jobs.db.close();
      } finally {
        await workspace.close();
      }
    }
  }
}
