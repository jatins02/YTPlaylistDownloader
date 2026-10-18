enum FailureCode {
  invalidPlaylist,
  invalidMetadata,
  invalidCredential,
  invalidPath,
  notFound,
  conflict,
  invalidTransition,
  storageUnavailable,
  storageBusy,
  corruptData,
  unsupportedPlatform,
  mediaUnavailable,
  limitExceeded,
  sourceUnavailable,
  processTimeout,
  operationCancelled,
  toolUnavailable,
  audioInvalid,
  liveUnsupported,
  expiredMedia,
  aiCredentialMissing,
  aiUnauthorized,
  aiModelUnavailable,
  aiRateLimited,
  aiInvalidResponse,
  aiUnavailable,
  artworkUncertain,
  artworkInvalid,
  artworkUnavailable,
  tagInvalid,
  exportInvalid,
  destinationUnavailable,
  destinationExists,
}

/// Only safe, user-facing messages cross adapter boundaries.
final class AppFailure implements Exception {
  const AppFailure(
    this.code,
    this.message, {
    this.retryable = false,
    this.fileLimit = false,
  }) : assert(!fileLimit || code == FailureCode.limitExceeded);

  final FailureCode code;
  final String message;
  final bool retryable;

  /// In-process distinction only; persisted errors retain the existing code.
  /// A single tool file can fail without treating it as a full-workspace quota.
  final bool fileLimit;

  @override
  String toString() => 'AppFailure(${code.name}): $message';
}
