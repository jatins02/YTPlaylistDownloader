import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/domain/models.dart';
import 'package:yt_playlist_downloader/domain/playlist_url.dart';
import 'package:yt_playlist_downloader/platform/desktop_media_port.dart';
import 'package:yt_playlist_downloader/platform/desktop_tools.dart';

import 'test_support.dart';

/// Separate explicit live opt-in. Never reads .env or requests AI/artwork.
void main() {
  final playlist = Platform.environment['STAGE7_LIVE_PLAYLIST'];
  final manifest = Platform.environment['STAGE3_TEST_RUNTIME'];
  final output = Platform.environment['STAGE7_QA_OUTPUT'];
  if (!Platform.isLinux ||
      playlist == null ||
      manifest == null ||
      output == null) {
    return;
  }
  test('opt-in small public playlist source smoke', () async {
    final url = PlaylistUrl.parse(playlist);
    final f = await Fixture.open();
    DesktopMediaPort? media;
    try {
      final tools = await DesktopTools.load(
        File(manifest),
        File('assets/process_guard.py').absolute.path,
      );
      media = DesktopMediaPort(
        jobs: f.jobs,
        workspace: f.workspace,
        tools: tools,
      );
      await media.initialize();
      final job = await f.jobs.createDraft(url);
      final elapsed = Stopwatch()..start();
      await media.acquire(playlist: url, jobId: job.id);
      elapsed.stop();
      final tracks = await f.jobs.listTracks(job.id);
      final ready = tracks.where((t) => t.phase == TrackPhase.ready).length;
      final unavailable = (await f.jobs.listEntries(job.id))
          .where((e) => e.trackId == null)
          .length;
      final passed =
          tracks.isNotEmpty && ready == tracks.length && unavailable == 0;
      final report = File('$output/source-smoke.json');
      await report.parent.create(recursive: true);
      await report.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({'schema': 1, 'platform': 'linux-x64', 'mode': 'explicit-live-source-only', 'success': passed, 'tracks': tracks.length, 'ready': ready, 'unavailable_entries': unavailable, 'elapsed_seconds': elapsed.elapsedMilliseconds / 1000, 'limitations': 'No naming, artwork, physical playback, destination panel or phone proof'})}\n',
      );
      expect(
        passed,
        isTrue,
        reason: 'Inspect visible source failures; partial peers remain recoverable.',
      );
    } finally {
      await media?.close();
      await f.close();
    }
  }, timeout: const Timeout(Duration(minutes: 21)));
}
