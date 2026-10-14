"""Offline regressions for the review of implemented Stages 0–3."""
import json
import os
import struct
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from stage0.core import CheckError, allocate_filename, command, probe_and_decode
from stage0.providers import ArtworkClient, format_with_groq, naming_inputs


class CurrentReviewTests(unittest.TestCase):
    def test_source_temporary_and_runtime_cache_paths_stay_inside_scratch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = command([sys.executable, '-I', '-c',
                'import os,json;print(json.dumps([os.environ["TMPDIR"],os.environ["DENO_DIR"]]))'], scratch=root)
            self.assertEqual(json.loads(output), [str(root.resolve()), str(root.resolve() / '.deno-cache')])

    def test_ai_cannot_silently_strip_source_version_or_clip_markers(self):
        from types import SimpleNamespace
        from unittest.mock import MagicMock
        for version in ['Slowed + Reverb', 'Verse-only', 'Live', 'Remix', 'Sped up']:
            metadata = {'track_id': 'fixture', 'title': 'Moonlit Train', 'artists': ['Mira Vale'],
                'featured_artists': [], 'album': None, 'version': None, 'needs_review': False, 'reason': None}
            client = MagicMock()
            client.chat.completions.create.return_value = SimpleNamespace(
                choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps({'tracks': [metadata]})))], usage=None)
            source = 'Mira Vale - Moonlit Train (' + version + ')'
            with self.subTest(version=version), patch.dict(os.environ, {'GROQ_API_KEY': 'fictional-test-value'}), \
                 patch('groq.Groq') as provider:
                provider.return_value.__enter__.return_value = client
                records, _ = format_with_groq([{'track_id': 'fixture', 'title': source}])
                self.assertEqual(records['fixture']['title'], source)
                self.assertTrue(records['fixture']['needs_review'])
                self.assertEqual(records['fixture']['artists'], [])

    def test_short_track_snippet_starts_at_zero_and_stays_within_thirty_seconds(self):
        from stage0.__main__ import export_tracks, tool
        ffmpeg, ffprobe = tool('ffmpeg'), tool('ffprobe')
        if not ffmpeg or not ffprobe:
            self.skipTest('Real FFmpeg/ffprobe required')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ['source', 'export', 'previews']:
                (root / name).mkdir()
            source = root / 'source/fixture.mp3'
            command([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=330:duration=30',
                '-f', 'lavfi', '-i', 'sine=frequency=880:duration=15', '-filter_complex',
                '[0:a][1:a]concat=n=2:v=0:a=1', '-c:a', 'libmp3lame', str(source)])
            duration = probe_and_decode(source, ffmpeg, ffprobe)
            tracks = [{'track_id': 'fixture', 'video_id': 'fictional', 'duration': duration}]
            metadata = {'fixture': {'track_id': 'fixture', 'title': 'Fictional short track',
                'artists': ['Mira Vale'], 'featured_artists': [], 'album': None, 'version': None}}
            result = export_tracks(root, tracks, {'fixture': source}, metadata, {}, 'synthetic')
            self.assertLessEqual(result['tracks'][0]['preview_seconds'], 30)
            data = command([ffmpeg, '-v', 'error', '-i', str(root / 'previews/fixture.mp3'),
                '-t', '1', '-ar', '8000', '-ac', '1', '-f', 's16le', '-'])
            samples = [sample[0] for sample in struct.iter_unpack('<h', data)]
            crossings = sum((a < 0) != (b < 0) for a, b in zip(samples, samples[1:]))
            self.assertTrue(600 < crossings < 730, f'Expected opening 330 Hz tone; got {crossings} crossings')

    def test_media_children_do_not_inherit_provider_credentials(self):
        with patch.dict(os.environ, {'GROQ_API_KEY': 'fictional-test-value',
                                    'AWS_SECRET_ACCESS_KEY': 'fictional-test-value'}):
            result = command([sys.executable, '-I', '-c',
                'import os;print("GROQ_API_KEY" in os.environ,"AWS_SECRET_ACCESS_KEY" in os.environ)'])
        self.assertEqual(result.strip(), b'False False')

    @unittest.skipIf(os.name == 'nt', 'POSIX process groups; Windows remains unverified')
    def test_successful_cli_command_stops_lingering_descendant_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / 'late-write'
            child = 'import time;from pathlib import Path;time.sleep(.3);Path(sys.argv[1]).write_text("late")'
            child = 'import sys;' + child
            parent = 'import subprocess,sys;subprocess.Popen([sys.executable,"-c",sys.argv[1],sys.argv[2]]);print("done")'
            self.assertEqual(command([sys.executable, '-c', parent, child, str(marker)]).strip(), b'done')
            time.sleep(.5)
            self.assertFalse(marker.exists())

    def test_small_filename_budgets_fail_instead_of_looping_or_breaking_the_cap(self):
        metadata = {'track_id': 'fixture', 'title': '夜' * 100, 'artists': [], 'featured_artists': []}
        for budget in [0, 4, 10, -1, True, 256]:
            with self.subTest(budget=budget), self.assertRaises(CheckError):
                allocate_filename(metadata, set(), budget)
        used = set()
        names = [allocate_filename(metadata, used, 32) for _ in range(3)]
        self.assertEqual(len(set(names)), 3)
        self.assertTrue(all(len(name.encode('utf-8')) <= 32 for name in names))

    def test_known_album_does_not_guess_between_matching_release_editions(self):
        client = ArtworkClient.__new__(ArtworkClient)
        responses = [{'recordings': [{'id': 'fixture', 'title': 'Moonlit Train',
            'artist-credit': [{'artist': {'name': 'Mira Vale'}}]}]},
            {'releases': [{'id': 'edition-a', 'title': 'Known album'},
                          {'id': 'edition-b', 'title': 'Known album'}]}]
        with patch.object(client, 'json', side_effect=responses), patch.object(client, 'fetch') as fetch:
            with self.assertRaises(CheckError) as raised:
                client.lookup('Moonlit Train', ['Mira Vale'], 'Known album')
            self.assertEqual(raised.exception.code, 'ARTWORK_MATCH_UNCERTAIN')
            fetch.assert_not_called()

    def test_control_characters_are_rejected_before_naming_requests(self):
        for record in [{'track_id': 'fixture', 'title': 'Source\x00title'},
                       {'track_id': 'fixture', 'title': 'Source', 'uploader': 'Channel\nheader'}]:
            with self.subTest(record=record), self.assertRaises(CheckError):
                naming_inputs([record])

    def test_metadata_check_requires_original_source_records(self):
        from stage0.__main__ import main
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / 'report.json'
            report.write_text(json.dumps({'checks': [{'name': 'tagged_export', 'status': 'passed',
                'evidence': {'tracks': [{'track_id': 'fixture', 'duration_seconds': 3,
                                        'metadata': {'title': 'Human edited title'}}]}}]}))
            with patch('sys.argv', ['stage0', 'metadata-check', '--report', str(report)]), \
                 patch('stage0.__main__.load_project_environment'), \
                 patch('stage0.providers.format_with_groq') as provider, \
                 patch('sys.stderr'):
                self.assertEqual(main(), 1)
                provider.assert_not_called()


if __name__ == '__main__':
    unittest.main()
