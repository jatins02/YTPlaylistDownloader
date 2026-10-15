"""Regression cases found in the Stage 0/1 code review; no live providers."""
import json
import shutil
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from stage0.core import CheckError, build_archive, checksum, command, probe_and_decode
from stage0.providers import ArtworkClient, format_with_groq, naming_inputs, upload_and_verify


class ReviewRegressions(unittest.TestCase):
    def test_optional_providers_are_not_required_for_core_media(self):
        from stage0.__main__ import MODULES, require_runtime
        state = {'packages': {name: 'fixture' for name in MODULES},
                 'tools': {name: {'available': True} for name in ['ffmpeg', 'ffprobe', 'deno']}}
        for name in ['boto3', 'groq', 'requests']:
            state['packages'][name] = None
        with patch('stage0.__main__.preflight', return_value=state):
            self.assertIs(require_runtime(True), state)
            with self.assertRaises(CheckError):
                require_runtime(True, with_storage=True)
    def test_fast_tool_output_is_rejected_instead_of_silently_truncated(self):
        with self.assertRaises(CheckError) as raised:
            command([sys.executable, '-c', 'import sys; sys.stdout.buffer.write(b"x" * (3 * 1024 * 1024))'])
        self.assertEqual(raised.exception.code, 'TOOL_OUTPUT_LIMIT')

    def test_nonfinite_duration_is_not_valid_audio(self):
        for duration in ['NaN', 'Infinity', '-Infinity']:
            with self.subTest(duration=duration), patch('stage0.core.command', return_value=json.dumps({'format': {'duration': duration}}).encode()):
                with self.assertRaises(CheckError):
                    probe_and_decode(Path('fixture.mp3'), 'ffmpeg', 'ffprobe')

    def test_duplicate_empty_playlist_parameters_are_rejected(self):
        from stage0.core import canonical_playlist
        with self.assertRaises(CheckError):
            canonical_playlist('https://youtube.com/playlist?list=PL1234567890&list=')

    def test_archive_publication_has_a_scratch_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'export').mkdir()
            path = root / 'export/song.mp3'
            path.write_bytes(b'x' * 2048)
            records = [{'filename': path.name, 'sha256': checksum(path), 'source_mode': 'synthetic'}]
            with self.assertRaises(CheckError):
                build_archive(root, records, max_bytes=3000)
            self.assertFalse((root / 'playlist.zip').exists())

    def test_ambiguous_unknown_album_does_not_choose_the_first_release(self):
        client = ArtworkClient.__new__(ArtworkClient)
        recording = {'id': '11111111-1111-4111-8111-111111111111', 'title': 'Moonlit Train',
                     'artist-credit': [{'artist': {'name': 'Mira Vale'}}]}
        responses = [ {'count': 1, 'recordings': [recording]}, {**recording, 'releases': [
            {'id': '22222222-2222-4222-8222-222222222222', 'title': 'Original album'},
            {'id': 'release-b', 'title': 'Compilation'}]},
            {'images': [{'front': True, 'approved': True, 'image': 'https://archive.org/image.jpg'}]} ]
        with patch.object(client, 'json', side_effect=responses), patch.object(client, 'fetch', return_value=b'image'), patch('stage0.providers.normalize_image', return_value=b'cover'):
            with self.assertRaises(CheckError) as raised:
                client.lookup('Moonlit Train', ['Mira Vale'])
        self.assertEqual(raised.exception.code, 'ARTWORK_MATCH_UNCERTAIN')

    def test_cover_matching_includes_known_featured_artist_credits(self):
        client = ArtworkClient.__new__(ArtworkClient)
        recording = {'id': '11111111-1111-4111-8111-111111111111', 'title': 'Moonlit Train', 'artist-credit': [
            {'artist': {'name': 'Mira Vale'}}, {'artist': {'name': 'Jun Park'}}]}
        responses = [{'count': 1, 'recordings': [recording]}, {**recording, 'releases': [{'id': '22222222-2222-4222-8222-222222222222', 'title': 'Known album'}]},
                     {'images': [{'front': True, 'approved': True, 'image': 'https://archive.org/image.jpg'}]}]
        with patch.object(client, 'json', side_effect=responses), patch.object(client, 'fetch', return_value=b'image'), patch('stage0.providers.normalize_image', return_value=b'cover'):
            image, provenance = client.lookup('Moonlit Train', ['Mira Vale'], 'Known album', featured_artists=['Jun Park'])
        self.assertEqual(image, b'cover')
        self.assertEqual(provenance['matched_artists'], ['Mira Vale', 'Jun Park'])

    def test_ai_inputs_are_bounded_before_any_request(self):
        with patch.dict('os.environ', {'GROQ_API_KEY': 'synthetic-test-key'}), patch('groq.Groq') as provider:
            with self.assertRaises(CheckError):
                format_with_groq([{'track_id': 'a', 'title': 'x' * 501}])
            provider.assert_not_called()

    def test_ai_input_allowlist_excludes_private_report_fields(self):
        result = naming_inputs([{'track_id': 'a', 'title': 'Song', 'duration': 42,
                                'uploader': 'Artist', 'cookies': 'PRIVATE',
                                'signed_url': 'PRIVATE', 'api_key': 'PRIVATE'}])
        self.assertEqual(result, [{'track_id': 'a', 'title': 'Song', 'uploader': 'Artist', 'duration': 42}])

    def test_archive_race_never_overwrites_an_existing_winner(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'export').mkdir()
            path = root / 'export/song.mp3'
            path.write_bytes(b'audio')
            original_link = os.link
            def racing_link(source, destination):
                Path(destination).write_bytes(b'concurrent winner')
                original_link(source, destination)
            records = [{'filename': path.name, 'sha256': checksum(path), 'source_mode': 'synthetic'}]
            with patch('stage0.core.os.link', side_effect=racing_link), self.assertRaises(CheckError):
                build_archive(root, records)
            self.assertEqual((root / 'playlist.zip').read_bytes(), b'concurrent winner')
            self.assertFalse(list(root.glob('*.partial')))

    def test_private_link_write_failure_rolls_back_only_this_run(self):
        from unittest.mock import MagicMock
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / 'song.mp3'
            artifact.write_bytes(b'audio')
            # Exclusive local publication fails; never replace an existing link file.
            (root / 'device-links.private.json').write_text('existing private links')
            client = MagicMock()
            client.generate_presigned_url.return_value = 'https://storage.example/song.mp3?signature=fixture'
            anonymous = MagicMock()
            anonymous.__enter__.return_value = SimpleNamespace(status_code=403)
            signed = MagicMock()
            signed.__enter__.return_value = SimpleNamespace(status_code=200, headers={'Content-Disposition': 'attachment'}, iter_content=lambda _: [b'audio'])
            environment = {'S3_ENDPOINT_URL': 'https://storage.example', 'S3_BUCKET': 'fixture',
                           'AWS_ACCESS_KEY_ID': 'fixture', 'AWS_SECRET_ACCESS_KEY': 'fixture'}
            with patch.dict('os.environ', environment), patch('boto3.client', return_value=client), patch('requests.get', side_effect=[anonymous, signed]):
                with self.assertRaises(FileExistsError):
                    upload_and_verify([artifact], 'a' * 32, root)
            client.delete_object.assert_called_once_with(Bucket='fixture', Key='stage0/' + 'a' * 32 + '/song.mp3')
            client.close.assert_called_once()
            self.assertEqual((root / 'device-links.private.json').read_text(), 'existing private links')

    def test_streaming_artwork_deadline_and_size_use_bounded_reads(self):
        from unittest.mock import MagicMock
        client = ArtworkClient.__new__(ArtworkClient)
        client.session = MagicMock()
        client.requests = client.received_bytes = 0
        client.last_musicbrainz = 0
        response = MagicMock()
        response.status_code = 200
        response.raw.read1.side_effect = [b'1234', b'5678']
        client.session.get.return_value.__enter__.return_value = response
        with patch('stage0.providers.validate_artwork_url'), patch('stage0.providers.time.monotonic', return_value=0):
            with self.assertRaises(CheckError) as raised:
                client.fetch('https://archive.org/fixture.jpg', limit=5)
        self.assertEqual(raised.exception.code, 'ARTWORK_SIZE_LIMIT')
        response.raw.read1.assert_called_with(65536, decode_content=True)
        with patch('stage0.providers.validate_artwork_url'), patch('stage0.providers.time.monotonic', side_effect=[0, 0, 46]):
            with self.assertRaises(CheckError) as raised:
                client.fetch('https://archive.org/fixture.jpg')
        self.assertEqual(raised.exception.code, 'ARTWORK_TIMEOUT')

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'Real FFmpeg/ffprobe required')
    def test_partially_corrupt_audio_is_rejected_even_when_ffmpeg_recovers(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'tone.mp3'
            command([shutil.which('ffmpeg'), '-v', 'error', '-f', 'lavfi', '-i',
                     'sine=frequency=440:duration=2', '-c:a', 'libmp3lame', '-b:a', '128k', str(path)])
            data = bytearray(path.read_bytes())
            middle = len(data) // 2
            data[middle:middle + 1500] = b'\x00' * 1500
            path.write_bytes(data)
            with self.assertRaises(CheckError):
                probe_and_decode(path, shutil.which('ffmpeg'), shutil.which('ffprobe'))

    def test_cpu_metrics_exclude_previous_work_in_the_same_cli_process(self):
        from unittest.mock import MagicMock
        from stage0.__main__ import Metrics
        process = MagicMock()
        process.pid = 123
        process.create_time.return_value = 1
        process.cpu_times.side_effect = [SimpleNamespace(user=100, system=5), SimpleNamespace(user=102, system=5)]
        process.memory_info.return_value = SimpleNamespace(rss=1024)
        process.children.return_value = []
        with tempfile.TemporaryDirectory() as directory, patch('psutil.Process', return_value=process), patch('stage0.__main__.threading.Thread'):
            metrics = Metrics(Path(directory))
            with patch.object(metrics.stop, 'wait', side_effect=lambda _: metrics.stop.set()):
                metrics.sample()
            self.assertEqual(metrics.finish()['sampled_process_tree_cpu_seconds'], 2)

    def test_valid_ai_response_uses_scoped_client_and_redacted_inputs(self):
        from unittest.mock import MagicMock
        metadata = {'track_id': 'a', 'title': 'Moonlit Train', 'artists': ['Mira Vale'],
                    'featured_artists': [], 'album': None, 'version': None, 'needs_review': False, 'reason': None}
        client = MagicMock()
        client.chat.completions.create.return_value = SimpleNamespace(
            choices=[SimpleNamespace(finish_reason='stop', message=SimpleNamespace(content=json.dumps({'tracks': [metadata]})))], usage=None)
        with patch.dict('os.environ', {'GROQ_API_KEY': 'synthetic-test-key'}), patch('groq.Groq') as provider:
            provider.return_value.__enter__.return_value = client
            result, _ = format_with_groq([{'track_id': 'a', 'title': 'Source title', 'cookies': 'PRIVATE_VALUE'}])
            payload = client.chat.completions.create.call_args.kwargs['messages'][1]['content']
            self.assertNotIn('PRIVATE_VALUE', payload)
            self.assertEqual(result['a']['title'], 'Moonlit Train')
            provider.return_value.__exit__.assert_called_once()


if __name__ == '__main__':
    unittest.main()
