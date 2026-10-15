import 'dart:typed_data';

import '../domain/failure.dart';
import '../domain/enrichment.dart';
import '../domain/models.dart';
import '../domain/playlist_url.dart';

enum DevicePlatform { android, ios, linux, windows, macos, unknown }

final class MediaCapabilities {
  const MediaCapabilities({
    required this.platform,
    this.canAcquire = false,
    this.canConvert = false,
    this.canPrepareSnippets = false,
    this.canTag = false,
    this.canEnrich = false,
    this.canExport = false,
  });
  final DevicePlatform platform;
  final bool canAcquire;
  final bool canConvert;
  final bool canPrepareSnippets;
  final bool canTag;
  final bool canEnrich;
  final bool canExport;
}

/// Platform adapters receive identities and private paths, never title-based keys.
abstract interface class MediaPort {
  Future<MediaCapabilities> capabilities();
  Future<void> acquire({required PlaylistUrl playlist, required String jobId});
  Future<void> cancel(String jobId);
  Future<void> export(ExportSnapshot snapshot);
}

abstract interface class ManagedMediaPort implements MediaPort {
  Future<void> close();
  Future<void> pause(String jobId);
  Future<void> discardPrivateMedia(String jobId);
}

/// Honest default until the corresponding Stage 0 device spike passes.
final class UnavailableMediaPort implements MediaPort {
  const UnavailableMediaPort(this.platform);
  final DevicePlatform platform;

  @override
  Future<MediaCapabilities> capabilities() async =>
      MediaCapabilities(platform: platform);
  @override
  Future<void> acquire({
    required PlaylistUrl playlist,
    required String jobId,
  }) async => _unavailable();
  @override
  Future<void> cancel(String jobId) async => _unavailable();
  @override
  Future<void> export(ExportSnapshot snapshot) async => _unavailable();
  Never _unavailable() => throw const AppFailure(
    FailureCode.mediaUnavailable,
    'Media processing is not available on this device yet. Your draft is saved.',
  );
}

abstract interface class EnrichingMediaPort implements MediaPort {
  Future<void> enrich(String jobId, {bool retry = true});
  Future<Uint8List?> coverBytes(String jobId, String assetId);
  Future<EnrichmentOptions> metadataOptions();
  Future<void> saveMetadataOptions(EnrichmentOptions options);
}
