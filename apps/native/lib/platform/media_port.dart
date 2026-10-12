import '../domain/failure.dart';
import '../domain/models.dart';
import '../domain/playlist_url.dart';

enum DevicePlatform { android, ios, linux, windows, macos, unknown }

final class MediaCapabilities {
  const MediaCapabilities({
    required this.platform,
    this.canAcquire = false,
    this.canConvert = false,
    this.canTag = false,
    this.canExport = false,
  });
  final DevicePlatform platform;
  final bool canAcquire;
  final bool canConvert;
  final bool canTag;
  final bool canExport;
}

/// Platform adapters receive identities and private paths, never title-based keys.
abstract interface class MediaPort {
  Future<MediaCapabilities> capabilities();
  Future<void> acquire({required PlaylistUrl playlist, required String jobId});
  Future<void> cancel(String jobId);
  Future<void> export(ExportSnapshot snapshot);
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
