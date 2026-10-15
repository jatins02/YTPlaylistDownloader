import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../data/enrichment_repository.dart';
import '../data/job_repository.dart';
import '../data/media_workspace.dart';
import '../domain/enrichment.dart';
import '../domain/failure.dart';
import '../domain/models.dart';
import '../platform/guarded_process.dart';
import 'native_metadata_tools.dart';
import 'providers.dart';
import 'provider_transport.dart';

final class EnrichmentPipeline {
  EnrichmentPipeline({
    required this.jobs,
    required this.files,
    required this.tools,
    required this.naming,
    required this.artwork,
  });
  final JobRepository jobs;
  final MediaWorkspace files;
  final NativeMetadataTools tools;
  final NamingProvider naming;
  final ArtworkProvider artwork;
  late final store = EnrichmentRepository(jobs);
  RequestScope? _network;
  void cancel() => _network?.cancel();

  Future<void> process(
    String jobId,
    ProcessScope scope,
    Future<void> Function(Directory) budget, {
    bool retry = false,
  }) async {
    final network = RequestScope(stopped: () => scope.cancelled);
    _network = network;
    final tickets = <EnrichmentTicket>[];
    final work = <String, Directory>{};
    final needNames = <String>{};
    try {
      final options = await store.options();
      final records = await store.records(jobId);
      for (final track in await jobs.listTracks(jobId)) {
        scope.check();
        if (track.phase != TrackPhase.ready) continue;
        final record = records[track.id];
        final nameNeeded =
            record == null ||
            record.naming == NamingState.pending ||
            (retry &&
                [
                  NamingState.failed,
                  NamingState.stale,
                ].contains(record.naming));
        var artNeeded =
            record == null ||
            [
              ArtworkState.pending,
              ArtworkState.stale,
            ].contains(record.artwork) ||
            (retry &&
                [
                  ArtworkState.failed,
                  ArtworkState.unavailable,
                ].contains(record.artwork));
        if (retry &&
            record != null &&
            record.artwork == ArtworkState.matched &&
            !record.artworkOverride) {
          final covers = (await store.pipeline.assets(jobId, trackId: track.id))
              .where(
                (a) =>
                    a.kind == AssetKind.artwork &&
                    a.id == record.artworkAssetId,
              )
              .toList();
          if (covers.length != 1 || !await files.matches(covers.single)) {
            artNeeded = true;
          }
        }
        if (!nameNeeded && !artNeeded) continue;
        final assets = await store.pipeline.assets(jobId, trackId: track.id);
        if (!await files.matches(
              assets.singleWhere((a) => a.kind == AssetKind.audio),
            ) ||
            !await files.matches(
              assets.singleWhere((a) => a.kind == AssetKind.preview),
            )) {
          throw const AppFailure(
            FailureCode.audioInvalid,
            'Prepared audio changed. Retry audio processing before naming.',
          );
        }
        final ticket = await store.begin(track.id, nameNeeded: nameNeeded);
        tickets.add(ticket);
        work[track.id] = await files.work(jobId, ticket.token.id);
        await budget(work[track.id]!);
        if (nameNeeded) needNames.add(track.id);
      }
      // Capacity is the Stage 3 ten-source gate. One schema response is validated
      // atomically by ID before any per-track suggestion is published.
      Map<String, NamingResult>? names;
      FailureCode? nameFailure;
      if (needNames.isNotEmpty) {
        try {
          names = await naming.name(
            tickets
                .where((t) => needNames.contains(t.input.trackId))
                .map((t) => t.input)
                .toList(),
            options,
            network,
          );
          if (names.length != needNames.length ||
              names.keys.toSet().difference(needNames).isNotEmpty) {
            names = null;
            throw const AppFailure(
              FailureCode.aiInvalidResponse,
              'Naming returned incomplete track identities.',
            );
          }
        } on AppFailure catch (error) {
          if (error.code == FailureCode.operationCancelled) rethrow;
          nameFailure = error.code;
        } catch (_) {
          nameFailure = FailureCode.aiUnavailable;
        }
      }
      for (final ticket in tickets) {
        scope.check();
        network.check();
        final directory = work[ticket.input.trackId]!;
        Future<void> monitor() => budget(directory);
        var canLookup = true;
        if (needNames.contains(ticket.input.trackId)) {
          canLookup = await store.naming(
            ticket,
            options,
            result: names?[ticket.input.trackId],
            failure: nameFailure,
          );
        }
        final track = await jobs.getTrack(ticket.input.trackId);
        final record = (await store.records(jobId))[track.id]!;
        if (canLookup && !record.artworkOverride) {
          await store.artworkStarted(ticket);
          try {
            if (track.metadata.needsReview || track.metadata.artists.isEmpty) {
              throw const AppFailure(
                FailureCode.artworkUncertain,
                'Resolve uncertain names before a cover can be matched.',
              );
            }
            var cached = await store.cached(track.metadata);
            if (cached != null) {
              final check = File('${directory.path}/cache-check.jpg');
              await check.create(exclusive: true);
              await check.writeAsBytes(cached.bytes, flush: true);
              try {
                final result = await tools.run(scope, directory, [
                  'verify-image',
                  check.path,
                ], monitor: monitor);
                if (result['sha256'] != cached.provenance['sha256']) {
                  throw const FormatException();
                }
              } on AppFailure catch (error) {
                if ([
                  FailureCode.operationCancelled,
                  FailureCode.processTimeout,
                  FailureCode.storageUnavailable,
                  FailureCode.limitExceeded,
                ].contains(error.code)) {
                  rethrow;
                }
                await store.evict(track.metadata);
                cached = null;
              } catch (_) {
                await store.evict(track.metadata);
                cached = null;
              }
            }
            Uint8List bytes;
            Map<String, Object?> provenance;
            if (cached != null) {
              bytes = cached.bytes;
              provenance = cached.provenance;
            } else {
              final download = await artwork.find(
                track.metadata,
                options,
                network,
              );
              scope.check();
              network.check();
              if (download.bytes.isEmpty ||
                  download.bytes.length > 5 * 1024 * 1024) {
                throw const AppFailure(
                  FailureCode.artworkInvalid,
                  'Artwork exceeded its byte limit.',
                );
              }
              final raw = File('${directory.path}/cover-source');
              await raw.create(exclusive: true);
              await raw.writeAsBytes(download.bytes, flush: true);
              final normalized = File('${directory.path}/cover-normalized.jpg');
              final verified = await tools.run(scope, directory, [
                'image',
                raw.path,
                normalized.path,
              ], monitor: monitor);
              bytes = await normalized.readAsBytes();
              if (bytes.length > EnrichmentRepository.cacheBytes ||
                  verified['bytes'] != bytes.length ||
                  verified['sha256'] != await files.digest(normalized.path)) {
                throw const AppFailure(
                  FailureCode.artworkInvalid,
                  'Artwork normalization failed verification.',
                );
              }
              provenance = {
                ...download.provenance,
                'sha256': verified['sha256'],
                'mime': 'image/jpeg',
                'width': verified['width'],
                'height': verified['height'],
              };
              await monitor();
              network.check();
              await store.cache(track.metadata, bytes, provenance);
            }
            final normalized = File('${directory.path}/cover-publish.jpg');
            await normalized.create(exclusive: true);
            await normalized.writeAsBytes(bytes, flush: true);
            await monitor();
            network.check();
            final asset = await files.stage(
              normalized,
              jobId,
              track.id,
              const Uuid().v4(),
              AssetKind.artwork,
            );
            final applied = await store.artwork(
              ticket,
              track.revision,
              asset: asset,
              provenance: provenance,
            );
            if (applied) {
              final updated = await jobs.getTrack(track.id);
              if (artworkKey(updated.metadata) != artworkKey(track.metadata)) {
                network.check();
                await store.cache(updated.metadata, bytes, provenance);
              }
            }
          } on AppFailure catch (error) {
            if ([
              FailureCode.operationCancelled,
              FailureCode.conflict,
              FailureCode.storageUnavailable,
              FailureCode.limitExceeded,
              FailureCode.toolUnavailable,
            ].contains(error.code)) {
              rethrow;
            }
            await store.artwork(
              ticket,
              track.revision,
              failure:
                  [
                    FailureCode.artworkUncertain,
                    FailureCode.artworkInvalid,
                    FailureCode.artworkUnavailable,
                  ].contains(error.code)
                  ? error.code
                  : FailureCode.artworkUnavailable,
            );
          } catch (_) {
            await store.artwork(
              ticket,
              track.revision,
              failure: FailureCode.artworkInvalid,
            );
          }
        } else if (!record.artworkOverride) {
          await store.artwork(
            ticket,
            track.revision,
            failure: FailureCode.artworkUncertain,
          );
        }
        scope.check();
        await store.finish(ticket);
      }
    } finally {
      network.cancel();
      _network = null;
    }
  }
}
