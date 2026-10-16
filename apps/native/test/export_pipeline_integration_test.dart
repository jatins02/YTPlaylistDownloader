import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yt_playlist_downloader/data/export_repository.dart';
import 'package:yt_playlist_downloader/data/export_workspace.dart';
import 'package:yt_playlist_downloader/data/pipeline_repository.dart';
import 'package:yt_playlist_downloader/data/review_repository.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/review.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/metadata/native_metadata_tools.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';
import 'package:yt_playlist_downloader/platform/native_export_tools.dart';

import 'enrichment_pipeline_integration_test.dart'
    show FixtureNaming, FixtureArtwork;
import 'export_test_support.dart';
import 'test_support.dart';

void main() {
  final manifest = Platform.environment['STAGE3_TEST_RUNTIME'];
  if (manifest == null || !Platform.isLinux) return;
  late Fixture fixture;
  late DesktopTools tools;
  late DesktopMediaPort media;
  late TestExportDestination destination;
  late Uint8List image;
  late JobRecord review;
  setUp(() async {
    fixture = await Fixture.open();
    tools = await DesktopTools.load(
      File(manifest),
      File('assets/process_guard.py').absolute.path,
    );
    final scope = tools.scope();
    try {
      await scope.run(tools.python, [
        '-I',
        '-c',
        'from PIL import Image;Image.new("RGB",(32,32),"#f5d6e0").save("fixture.png")',
      ], directory: fixture.root);
    } finally {
      scope.cancel();
    }
    image = await File('${fixture.root.path}/fixture.png').readAsBytes();
    destination = TestExportDestination();
    media = DesktopMediaPort(
      jobs: fixture.jobs,
      workspace: fixture.workspace,
      tools: tools,
      source: ExportTestSource(tools),
      vault: MemoryVault(),
      namingProvider: FixtureNaming(),
      artworkProvider: FixtureArtwork(image),
      metadataTools: NativeMetadataTools(
        tools,
        File('assets/metadata_tools.py').absolute.path,
      ),
      exportTools: NativeExportTools(
        tools,
        File('assets/export_tools.py').absolute.path,
      ),
      exportDestination: destination,
    );
    await media.initialize();
    expect((await media.capabilities()).canExport, isTrue);
    review = await prepareExportReview(fixture.jobs, media, image);
  });
  tearDown(() async {
    await media.close();
    await fixture.close();
  });
  Matcher failure(FailureCode code) =>
      isA<AppFailure>().having((e) => e.code, 'code', code);
  test('embedded version titles match review and filenames even inside ordinary words', () async {
    final tracks = (await fixture.jobs.listTracks(review.id))
        .where((t) => ['abcdefghijk', '12345678901'].contains(t.videoId))
        .toList();
    for (var index = 0; index < tracks.length; index++) {
      final track = tracks[index];
      await fixture.jobs.editMetadata(
        trackId: track.id,
        revision: track.revision,
        candidate: SongMetadata(
          title: index == 0 ? 'Olive' : 'Delivery',
          artists: track.metadata.artists,
          version: 'Live',
        ),
        fields: {MetadataField.title, MetadataField.version},
      );
    }
    final current = await fixture.jobs.getJob(review.id);
    final publication = await media.prepareExport(review.id, current.revision);
    final paths = ExportWorkspace(media.files);
    final scope = tools.scope();
    try {
      for (final initial in tracks) {
        final track = await fixture.jobs.getTrack(initial.id);
        final file = publication.tracks.singleWhere(
          (f) => f.trackId == track.id,
        );
        expect(file.filename, contains(track.metadata.songTitle));
        final title = await scope.run(tools.python, [
          '-I',
          '-c',
          'import sys;from mutagen.id3 import ID3;print(str(ID3(sys.argv[1])["TIT2"]))',
          (await paths.file(publication, file)).path,
        ], directory: fixture.root);
        expect(title.trim(), track.metadata.songTitle);
      }
    } finally {
      scope.cancel();
    }
  });
  test(
    'retention keeps an open editor playable until Save or Cancel',
    () async {
      final track = (await fixture.jobs.listTracks(review.id)).first;
      final repository = ReviewRepository(fixture.jobs);
      final session = await repository.begin(track);
      final assets = await PipelineRepository(fixture.jobs).assets(review.id);
      await fixture.db.update(
        'jobs',
        {
          'created_at': DateTime.now()
              .toUtc()
              .subtract(const Duration(hours: 49))
              .millisecondsSinceEpoch,
        },
        where: 'id=?',
        whereArgs: [review.id],
      );
      await media.expireOldMedia();
      expect(
        (await fixture.jobs.getJob(review.id)).phase,
        JobPhase.reviewReady,
      );
      for (final asset in assets) {
        expect(await media.files.matches(asset), isTrue);
      }
      await media.saveReview(session, track.metadata, const CoverEdit.keep());
      await media.expireOldMedia();
      expect((await fixture.jobs.getJob(review.id)).phase, JobPhase.cancelled);
      expect(
        await Directory('${fixture.workspace.root.path}/jobs/${review.id}')
            .exists(),
        isFalse,
      );
    },
  );

  test('cancel a completed export fences a pending chooser and permits safe private discard', () async {
    final publication = await media.prepareExport(review.id, review.revision);
    destination.path = '${fixture.root.path}/Retained.mp3';
    await media.deliverExport(publication, publication.tracks.first.id);
    final savedPath = destination.path!;
    destination.pending = Completer<String?>();
    final saving = media.deliverExport(publication, publication.archive.id);
    while (destination.calls < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await media.cancel(review.id);
    expect(await saving, isNull);
    expect((await fixture.jobs.getJob(review.id)).phase, JobPhase.cancelled);
    destination.pending!.complete('${fixture.root.path}/Too late.zip');
    await media.discardPrivateMedia(review.id);
    expect(
      await media.files.digest(savedPath),
      publication.tracks.first.sha256,
    );
    expect(await File('${fixture.root.path}/Too late.zip').exists(), isFalse);
    expect(await media.currentExport(review.id), isNull);
  });
  test('real tagged full MP3s and ZIP preserve equal titles, human cover bytes and completed snapshot reuse', () async {
    final original = await PipelineRepository(fixture.jobs).assets(review.id);
    final prepared = await Future.wait([
      media.prepareExport(review.id, review.revision),
      media.prepareExport(review.id, review.revision),
    ]);
    final publication = prepared.first;
    expect(prepared.last.snapshot.id, publication.snapshot.id);
    expect(publication.tracks, hasLength(3));
    expect(publication.tracks.map((f) => f.filename).toSet(), hasLength(3));
    expect(publication.tracks.any((f) => f.filename.contains('(2)')), isTrue);
    expect(publication.tracks.any((f) => f.filename.contains('夜')), isTrue);
    final paths = ExportWorkspace(media.files);
    final first = publication.tracks[0], second = publication.tracks[1];
    final scope = tools.scope();
    try {
      final work = await media.files.work(review.id, const Uuid().v4());
      final measured = await media.codec.verify(
        await paths.file(publication, first),
        scope,
        work,
        () => media.budget(review.id, scope, work),
        mp3: true,
        expected: 65,
      );
      expect(measured.durationSeconds, greaterThan(64));
      final details = await scope.run(tools.python, [
        '-I',
        '-c',
        'import hashlib,json,sys;from mutagen.id3 import ID3;\n'
            'out=[]\n'
            'for p in sys.argv[1:]:\n t=ID3(p);b=open(p,"rb").read();out.append({"title":str(t["TIT2"]),"artist":str(t["TPE1"]),"features":str(t["TXXX:FEATURED_ARTISTS"]),"cover":hashlib.sha256(t.getall("APIC")[0].data).hexdigest() if t.getall("APIC") else None,"audio":hashlib.sha256(b[t.size:]).hexdigest()})\n'
            'print(json.dumps(out))',
        (await paths.file(publication, first)).path,
        (await paths.file(publication, second)).path,
      ], directory: work);
      final tags = jsonDecode(details) as List;
      expect(tags[0]['title'], 'Same full song (Live)');
      expect(tags[0]['artist'], 'Mira Vale');
      expect(tags[0]['features'], 'Jun Park');
      final cover = original.singleWhere(
        (a) => a.trackId == first.trackId && a.kind == AssetKind.artwork,
      );
      expect(tags[0]['cover'], cover.sha256);
      expect(tags[1]['cover'], isNull);
      expect(tags[0]['audio'], isNot(tags[1]['audio']));
      await work.delete(recursive: true);
    } finally {
      scope.cancel();
    }
    final ready = await fixture.jobs.getJob(review.id);
    expect(
      (await media.prepareExport(review.id, ready.revision)).json,
      publication.json,
    );
    expect(await fixture.db.query('exports'), hasLength(1));
    expect(
      (await PipelineRepository(fixture.jobs).assets(review.id))
          .map((a) => a.sha256),
      original.map((a) => a.sha256),
    );
  });
  test('actual external ZIP and MP3 transfer, chooser cancellation, no clobber and receipt recovery', () async {
    final publication = await media.prepareExport(review.id, review.revision);
    expect(
      await media.deliverExport(publication, publication.archive.id),
      isNull,
    );
    expect(await fixture.db.query('export_deliveries'), isEmpty);
    destination.path = '${fixture.root.path}/Chosen.zip';
    final receipt = await media.deliverExport(
      publication,
      publication.archive.id,
    );
    expect(receipt, isNotNull);
    expect(
      await media.files.digest(destination.path!),
      publication.archive.sha256,
    );
    await expectLater(
      media.deliverExport(publication, publication.archive.id),
      throwsA(failure(FailureCode.destinationExists)),
    );
    expect(
      await media.files.digest(destination.path!),
      publication.archive.sha256,
    );
    destination.path = '${fixture.root.path}/Chosen.mp3';
    final track = publication.tracks.first;
    expect(await media.deliverExport(publication, track.id), isNotNull);
    expect(await media.files.digest(destination.path!), track.sha256);
    expect(
      await Directory(fixture.root.path)
          .list()
          .where((f) => f.path.contains('.ytpd-'))
          .toList(),
      isEmpty,
    );
    await fixture.jobs.recoverInterruptedAttempts();
    expect(
      (await ExportRepository(fixture.jobs)
              .latestReceipt(publication.snapshot.id))!
          .fileId,
      track.id,
    );
    expect(
      (await media.currentExport(review.id))!.snapshot.id,
      publication.snapshot.id,
    );
    await fixture.db.update(
      'jobs',
      {
        'created_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 49))
            .millisecondsSinceEpoch,
      },
      where: 'id=?',
      whereArgs: [review.id],
    );
    await media.expireOldMedia();
    expect(
      (await fixture.jobs.getJob(review.id)).failure,
      FailureCode.expiredMedia,
    );
    expect(
      await Directory('${fixture.workspace.root.path}/jobs/${review.id}')
          .exists(),
      isFalse,
    );
    expect(await media.files.digest(destination.path!), track.sha256);
    expect(await File('${fixture.root.path}/Chosen.zip').exists(), isTrue);
  });
  test('corrupt published bytes are rejected before opening a chooser and a new review can rebuild', () async {
    final publication = await media.prepareExport(review.id, review.revision);
    final archive = await ExportWorkspace(media.files)
        .file(publication, publication.archive);
    await archive.writeAsBytes(List.filled(publication.archive.bytes, 0));
    await expectLater(
      media.deliverExport(publication, publication.archive.id),
      throwsA(failure(FailureCode.exportInvalid)),
    );
    expect(destination.calls, 0);
    final job = await fixture.jobs.getJob(review.id);
    await fixture.jobs.transition(job.id, job.revision, JobPhase.reviewReady);
    final current = await fixture.jobs.getJob(job.id);
    final rebuilt = await media.prepareExport(current.id, current.revision);
    expect(rebuilt.snapshot.id, isNot(publication.snapshot.id));
    expect(rebuilt.tracks, hasLength(3));
  });
  test('stop while the OS chooser is pending retains the verified publication and ignores late choices', () async {
    final publication = await media.prepareExport(review.id, review.revision);
    destination.pending = Completer<String?>();
    final saving = media.deliverExport(publication, publication.archive.id);
    await destination.entered.future;
    await media.stopExport(review.id);
    expect(await saving, isNull);
    destination.pending!.complete('${fixture.root.path}/too-late.zip');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await File('${fixture.root.path}/too-late.zip').exists(), isFalse);
    expect((await fixture.jobs.getJob(review.id)).phase, JobPhase.exportReady);
    expect(await fixture.db.query('export_deliveries'), isEmpty);
  });
  test('corrupt source audio fails publication and recheck plus explicit retry preserve human review', () async {
    final before = await fixture.jobs.listTracks(review.id);
    final first = before.firstWhere((t) => t.videoId == 'abcdefghijk');
    final audio = (await PipelineRepository(fixture.jobs).assets(
      review.id,
      trackId: first.id,
    )).singleWhere((a) => a.kind == AssetKind.audio);
    await (await media.files.file(audio)).writeAsBytes([1, 2, 3], flush: true);
    await expectLater(
      media.prepareExport(review.id, review.revision),
      throwsA(failure(FailureCode.tagInvalid)),
    );
    expect((await fixture.jobs.getJob(review.id)).phase, JobPhase.reviewReady);
    expect(await fixture.db.query('export_publications'), isEmpty);
    await PipelineRepository(fixture.jobs).retryFailedTracks(review.id);
    await media.acquire(
      playlist: PlaylistUrl.parse(review.sourceUrl),
      jobId: review.id,
    );
    final diagnosed = await fixture.jobs.getTrack(first.id);
    expect(diagnosed.phase, TrackPhase.failed);
    expect(diagnosed.failure, FailureCode.audioInvalid);
    await PipelineRepository(fixture.jobs).retryFailedTracks(review.id);
    await media.acquire(
      playlist: PlaylistUrl.parse(review.sourceUrl),
      jobId: review.id,
    );
    final repaired = await fixture.jobs.getTrack(first.id);
    expect(repaired.phase, TrackPhase.ready);
    expect(repaired.metadata.title, first.metadata.title);
    expect(repaired.metadata.featuredArtists, first.metadata.featuredArtists);
    final current = await fixture.jobs.getJob(review.id);
    expect(
      (await media.prepareExport(review.id, current.revision)).tracks,
      hasLength(3),
    );
  });
  test('stop during actual preparation fences publication and preserves retryable review', () async {
    final saving = media.prepareExport(review.id, review.revision);
    while ((await fixture.jobs.getJob(review.id)).phase != JobPhase.exporting) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final outcome = expectLater(saving, throwsA(isA<AppFailure>()));
    await media.stopExport(review.id);
    await outcome;
    expect((await fixture.jobs.getJob(review.id)).phase, JobPhase.reviewReady);
    expect(await fixture.db.query('export_publications'), isEmpty);
    final current = await fixture.jobs.getJob(review.id);
    expect(
      (await media.prepareExport(review.id, current.revision)).tracks,
      hasLength(3),
    );
  });
}
