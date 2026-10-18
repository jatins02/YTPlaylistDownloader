"""Offline handoff behavior; packages are fictional and never executed."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from scripts import build_handoff as handoff
from scripts import desktop_package as package


class HandoffTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='ytpd-handoff-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.input = self.root / 'ytpd'
        self.input.mkdir()
        self.output = self.root / 'delivery.zip'
        self.manifest = {
            'format': 1, 'channel': 'private-evaluation', 'target': 'linux-x64',
            'version': '0.1.0+1', 'revision': 'a' * 40, 'source_dirty': False,
            'schema': 6, 'scope': 'foundation',
            'entrypoint': 'app/yt_playlist_downloader',
            'toolchain': package.read_json(package.ROOT / 'toolchain.json'),
            'build_environment': {'os': 'fictional test environment'},
        }
        for name in ('app/yt_playlist_downloader', 'app/lib/libapp.so',
                     'app/lib/libflutter_linux_gtk.so', 'app/data/icudtl.dat',
                     'app/data/flutter_assets/NOTICES.Z', 'notices/flutter.txt',
                     'notices/dart.txt'):
            file = self.input / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b'fictional fixture: ' + name.encode())
            file.chmod(0o755 if name == self.manifest['entrypoint'] else 0o644)
        self.seal()

    def seal(self):
        self.manifest.pop('package_id', None)
        self.manifest['files'] = package.inventory(
            self.input, windows=self.manifest['target'] == 'windows-x64')
        self.manifest['package_id'] = package.identity(self.manifest)
        package.write_json(self.input / 'package.json', self.manifest)

    def test_handoff_contains_exact_verified_package_guides_and_checksums(self):
        before = package.inventory(self.input)
        result = handoff.build(self.input, self.output)
        self.assertEqual(result['sha256'], package.digest(self.output))
        self.assertEqual(package.inventory(self.input), before)
        with zipfile.ZipFile(self.output) as delivery:
            self.assertIsNone(delivery.testzip())
            report = json.loads(delivery.read('handoff.json'))
            self.assertFalse(report['public_release_approved'])
            self.assertEqual(report['build_revision'], 'a' * 40)
            self.assertEqual(report['scope'], 'foundation')
            self.assertEqual(report['physical_device_acceptance'], 'not assessed by this tool')
            self.assertEqual(set(report['files']), {*handoff.GUIDES, report['package_archive']})
            for line in delivery.read('SHA256SUMS').decode().splitlines():
                checksum, name = line.split('  ', 1)
                self.assertEqual(hashlib.sha256(delivery.read(name)).hexdigest(), checksum)
            with tarfile.open(fileobj=io.BytesIO(delivery.read(report['package_archive']))) as archive:
                embedded = json.load(archive.extractfile('ytpd/package.json'))
                self.assertEqual(embedded, self.manifest)

    def test_windows_foundation_keeps_its_scope_and_zip_format(self):
        (self.input / 'app/yt_playlist_downloader').rename(self.input / 'app/yt_playlist_downloader.exe')
        (self.input / 'app/lib/libapp.so').rename(self.input / 'app/data/app.so')
        (self.input / 'app/lib/libflutter_linux_gtk.so').rename(self.input / 'app/flutter_windows.dll')
        self.manifest.update(target='windows-x64', entrypoint='app/yt_playlist_downloader.exe')
        self.seal()
        handoff.build(self.input, self.output)
        with zipfile.ZipFile(self.output) as delivery:
            report = json.loads(delivery.read('handoff.json'))
            self.assertEqual(report['target'], 'windows-x64')
            self.assertEqual(report['scope'], 'foundation')
            with zipfile.ZipFile(io.BytesIO(delivery.read(report['package_archive']))) as archive:
                self.assertIn('ytpd/app/data/app.so', archive.namelist())

    def test_dirty_source_and_pin_drift_are_rejected(self):
        for change in ({'source_dirty': True}, {'toolchain': {}}):
            with self.subTest(change=change):
                old = self.manifest.copy()
                self.manifest.update(change)
                self.seal()
                with self.assertRaises(package.PackageError):
                    handoff.build(self.input, self.output)
                self.assertFalse(self.output.exists())
                self.manifest = old
                self.seal()

    def test_corrupt_or_secret_package_never_publishes(self):
        file = self.input / self.manifest['entrypoint']
        for payload in (b'changed binary', b'gsk_' + b'x' * 28):
            file.write_bytes(payload)
            with self.assertRaises(package.PackageError):
                handoff.build(self.input, self.output)
            self.assertFalse(self.output.exists())

    def test_changed_snapshot_is_rejected(self):
        original = package.copy_tree

        def mutate(source, destination):
            original(source, destination)
            (destination / self.manifest['entrypoint']).write_bytes(b'changed in copy')

        with patch.object(package, 'copy_tree', side_effect=mutate):
            with self.assertRaises(package.PackageError):
                handoff.build(self.input, self.output)
        self.assertFalse(self.output.exists())

    def test_existing_output_and_input_are_preserved(self):
        self.output.write_bytes(b'previous owner delivery')
        with self.assertRaises(FileExistsError):
            handoff.build(self.input, self.output)
        self.assertEqual(self.output.read_bytes(), b'previous owner delivery')
        with self.assertRaises(package.PackageError):
            handoff.build(self.input, self.input / 'delivery.zip')
        package.verify(self.input)

    def test_interrupted_publication_removes_only_its_partial(self):
        with patch.object(zipfile.ZipFile, 'write', side_effect=OSError('synthetic disk full')):
            with self.assertRaises(OSError):
                handoff.build(self.input, self.output)
        self.assertFalse(self.output.exists())
        package.verify(self.input)

    def test_guidance_must_exist_and_pass_secret_scan(self):
        guide = self.root / 'guide.md'
        package.write_json(self.root / 'toolchain.json', self.manifest['toolchain'])
        with patch.object(package, 'ROOT', self.root), patch.object(handoff, 'GUIDES', ('guide.md',)):
            for contents in (None, b'gsk_' + b'x' * 28):
                with self.subTest(contents=contents is not None):
                    if contents is not None:
                        guide.write_bytes(contents)
                    with self.assertRaises(package.PackageError):
                        handoff.build(self.input, self.output)
        self.assertFalse(self.output.exists())

    def test_guidance_paths_cannot_escape_the_handoff(self):
        with patch.object(handoff, 'GUIDES', ('../guide.md',)):
            with self.assertRaises(package.PackageError):
                handoff.build(self.input, self.output)


if __name__ == '__main__':
    unittest.main()
