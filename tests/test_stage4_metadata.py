"""Fictional real-image/ID3 readback tests; no provider or source requests."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from PIL import Image
from mutagen.id3 import ID3
from stage0.core import command

_HELPER = Path(__file__).resolve().parents[1] / 'apps/native/assets/metadata_tools.py'
_spec = importlib.util.spec_from_file_location('native_metadata_tools', _HELPER)
worker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(worker)


class Stage4MetadataTests(unittest.TestCase):
    def test_normalizes_verified_images_and_removes_private_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = Image.new('RGB', (1024, 800), '#f5d6e0')
            image.save(root / 'source.png')
            result = worker.normalize(root / 'source.png', root / 'cover.jpg')
            self.assertEqual(result['width'], 768)
            self.assertLessEqual(result['height'], 768)
            self.assertEqual(result['sha256'], worker.verify_image(root / 'cover.jpg')['sha256'])
            with Image.open(root / 'cover.jpg') as actual:
                self.assertEqual(actual.format, 'JPEG')
                self.assertFalse(actual.getexif())
            with self.assertRaises(FileExistsError):
                worker.normalize(root / 'source.png', root / 'cover.jpg')

    def test_rejects_truncated_animation_and_excessive_pixel_images(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bad = root / 'bad'
            for payload in [b'not an image', b'\x89PNG\r\n\x1a\n']:
                bad.write_bytes(payload)
                with self.assertRaises(Exception):
                    worker.normalize(bad, root / 'cover.jpg')
            Image.new('RGB', (4000, 2100)).save(bad, format='PNG')
            with self.assertRaises(Exception):
                worker.normalize(bad, root / 'cover.jpg')
            images = [Image.new('RGB', (2, 2), color) for color in ['red', 'blue']]
            images[0].save(bad, format='PNG', save_all=True, append_images=images[1:])
            with self.assertRaises(ValueError):
                worker.normalize(bad, root / 'cover.jpg')

    @unittest.skipUnless(shutil.which('ffmpeg'), 'Real codec required')
    def test_tags_new_derivative_and_reads_exact_cover_and_unicode_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source.mp3'
            command([shutil.which('ffmpeg'), '-v', 'error', '-f', 'lavfi', '-i',
                     'sine=frequency=440:duration=2', '-c:a', 'libmp3lame', str(source)])
            before = source.read_bytes()
            Image.new('RGB', (16, 16), '#f5d6e0').save(root / 'raw.png')
            cover = worker.normalize(root / 'raw.png', root / 'cover.jpg')
            request = {
                'metadata': {'title': '夜の歌', 'artists': ['Mira Vale', 'Jun Park'],
                             'featured_artists': ['Asha'], 'album': 'Fictional album',
                             'version': 'Live', 'needs_review': False},
                'track_id': 'fictional-track', 'track_revision': 9, 'video_id': 'abcdefghijk',
                'cover_path': str(root / 'cover.jpg'), 'cover_sha256': cover['sha256'],
                'snapshot_hash': 'a' * 64,
            }
            (root / 'request.json').write_text(json.dumps(request), encoding='utf-8')
            result = worker.tag(source, root / 'tagged.mp3', root / 'request.json')
            tags = ID3(root / 'tagged.mp3')
            self.assertEqual(str(tags['TIT2']), '夜の歌 (Live)')
            self.assertEqual(str(tags['TPE1']), 'Mira Vale, Jun Park')
            self.assertEqual(str(tags['TXXX:FEATURED_ARTISTS']), 'Asha')
            self.assertEqual(tags.getall('APIC')[0].data, (root / 'cover.jpg').read_bytes())
            self.assertEqual(result['cover_sha256'], cover['sha256'])
            self.assertEqual(result['track_revision'], 9)
            self.assertEqual(worker.audio_digest(source), worker.audio_digest(root / 'tagged.mp3'))
            self.assertEqual(source.read_bytes(), before)
            with self.assertRaises(FileExistsError):
                worker.tag(source, root / 'tagged.mp3', root / 'request.json')
            request['cover_sha256'] = '0' * 64
            (root / 'request.json').write_text(json.dumps(request), encoding='utf-8')
            with self.assertRaises(ValueError):
                worker.tag(source, root / 'bad.mp3', root / 'request.json')
            self.assertFalse((root / 'bad.mp3').exists())

    @unittest.skipUnless(shutil.which('ffmpeg'), 'Real codec required')
    def test_no_cover_or_empty_features_leave_no_stale_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source.mp3'
            command([shutil.which('ffmpeg'), '-v', 'error', '-f', 'lavfi', '-i',
                     'sine=frequency=880:duration=1', '-c:a', 'libmp3lame', str(source)])
            request = {'metadata': {'title': 'Fictional', 'artists': [], 'featured_artists': [],
                                   'album': None, 'version': None, 'needs_review': True},
                       'track_id': 'fictional', 'track_revision': 0, 'video_id': 'abcdefghijk',
                       'cover_path': None, 'cover_sha256': None, 'snapshot_hash': 'a' * 64}
            (root / 'request.json').write_text(json.dumps(request), encoding='utf-8')
            result = worker.tag(source, root / 'tagged.mp3', root / 'request.json')
            tags = ID3(root / 'tagged.mp3')
            self.assertEqual(str(tags['TIT2']), 'Fictional')
            self.assertEqual(str(tags['TPE1']), 'Unknown Artist')
            self.assertNotIn('TALB', tags)
            self.assertNotIn('TXXX:FEATURED_ARTISTS', tags)
            self.assertFalse(tags.getall('APIC'))
            self.assertIsNone(result['cover_sha256'])
            self.assertEqual(result['sha256'], hashlib.sha256((root / 'tagged.mp3').read_bytes()).hexdigest())

    @unittest.skipUnless(shutil.which('ffmpeg'), 'Real codec required')
    def test_tagging_rejects_wide_or_truncated_cover_before_creating_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source.mp3'
            command([shutil.which('ffmpeg'), '-v', 'error', '-f', 'lavfi', '-i',
                     'sine=frequency=440:duration=1', '-c:a', 'libmp3lame', str(source)])
            for kind, dimensions in [('wide', (1024, 16)), ('truncated', (64, 64))]:
                cover = root / 'cover.jpg'
                Image.new('RGB', dimensions, 'lavenderblush').save(cover, 'JPEG')
                if kind == 'truncated':
                    cover.write_bytes(cover.read_bytes()[:-20])
                request = {'metadata': {'title': 'Fictional', 'artists': ['Mira Vale'],
                    'featured_artists': [], 'album': None, 'version': None, 'needs_review': False},
                    'track_id': 'fixture', 'track_revision': 0, 'video_id': 'abcdefghijk',
                    'cover_path': str(cover), 'cover_sha256': hashlib.sha256(cover.read_bytes()).hexdigest(),
                    'snapshot_hash': 'a' * 64}
                (root / 'request.json').write_text(json.dumps(request), encoding='utf-8')
                with self.assertRaises((ValueError, OSError)):
                    worker.tag(source, root / 'bad.mp3', root / 'request.json')
                self.assertFalse((root / 'bad.mp3').exists())
