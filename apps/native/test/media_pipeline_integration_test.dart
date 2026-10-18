import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/media_workspace.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/data/review_repository.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/media_models.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/platform/guarded_process.dart';
import 'package:yt_playlist_downloader/platform/playlist_source.dart';

import '../tool/media_smoke.dart' show SyntheticPlaylistSource;
import 'test_support.dart';

/// Opt in with STAGE3_TEST_RUNTIME. These tests execute real pinned codecs and
/// native process supervision; the source boundary uses generated audio only.
void main() {
  final manifest = Platform.environment['STAGE3_TEST_RUNTIME'];
  if (manifest == null || !Platform.isLinux) return;
  late Fixture fixture;
  late DesktopTools tools;
  late DesktopMediaPort media;
  late CountingSource source;
  setUp(() async {
    fixture = await Fixture.open();
    tools = await DesktopTools.load(
      File(manifest),
      File('assets/process_guard.py').absolute.path,
    );
    source = CountingSource(SyntheticPlaylistSource(tools));
    media = DesktopMediaPort(
      jobs: fixture.jobs,
      workspace: fixture.workspace,
      tools: tools,
      source: source,
    );
    await media.initialize();
  });
  tearDown(() async {
    await media.close();
    await fixture.close();
  });
  Future<JobRecord> draft() => fixture.jobs.createDraft(
    PlaylistUrl.parse('https://youtube.com/playlist?list=PLsyntheticNative01'),
  );
  Future<void> run(JobRecord job) =>
      media.acquire(playlist: PlaylistUrl.parse(job.sourceUrl), jobId: job.id);

  test('one source exceeding its enforced file cap stays excludable without blocking playable peers', () async {
    final job = await draft();
    source.fileCappedVideo = '12345678901';
    await run(job);
    expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.reviewReady);
    final tracks = await fixture.jobs.listTracks(job.id);
    final failed = tracks.singleWhere(
      (track) => track.videoId == source.fileCappedVideo,
    );
    expect(failed.phase, TrackPhase.failed);
    expect(failed.failure, FailureCode.limitExceeded);
    expect(
      tracks.where((track) => track.phase == TrackPhase.ready),
      hasLength(2),
    );
    await ReviewRepository(fixture.jobs).selectTrack(failed, false);
    expect((await fixture.jobs.getTrack(failed.id)).selected, isFalse);
    expect(source.enumerations, 1);
    expect(
      await Directory('${fixture.workspace.root.path}/jobs/${job.id}/.work')
          .exists(),
      isFalse,
    );
  });

  test('real codecs preserve equal-title bytes, Unicode, duplicates and partial failures', () async {
    final job = await draft();
    await run(job);
    final snapshot = await fixture.jobs.processingSnapshot(job.id);
    expect(snapshot.$1.phase, JobPhase.reviewReady);
    expect(snapshot.$2, hasLength(4));
    expect(snapshot.$3, hasLength(6));
    expect(snapshot.$2.where((t) => t.phase == TrackPhase.ready), hasLength(3));
    expect(source.downloads['abcdefghijk'], 1);
    final assets = await PipelineRepository(fixture.jobs).assets(job.id);
    final audio = assets.where((a) => a.kind == AssetKind.audio).toList();
    expect(audio.map((a) => a.sha256).toSet(), hasLength(3));
    final first = snapshot.$2[0], second = snapshot.$2[1];
    expect(first.metadata.title, second.metadata.title);
    expect(first.id, isNot(second.id));
    expect(
      await Directory('${fixture.workspace.root.path}/jobs/${job.id}/.work')
          .exists(),
      isFalse,
    );
  });

  test('pause blocks late source completion, then resume retains ready peers without reenumeration', () async {
    final gate = Completer<void>();
    source.blockVideo = '12345678901';
    source.gate = gate;
    final job = await draft();
    final task = run(job);
    await source.blocked.future.timeout(const Duration(seconds: 15));
    final before = await PipelineRepository(fixture.jobs).assets(job.id);
    expect(before.where((a) => a.kind == AssetKind.audio), hasLength(1));
    final pausing = media.pause(job.id);
    gate.complete();
    await pausing;
    await task;
    expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.queued);
    source.blockVideo = null;
    await run(await fixture.jobs.getJob(job.id));
    expect(source.enumerations, 1);
    expect(source.downloads['abcdefghijk'], 1);
    final after = await PipelineRepository(fixture.jobs).assets(job.id);
    for (final asset in before) {
      expect(
        after.any((a) => a.id == asset.id && a.sha256 == asset.sha256),
        isTrue,
      );
    }
  });

  test('converted checkpoint resumes without downloading or transcoding full audio again', () async {
    final job = await draft();
    var current = await fixture.jobs.transition(
      job.id,
      job.revision,
      JobPhase.queued,
    );
    current = await fixture.jobs.transition(
      job.id,
      current.revision,
      JobPhase.enumerating,
    );
    final store = PipelineRepository(fixture.jobs);
    final listing = await fixture.jobs.beginAttempt(
      jobId: job.id,
      stage: TaskStage.acquisition,
    );
    await store.commitEnumeration(listing, const [
      SourceEntry(
        position: 1,
        title: 'Checkpoint fixture',
        videoId: 'abcdefghijk',
        durationSeconds: 2.4,
      ),
    ], const PipelineLimits());
    current = await fixture.jobs.getJob(job.id);
    await fixture.jobs.transition(
      job.id,
      current.revision,
      JobPhase.processing,
    );
    final track = (await fixture.jobs.listTracks(job.id)).single;
    final token = await fixture.jobs.beginAttempt(
      jobId: job.id,
      trackId: track.id,
      stage: TaskStage.conversion,
    );
    final files = MediaWorkspace(fixture.workspace, const PipelineLimits());
    final work = await files.work(job.id, token.id);
    final scope = tools.scope();
    try {
      await store.trackPhase(token, TrackPhase.downloading);
      final input = await source.base.download(
        track.videoId,
        scope,
        work,
        const PipelineLimits(),
        () async {},
      );
      await media.codec.verify(input, scope, work, () async {});
      final raw = await files.stage(
        input,
        job.id,
        track.id,
        const Uuid().v4(),
        AssetKind.source,
      );
      await store.publish(token, raw, CheckpointStep.acquired);
      await store.trackPhase(token, TrackPhase.converting);
      final output = await media.codec.convert(
        await files.file(raw),
        scope,
        work,
        () async {},
      );
      await media.codec.verify(output, scope, work, () async {}, mp3: true);
      final audio = await files.stage(
        output,
        job.id,
        track.id,
        const Uuid().v4(),
        AssetKind.audio,
      );
      await store.publish(token, audio, CheckpointStep.converted);
      await store.stop(job.id);
      await run(await fixture.jobs.getJob(job.id));
      expect(source.enumerations, 0);
      expect(source.downloads, isEmpty);
      final retained = (await store.assets(
        job.id,
        trackId: track.id,
      )).singleWhere((a) => a.kind == AssetKind.audio);
      expect(retained.id, audio.id);
      expect(retained.sha256, audio.sha256);
      expect((await fixture.jobs.getTrack(track.id)).phase, TrackPhase.ready);
    } finally {
      scope.cancel();
    }
  });

  test('corrupt ready audio is flagged and an explicit retry replaces only the damaged track', () async {
    final job = await draft();
    await run(job);
    final store = PipelineRepository(fixture.jobs);
    final before = await store.assets(job.id);
    final corrupt = before.firstWhere((a) => a.kind == AssetKind.audio);
    await (await media.files.file(corrupt)).writeAsString('corrupt audio');
    await store.retryFailedTracks(job.id);
    await run(await fixture.jobs.getJob(job.id));
    expect(
      (await fixture.jobs.getTrack(corrupt.trackId!)).failure,
      FailureCode.audioInvalid,
    );
    await store.retryFailedTracks(job.id);
    await run(await fixture.jobs.getJob(job.id));
    final after = await store.assets(job.id);
    expect(after.any((a) => a.id == corrupt.id), isFalse);
    expect(
      (await store.assets(
        job.id,
        activeOnly: false,
      )).any((a) => a.id == corrupt.id),
      isTrue,
    );
    for (final asset in before.where(
      (a) => a.trackId != corrupt.trackId && a.kind == AssetKind.audio,
    )) {
      expect(
        after.any((a) => a.id == asset.id && a.sha256 == asset.sha256),
        isTrue,
      );
      final peer = await fixture.jobs.getTrack(asset.trackId!);
      expect(source.downloads[peer.videoId], 1);
    }
  });

  test('cancel fences a late source and removing private media cannot touch an external copy', () async {
    final gate = Completer<void>();
    source.blockVideo = '12345678901';
    source.gate = gate;
    final job = await draft();
    final task = run(job);
    await source.blocked.future.timeout(const Duration(seconds: 15));
    final asset = (await PipelineRepository(fixture.jobs).assets(job.id))
        .firstWhere((a) => a.kind == AssetKind.audio);
    final external = await (await media.files.file(asset))
        .copy('${fixture.root.path}/user-copy.mp3');
    final expectedLength = await external.length();
    final stopping = media.cancel(job.id);
    gate.complete();
    await stopping;
    await task;
    expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.cancelled);
    expect(
      (await fixture.jobs.listTracks(job.id))
          .where((t) => t.phase == TrackPhase.ready),
      hasLength(1),
    );
    await Future.wait([
      media.discardPrivateMedia(job.id),
      media.discardPrivateMedia(job.id),
    ]);
    final cleaned = await fixture.jobs.getJob(job.id);
    await media.discardPrivateMedia(job.id);
    expect((await fixture.jobs.getJob(job.id)).revision, cleaned.revision);
    expect(await PipelineRepository(fixture.jobs).assets(job.id), isEmpty);
    expect(await external.length(), expectedLength);
    expect(
      (await fixture.jobs.listTracks(job.id))
          .any((t) => t.phase == TrackPhase.ready),
      isFalse,
    );
  });

  test('expiry removes only private bytes, keeps source metadata and reports expiration', () async {
    final job = await draft();
    await run(job);
    await fixture.db.update(
      'jobs',
      {
        'created_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 49))
            .millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [job.id],
    );
    await media.expireOldMedia();
    final expired = await fixture.jobs.getJob(job.id);
    expect(expired.phase, JobPhase.cancelled);
    expect(expired.failure, FailureCode.expiredMedia);
    expect(await PipelineRepository(fixture.jobs).assets(job.id), isEmpty);
    expect(
      (await fixture.jobs.listTracks(job.id)).first.sourceTitle,
      'Equal fictional title',
    );
    final directory = Directory(
      '${fixture.workspace.root.path}/jobs/${job.id}',
    );
    expect(await directory.exists(), isFalse);
    await media.expireOldMedia();
    expect((await fixture.jobs.getJob(job.id)).revision, expired.revision);
    expect(await directory.exists(), isFalse);
  });

  test('unexpected source exceptions fence the job and keep completed peers resumable', () async {
    final job = await draft();
    source.throwVideo = '12345678901';
    await expectLater(
      run(job),
      throwsA(
        isA<AppFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.toolUnavailable,
        ),
      ),
    );
    final stopped = await fixture.jobs.processingSnapshot(job.id);
    expect(stopped.$1.phase, JobPhase.failed);
    expect(stopped.$2.first.phase, TrackPhase.ready);
    expect(stopped.$2[1].phase, TrackPhase.queued);
    expect(
      await fixture.db.query(
        'attempts',
        where: 'status = ?',
        whereArgs: ['running'],
      ),
      isEmpty,
    );
    source.throwVideo = null;
    await run(stopped.$1);
    expect(source.enumerations, 1);
    expect(source.downloads['abcdefghijk'], 1);
    expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.reviewReady);
  });

  test(
    'closing waits for queued private cleanup before storage can be released',
    () async {
      final job = await draft();
      await run(job);
      await media.cancel(job.id);
      final entered = Completer<void>(), release = Completer<void>();
      final lock = fixture.db.transaction((tx) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      var finished = false;
      final discard = media.discardPrivateMedia(job.id);
      final closing = media.close().then((_) {
        finished = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      release.complete();
      await lock;
      await Future.wait([discard, closing]);
      expect(finished, isTrue);
      expect(await PipelineRepository(fixture.jobs).assets(job.id), isEmpty);
      expect(
        await Directory('${fixture.workspace.root.path}/jobs/${job.id}')
            .exists(),
        isFalse,
      );
    },
  );

  test('cleanup and acquisition cannot race an expiration sweep', () async {
    final job = await draft();
    final cleanup = media.expireOldMedia();
    await expectLater(
      run(job),
      throwsA(
        isA<AppFailure>().having((e) => e.code, 'code', FailureCode.conflict),
      ),
    );
    await cleanup;
    expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.draft);
    await run(job);
    expect((await fixture.jobs.getJob(job.id)).phase, JobPhase.reviewReady);
  });

  test(
    'a retained but truncated snippet is retired and rebuilt on explicit retry',
    () async {
      final job = await draft();
      await run(job);
      final store = PipelineRepository(fixture.jobs);
      final before = await store.assets(job.id);
      final preview = before.firstWhere((a) => a.kind == AssetKind.preview);
      final full = before.singleWhere(
        (a) => a.trackId == preview.trackId && a.kind == AssetKind.audio,
      );
      final directory = await Directory('${fixture.root.path}/short-snippet')
          .create();
      final scope = tools.scope();
      try {
        final file = await media.files.file(preview);
        await file.delete();
        await scope.run(tools.ffmpeg, [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=0.1',
          '-c:a',
          'libmp3lame',
          file.path,
        ], directory: directory);
        await fixture.db.update(
          'assets',
          {
            'sha256': await media.files.digest(file.path),
            'bytes': await file.length(),
          },
          where: 'id = ?',
          whereArgs: [preview.id],
        );
        // Represent a pre-upgrade interrupted track with a hash-valid but short
        // preview; full audio is kept as the verified conversion boundary.
        await fixture.db.update(
          'tracks',
          {'phase': 'queued'},
          where: 'id = ?',
          whereArgs: [preview.trackId],
        );
        await store.retryFailedTracks(job.id);
        await run(await fixture.jobs.getJob(job.id));
        expect(
          (await fixture.jobs.getTrack(preview.trackId!)).failure,
          FailureCode.audioInvalid,
        );
        expect(
          (await store.assets(job.id)).any((a) => a.id == preview.id),
          isFalse,
        );
        await store.retryFailedTracks(job.id);
        await run(await fixture.jobs.getJob(job.id));
        expect(
          (await fixture.jobs.getTrack(preview.trackId!)).phase,
          TrackPhase.ready,
        );
        expect(
          (await store.assets(job.id)).any((a) => a.id == full.id),
          isTrue,
        );
        expect(source.downloads['abcdefghijk'], 1);
      } finally {
        scope.cancel();
      }
    },
  );
}

final class CountingSource implements PlaylistSource {
  CountingSource(this.base);
  final SyntheticPlaylistSource base;
  int enumerations = 0;
  final Map<String, int> downloads = {};
  String? blockVideo;
  String? throwVideo;
  String? fileCappedVideo;
  Completer<void>? gate;
  final blocked = Completer<void>();
  @override
  Future<List<SourceEntry>> enumerate(
    PlaylistUrl playlist,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) {
    enumerations++;
    return base.enumerate(playlist, scope, work, limits, monitor);
  }

  @override
  Future<File> download(
    String videoId,
    ProcessScope scope,
    Directory work,
    PipelineLimits limits,
    Future<void> Function() monitor,
  ) async {
    downloads.update(videoId, (n) => n + 1, ifAbsent: () => 1);
    if (videoId == throwVideo) throw StateError('Private provider diagnostic');
    if (videoId == fileCappedVideo) {
      await scope.run(
        base.tools.python,
        [
          '-c',
          'open("oversized.bin","wb").truncate(${limits.maxFileBytes + 1})',
        ],
        directory: work,
        monitor: monitor,
      );
    }
    if (videoId == blockVideo) {
      if (!blocked.isCompleted) blocked.complete();
      await gate!.future;
      scope.check();
    }
    return base.download(videoId, scope, work, limits, monitor);
  }
}
