"""Actual ZIP and atomic Linux destination operations; synthetic bytes only."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import warnings
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'apps/native/assets/export_tools.py'
spec = importlib.util.spec_from_file_location('export_worker', SCRIPT)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class ExportWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ytpd-stage6-worker-')
        self.root = Path(self.temporary.name)
        self.private = self.root / 'private'
        self.private.mkdir()
        self.public = self.root / 'destination'
        self.public.mkdir()
        self.addCleanup(self.temporary.cleanup)

    def entry(self, name, payload):
        path = self.private / str(uuid4())
        path.write_bytes(payload)
        return {'id': str(uuid4()), 'track_id': str(uuid4()), 'path': str(path),
                'filename': name, 'sha256': hashlib.sha256(payload).hexdigest(), 'bytes': len(payload)}

    def archive(self):
        files = [self.entry('Equal name.mp3', b'440 Hz fictional bytes' * 100),
                 self.entry('Equal name (2).mp3', b'880 Hz fictional bytes' * 100)]
        manifest = self.entry('manifest.json', json.dumps({'files': [{k: v for k, v in f.items() if k != 'path'} for f in files]}).encode())
        request = {'files': files, 'manifest': manifest, 'archive': str(self.private / 'verified.zip'),
                   'max_file_bytes': 65536, 'max_archive_bytes': 131072}
        worker.write_archive(request)
        return request

    def destination(self, payload=b'verified synthetic tagged MP3'):
        source = self.private / 'source.mp3'
        source.write_bytes(payload)
        request = {'delivery_id': str(uuid4()), 'destination': str(self.public / 'saved.mp3'),
                   'source': str(source), 'private_root': str(self.private),
                   'bytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(), 'max_bytes': 65536}
        return {**request, **worker.prepare_destination(request)}

    def test_unicode_casefold_collisions_reserved_names_and_byte_bounds(self):
        texts = ['Straße', 'STRASSE', 'Étoiles', 'E\u0301toiles', 'CON', '夜' * 500, 'bad:/name. ']
        tracks = [{'track_id': str(uuid4()), 'name': s} for s in texts]
        result = worker.names({'tracks': tracks})['names']
        self.assertEqual(len({worker.key(n) for n in result.values()}), len(texts))
        self.assertTrue(all(len(n.encode()) <= 184 for n in result.values()))
        self.assertEqual(result[tracks[4]['track_id']], '_CON.mp3')
        self.assertIn('(2)', result[tracks[1]['track_id']])
        self.assertTrue(all('/' not in n and ':' not in n for n in result.values()))

    def test_names_reject_duplicate_ids_instead_of_overwriting(self):
        track = {'track_id': str(uuid4()), 'name': 'Same'}
        with self.assertRaises(worker.Invalid):
            worker.names({'tracks': [track, track]})

    def test_actual_zip_exact_manifest_distinct_files_and_repeat_verification(self):
        request = self.archive()
        result = worker.verify_archive(request)
        self.assertEqual(result['sha256'], hashlib.sha256(Path(request['archive']).read_bytes()).hexdigest())
        with zipfile.ZipFile(request['archive']) as archive:
            self.assertEqual(set(archive.namelist()), {'Equal name.mp3', 'Equal name (2).mp3', 'manifest.json'})
            self.assertNotEqual(archive.read('Equal name.mp3'), archive.read('Equal name (2).mp3'))
            self.assertEqual(archive.read('manifest.json'), Path(request['manifest']['path']).read_bytes())

    def test_zip_unexpected_entry_or_duplicate_is_rejected(self):
        for filename in ('extra.mp3', 'Equal name.mp3'):
            request = self.archive()
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', UserWarning)
                with zipfile.ZipFile(request['archive'], 'a') as archive:
                    archive.writestr(filename, b'changed')
            with self.assertRaises(worker.Invalid):
                worker.verify_archive(request)
            Path(request['archive']).unlink()

    def test_truncated_zip_is_rejected(self):
        request = self.archive()
        path = Path(request['archive'])
        path.write_bytes(path.read_bytes()[:-15])
        with self.assertRaises(zipfile.BadZipFile):
            worker.verify_archive(request)

    def test_modified_loose_file_or_manifest_is_rejected(self):
        for target in ('files', 'manifest'):
            request = self.archive()
            entry = request['files'][0] if target == 'files' else request['manifest']
            path = Path(entry['path'])
            path.write_bytes(b'x' * entry['bytes'])
            with self.assertRaises(worker.Invalid):
                worker.verify_archive(request)
            Path(request['archive']).unlink()

    def test_archive_limit_is_enforced_without_omitting_songs(self):
        request = self.archive()
        Path(request['archive']).unlink()
        request['max_archive_bytes'] = 100
        with self.assertRaises(worker.Limit):
            worker.write_archive(request)

    def test_traversal_and_unicode_duplicate_archive_names_are_rejected(self):
        request = self.archive()
        for names in (['../escape.mp3', 'valid.mp3'], ['É.mp3', 'E\u0301.mp3']):
            for row, name in zip(request['files'], names):
                row['filename'] = name
            with self.assertRaises(worker.Invalid):
                worker.archive_entries(request)

    @unittest.skipUnless(sys.platform == 'linux', 'Actual Linux destination adapter')
    def test_transfer_publishes_verified_bytes_and_removes_staging_only(self):
        request = self.destination()
        result = worker.transfer(request)
        self.assertEqual(result['sha256'], request['sha256'])
        self.assertEqual(Path(request['destination']).read_bytes(), Path(request['source']).read_bytes())
        self.assertFalse(Path(request['temporary']).exists())
        worker.cleanup_destination(request)
        self.assertTrue(Path(request['destination']).exists())

    def test_existing_file_is_never_replaced(self):
        request = self.destination()
        Path(request['destination']).write_bytes(b'owner file')
        with self.assertRaises(FileExistsError):
            worker.transfer(request)
        self.assertEqual(Path(request['destination']).read_bytes(), b'owner file')
        self.assertFalse(Path(request['temporary']).exists())

    def test_prepare_rejects_existing_file_symlink_and_private_destination(self):
        request = self.destination()
        worker.cleanup_destination(request)
        Path(request['destination']).write_bytes(b'owner file')
        with self.assertRaises(FileExistsError):
            worker.prepare_destination(request)
        Path(request['destination']).unlink()
        Path(request['destination']).symlink_to(request['source'])
        with self.assertRaises(FileExistsError):
            worker.prepare_destination(request)
        request['destination'] = str(self.private / 'not-a-device-copy.mp3')
        with self.assertRaises(worker.Invalid):
            worker.prepare_destination(request)

    def test_corrupt_source_never_publishes_a_destination(self):
        request = self.destination()
        Path(request['source']).write_bytes(b'x' * request['bytes'])
        with self.assertRaises(worker.Invalid):
            worker.transfer(request)
        self.assertFalse(Path(request['destination']).exists())
        self.assertFalse(Path(request['temporary']).exists())

    def test_interrupted_staging_cleanup_uses_exact_inode_and_keeps_user_copy(self):
        request = self.destination()
        Path(request['temporary']).write_bytes(b'interrupted partial')
        Path(request['destination']).write_bytes(b'owner copy')
        worker.cleanup_destination(request)
        self.assertFalse(Path(request['temporary']).exists())
        self.assertEqual(Path(request['destination']).read_bytes(), b'owner copy')
        replacement = Path(request['temporary'])
        replacement.write_bytes(b'different inode')
        worker.cleanup_destination(request)
        self.assertEqual(replacement.read_bytes(), b'different inode')

    def test_unbound_intent_cleans_only_its_nonce_even_if_an_inode_was_never_recorded(self):
        request = self.destination()
        request['device'], request['inode'] = 0, 0
        worker.cleanup_destination(request)
        self.assertFalse(Path(request['temporary']).exists())
        Path(request['temporary']).write_bytes(b'foreign replacement')
        worker.cleanup_destination(request)
        self.assertEqual(Path(request['temporary']).read_bytes(), b'foreign replacement')

    def test_low_space_is_recoverable_before_creating_temporary_bytes(self):
        request = self.destination()
        worker.cleanup_destination(request)
        request['free_reserve_bytes'] = 10 ** 20
        with self.assertRaises(OSError):
            worker.prepare_destination(request)
        self.assertFalse(Path(request['temporary']).exists())

    def test_permission_denial_keeps_source_and_destination_unmodified(self):
        request = self.destination()
        worker.cleanup_destination(request)
        with patch.object(worker.os, 'open', side_effect=PermissionError()):
            with self.assertRaises(PermissionError):
                worker.prepare_destination(request)
        self.assertTrue(Path(request['source']).exists())
        self.assertFalse(Path(request['destination']).exists())

    @unittest.skipUnless(sys.platform == 'linux', 'Actual Linux transfer cancellation')
    def test_signal_during_copy_removes_partial_bytes_without_publishing(self):
        source = self.private / 'large-synthetic.bin'
        with source.open('wb') as file:
            file.truncate(128 * 1024 * 1024)
        with source.open('rb') as file:
            size, checksum = worker.digest(file, 128 * 1024 * 1024)
        request = {'delivery_id': str(uuid4()), 'destination': str(self.public / 'interrupted.zip'),
                   'source': str(source), 'private_root': str(self.private), 'bytes': size,
                   'sha256': checksum, 'max_bytes': size}
        request.update(worker.prepare_destination(request))
        path = self.private / 'request.json'
        path.write_text(json.dumps(request))
        child = subprocess.Popen([sys.executable, '-I', str(SCRIPT), 'transfer', str(path)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while Path(request['temporary']).stat().st_size < 65536 and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.0005)
            self.assertIsNone(child.poll(), 'Copy must still be active when interrupted')
            child.terminate()
            stdout, stderr = child.communicate(timeout=5)
            self.assertEqual(json.loads(stdout), {'ok': False, 'error': 'cancelled'})
            self.assertEqual(stderr, '')
            self.assertFalse(Path(request['destination']).exists())
            self.assertFalse(Path(request['temporary']).exists())
            self.assertTrue(source.exists())
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=5)

    def test_private_publication_sync_rejects_paths_outside_its_workspace(self):
        bundle = self.private / str(uuid4())
        bundle.mkdir()
        (bundle / (str(uuid4()) + '.mp3')).write_bytes(b'fully verified synthetic bytes')
        self.assertEqual(worker.sync_publication({'directory': str(bundle), 'private_root': str(self.private)}), {})
        with self.assertRaises(worker.Invalid):
            worker.sync_publication({'directory': str(self.public), 'private_root': str(self.private)})

    def test_worker_errors_are_structured_without_private_paths(self):
        request = self.root / 'bounded-request.json'
        request.write_text(json.dumps({'delivery_id': 'invalid', 'destination': '/private/do-not-expose.mp3'}))
        result = subprocess.run([sys.executable, '-I', str(SCRIPT), 'prepare-destination', str(request)],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout), {'ok': False, 'error': 'invalid'})
        self.assertNotIn('do-not-expose', result.stdout + result.stderr)

    @unittest.skipUnless(sys.platform == 'linux', 'Actual Linux special-file rejection')
    def test_foreign_fifo_does_not_block_recovery_or_source_verification(self):
        request = self.destination()
        temporary = Path(request['temporary'])
        temporary.unlink()
        os.mkfifo(temporary)
        path = self.private / 'request.json'
        path.write_text(json.dumps(request))
        result = subprocess.run([sys.executable, '-I', str(SCRIPT), 'cleanup-destination', str(path)],
                                capture_output=True, text=True, check=True, timeout=3)
        self.assertEqual(json.loads(result.stdout), {'ok': True})
        self.assertTrue(temporary.is_fifo())
        # A replaced private input is rejected before any blocking read as well.
        Path(request['source']).unlink()
        os.mkfifo(request['source'])
        result = subprocess.run([sys.executable, '-I', str(SCRIPT), 'names', request['source']],
                                capture_output=True, text=True, check=True, timeout=3)
        self.assertEqual(json.loads(result.stdout), {'ok': False, 'error': 'invalid'})


if __name__ == '__main__':
    unittest.main()
