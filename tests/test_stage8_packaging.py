"""Offline packaging/install regressions. Every file and prefix is test-owned."""
import json
import os
from pathlib import Path
import stat
import sys
import tarfile
import tempfile
import unittest
import zipfile
from unittest.mock import patch

from scripts import desktop_package as package
from scripts.prepare_linux_runtime import standalone
from scripts.check_android_apk import check as check_apk


class AndroidPackaging(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ytpd-apk-test-')
        self.addCleanup(self.temporary.cleanup)
        self.apk = Path(self.temporary.name) / 'fixture.apk'

    def write_apk(self, extra=None, *, complete=True):
        with zipfile.ZipFile(self.apk, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            if complete:
                for name in ('AndroidManifest.xml', 'classes.dex', 'assets/flutter_assets/NOTICES.Z',
                             'lib/arm64-v8a/libflutter.so'):
                    archive.writestr(name, b'fictional APK fixture')
            for name, value in (extra or {}).items():
                archive.writestr(name, value)

    def test_complete_compressed_assets_are_scanned_and_hashed(self):
        self.write_apk()
        self.assertEqual(check_apk(self.apk), package.digest(self.apk))
        # The key is synthetic and split at runtime; it never contacts a service.
        self.write_apk({'assets/fixture': b'gsk_' + b'z' * 28})
        with self.assertRaises(package.PackageError):
            check_apk(self.apk)

    def test_incomplete_and_private_config_fail(self):
        self.write_apk(complete=False)
        with self.assertRaises(package.PackageError):
            check_apk(self.apk)
        for name in ('assets/.env', 'assets/key.properties', 'assets/dev.keystore'):
            self.write_apk({name: b'fictional private fixture'})
            with self.assertRaises(package.PackageError):
                check_apk(self.apk)

    def test_required_apk_components_must_be_nonempty_files(self):
        required = ('AndroidManifest.xml', 'classes.dex', 'assets/flutter_assets/NOTICES.Z',
                    'lib/arm64-v8a/libflutter.so')
        for missing in required:
            for replacement in ('directory', 'empty'):
                with self.subTest(missing=missing, replacement=replacement):
                    entries = {name: b'fictional component' for name in required if name != missing}
                    entries[missing + '/' if replacement == 'directory' else missing] = b''
                    self.write_apk(entries, complete=False)
                    with self.assertRaises(package.PackageError):
                        check_apk(self.apk)

    def test_unsafe_paths_links_and_expansion_caps_fail(self):
        for name in ('../escaped', '/absolute', 'assets/../escaped', 'assets\\escaped'):
            self.write_apk({name: b'fictional'})
            with self.assertRaises(package.PackageError):
                check_apk(self.apk)
        entry = zipfile.ZipInfo('linked')
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.write_apk({entry: b'outside'})
        with self.assertRaises(package.PackageError):
            check_apk(self.apk)
        self.write_apk({'large': b'x' * 2048})
        with patch('scripts.check_android_apk.MAX_TOTAL', 1024):
            with self.assertRaises(package.PackageError):
                check_apk(self.apk)


class DesktopPackaging(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ytpd-package-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        self.executable = self.bundle / 'yt_playlist_downloader'
        self.executable.write_bytes(b'fictional native binary')
        self.executable.chmod(0o755)
        (self.bundle / 'data/flutter_assets').mkdir(parents=True)
        (self.bundle / 'data/flutter_assets/NOTICES.Z').write_bytes(b'fictional component notices')
        (self.bundle / 'data/icudtl.dat').write_bytes(b'fictional ICU data')
        (self.bundle / 'lib').mkdir()
        (self.bundle / 'lib/libapp.so').write_bytes(b'fictional AOT code')
        (self.bundle / 'lib/libflutter_linux_gtk.so').write_bytes(b'fictional engine')
        self.output = self.root / 'out'
        notice = self.root / 'fictional-sdk-notice.txt'
        notice.write_text('Fictional SDK license text; fixture packages never run.')
        patched = patch.object(package, 'flutter_notice_inputs', return_value={
            'flutter.txt': notice, 'dart.txt': notice, 'engine-fixture.txt': notice})
        patched.start()
        self.addCleanup(patched.stop)

    def unpack(self, archive, name='unpacked'):
        directory = self.root / name
        directory.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(directory, filter='data')
        return directory / 'ytpd'

    def make_package(self):
        return self.unpack(package.build(self.bundle, self.output, 'linux-x64'))

    def resign(self, root, **updates):
        data = package.read_json(root / 'package.json')
        data.update(updates)
        data['files'] = package.inventory(root)
        del data['package_id']
        data['package_id'] = package.identity(data)
        package.write_json(root / 'package.json', data)
        return data

    def test_deterministic_archives_hashes_and_no_clobber(self):
        first = package.build(self.bundle, self.output, 'linux-x64')
        other = package.build(self.bundle, self.root / 'other', 'linux-x64')
        self.assertEqual(first.read_bytes(), other.read_bytes())
        self.assertEqual(first.with_name(first.name + '.sha256').read_text().split()[0], package.digest(first))
        root = self.unpack(first)
        data = package.verify(root)
        self.assertEqual(data['scope'], 'foundation')
        self.assertEqual(data['channel'], 'private-evaluation')
        self.assertEqual(data['schema'], 6)
        with self.assertRaises(FileExistsError):
            package.build(self.bundle, self.output, 'linux-x64')
        self.assertEqual(package.digest(first), package.digest(other))

    def test_windows_archive_retains_complete_foundation_bundle(self):
        self.executable.rename(self.bundle / 'yt_playlist_downloader.exe')
        (self.bundle / 'plugin.dll').write_bytes(b'fictional plugin')
        (self.bundle / 'flutter_windows.dll').write_bytes(b'fictional engine')
        (self.bundle / 'data/app.so').write_bytes(b'fictional AOT code')
        archive = package.build(self.bundle, self.output, 'windows-x64')
        with zipfile.ZipFile(archive) as zip_file:
            self.assertIn('ytpd/app/plugin.dll', zip_file.namelist())
            self.assertIn('ytpd/app/data/flutter_assets/NOTICES.Z', zip_file.namelist())
            data = json.loads(zip_file.read('ytpd/package.json'))
            self.assertEqual(data['scope'], 'foundation')
            directory = self.root / 'windows-unpacked'
            zip_file.extractall(directory)
        self.assertEqual(package.verify(directory / 'ytpd')['target'], 'windows-x64')
        with self.assertRaises(package.PackageError):
            package.build(self.bundle, self.root / 'media-out', 'windows-x64', self.root)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux executable permissions')
    def test_shared_bundle_mode_bits_do_not_make_assets_executable(self):
        for path in package.files(self.bundle):
            path.chmod(0o777)  # Simulate an input mount synthesizing exec bits.
        root = self.make_package()
        data = package.verify(root)
        self.assertEqual([name for name, record in data['files'].items()
                          if record['executable']], ['app/yt_playlist_downloader'])
        self.assertEqual((root / 'app/data/icudtl.dat').stat().st_mode & 0o777, 0o644)

    def test_private_files_and_special_files_rejected_without_reading(self):
        for name in ('.env', '.env.example', 'owner.jks', 'key.properties', 'drafts.sqlite', 'pyvenv.cfg'):
            with self.subTest(name=name):
                path = self.bundle / name
                path.write_text('private content must not be opened')
                with self.assertRaises(package.PackageError):
                    package.files(self.bundle)
                path.unlink()
        if hasattr(os, 'mkfifo'):
            os.mkfifo(self.bundle / 'pipe')
            with self.assertRaises(package.PackageError):
                package.files(self.bundle)

    def test_interrupted_archive_is_not_left_as_a_finished_package(self):
        root = self.make_package()
        target = self.root / 'failed.tar.gz'
        with patch.object(package.tarfile.TarFile, 'addfile', side_effect=OSError('synthetic disk full')):
            with self.assertRaises(OSError):
                package.archive(root, 'linux-x64', target)
        self.assertFalse(target.exists())
        (self.bundle / 'lib/libapp.so').unlink()
        with self.assertRaises(package.PackageError):
            package.build(self.bundle, self.root / 'incomplete', 'linux-x64')

    def test_required_desktop_components_cannot_be_empty(self):
        for name in ('yt_playlist_downloader', 'lib/libapp.so', 'lib/libflutter_linux_gtk.so',
                     'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z'):
            file = self.bundle / name
            previous = file.read_bytes()
            with self.subTest(name=name):
                file.write_bytes(b'')
                with self.assertRaises(package.PackageError):
                    package.build(self.bundle, self.output, 'linux-x64')
            file.write_bytes(previous)
        (self.root / 'fictional-sdk-notice.txt').write_bytes(b'')
        with self.assertRaises(package.PackageError):
            package.build(self.bundle, self.output, 'linux-x64')

    @unittest.skipUnless(sys.platform == 'linux', 'Linux executable permissions')
    def test_nonexecutable_entrypoint_cannot_be_declared_a_verified_package(self):
        root = self.make_package()
        (root / 'app/yt_playlist_downloader').chmod(0o644)
        self.resign(root)
        with self.assertRaises(package.PackageError):
            package.verify(root)

    def test_media_package_checks_tool_bytes_and_component_notices(self):
        runtime = self.root / 'runtime'
        (runtime / 'bin').mkdir(parents=True)
        tools = {}
        for name in ('python', 'ffmpeg', 'ffprobe', 'deno'):
            file = runtime / 'bin' / name
            file.write_bytes(('fictional ' + name).encode())
            file.chmod(0o755)
            tools[name] = {'path': 'bin/' + name, 'bytes': file.stat().st_size, 'sha256': package.digest(file)}
        package.write_json(runtime / 'media-runtime.json', {'format': 1, 'tools': tools})
        (runtime / 'notice.txt').write_text('Fictional notices, no real runtime is executed.')
        pins = package.read_json(package.ROOT / 'toolchain.json')
        versions = pins['media_runtime_versions']
        expected = {'python': versions['python'], 'ffmpeg': versions['ffmpeg'], 'deno': versions['deno'],
                    'yt-dlp': versions['yt_dlp'], 'yt-dlp-ejs': versions['ejs'], **pins['metadata_runtime_versions']}
        components = {name: {'version': version, 'notices': ['notice.txt']} for name, version in expected.items()}
        package.write_json(runtime / 'COMPONENTS.json', {'redistribution': 'unresolved', 'components': components})
        archive = package.build(self.bundle, self.output, 'linux-x64', runtime)
        self.assertEqual(package.verify(self.unpack(archive))['scope'], 'linux-media')
        (runtime / 'bin/ffmpeg').write_text('corrupt')
        with self.assertRaises(package.PackageError):
            package.build(self.bundle, self.root / 'corrupt-media', 'linux-x64', runtime)
        (runtime / 'bin/ffmpeg').write_bytes(b'fictional ffmpeg')
        (runtime / 'notice.txt').unlink()
        with self.assertRaises(package.PackageError):
            package.build(self.bundle, self.root / 'missing-notice', 'linux-x64', runtime)

    def test_literal_key_across_chunk_boundary_rejected_without_disclosure(self):
        token = b'gsk_' + b'X' * 30
        (self.bundle / 'binary').write_bytes(b'a' * (1024 * 1024 - 2) + token)
        with self.assertRaises(package.PackageError) as raised:
            package.build(self.bundle, self.output, 'linux-x64')
        self.assertNotIn(token.decode(), str(raised.exception))

    def test_public_ca_is_allowed_but_actual_private_key_body_is_rejected(self):
        ca = self.bundle / 'python/site-packages/certifi/cacert.pem'
        ca.parent.mkdir(parents=True)
        ca.write_bytes(b'-----BEGIN CERTIFICATE-----\n' + b'Z' * 64 + b'\n')
        package.inventory(self.bundle)
        # Native TLS parsers contain header constants; those are not keys.
        (self.bundle / 'parser').write_bytes(b'-----BEGIN PRIVATE KEY-----\x00parser')
        package.inventory(self.bundle)
        ca.write_bytes(b'-----BEGIN PRIVATE KEY-----\n' + b'Z' * 64 + b'\n')
        with self.assertRaises(package.PackageError):
            package.inventory(self.bundle)

    def test_corruption_extra_missing_mode_and_metadata_rejected(self):
        root = self.make_package()
        file = root / 'app/yt_playlist_downloader'
        original = file.read_bytes()
        file.write_bytes(b'corrupt')
        with self.assertRaises(package.PackageError):
            package.verify(root)
        file.write_bytes(original)
        file.chmod(0o644)
        if os.name != 'nt':
            with self.assertRaises(package.PackageError):
                package.verify(root)
        file.chmod(0o755)
        extra = root / 'unlisted'
        extra.write_text('unlisted')
        with self.assertRaises(package.PackageError):
            package.verify(root)
        extra.unlink()
        data = package.read_json(root / 'package.json')
        data['version'] = '99.0.0+1'
        package.write_json(root / 'package.json', data)
        with self.assertRaises(package.PackageError):
            package.verify(root)

    def test_unsafe_paths_and_case_collisions_rejected(self):
        for value in ('../x', '/absolute', 'x//y', 'x/./y', r'x\y', 'C:x', 'CON', 'x/NUL.txt', 'x.'):
            with self.subTest(path=value), self.assertRaises(package.PackageError):
                package.relative(value)
        if os.name != 'nt':
            (self.bundle / 'equal').write_text('first')
            (self.bundle / 'EQUAL').write_text('second')
            with self.assertRaises(package.PackageError):
                package.inventory(self.bundle)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux versioned installer')
    def test_install_update_rollback_preserve_user_data_and_old_versions(self):
        root = self.make_package()
        # This represents an entirely separate app-private data tree/vault.
        data = self.root / 'private-data'
        data.mkdir()
        (data / 'drafts.sqlite').write_bytes(b'committed fictional draft')
        (data / 'vault-marker').write_bytes(b'fictional secure reference')
        before = {p.name: p.read_bytes() for p in data.iterdir()}
        prefix = self.root / 'install'
        first = package.install(root, prefix)
        (root / 'app/yt_playlist_downloader').write_bytes(b'fictional binary update')
        updated = self.resign(root)
        second = package.install(root, prefix)
        self.assertNotEqual(first, second)
        self.assertEqual(second, updated['package_id'])
        self.assertEqual(os.readlink(prefix / 'current'), 'releases/' + second)
        with package.installation(prefix) as locked:
            package.activate(locked, first)
        self.assertEqual(os.readlink(prefix / 'current'), 'releases/' + first)
        self.assertEqual(len(list((prefix / 'releases').iterdir())), 2)
        self.assertEqual({p.name: p.read_bytes() for p in data.iterdir()}, before)
        self.assertEqual(package.install(prefix / 'releases' / first, prefix), first)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux versioned installer')
    def test_failed_copy_tampered_rollback_and_schema_change_keep_current(self):
        root = self.make_package()
        prefix = self.root / 'install'
        first = package.install(root, prefix)
        old = os.readlink(prefix / 'current')
        (root / 'app/yt_playlist_downloader').write_bytes(b'new binary')
        self.resign(root)
        with patch.object(package.shutil, 'copyfile', side_effect=OSError('synthetic low storage')):
            with self.assertRaises(OSError):
                package.install(root, prefix)
        self.assertEqual(os.readlink(prefix / 'current'), old)
        self.assertFalse(list(prefix.glob('.incoming-*')))
        self.resign(root, schema=7)
        with self.assertRaises(package.PackageError):
            package.install(root, prefix)
        self.assertEqual(os.readlink(prefix / 'current'), old)
        (prefix / 'releases' / first / 'app/yt_playlist_downloader').write_bytes(b'tampered')
        with self.assertRaises(package.PackageError):
            with package.installation(prefix) as locked:
                package.activate(locked, first)
        self.assertEqual(os.readlink(prefix / 'current'), old)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux symlink and lock behavior')
    def test_unrelated_prefix_symlinks_and_concurrent_install_rejected(self):
        root = self.make_package()
        prefix = self.root / 'install'
        prefix.mkdir()
        keep = prefix / 'keep.txt'
        keep.write_text('owner data')
        with self.assertRaises(package.PackageError):
            package.install(root, prefix)
        self.assertEqual(keep.read_text(), 'owner data')
        keep.unlink()
        prefix.chmod(0o777)
        with self.assertRaises(package.PackageError):
            package.install(root, prefix)
        prefix.chmod(0o700)
        with package.installation(prefix):
            with self.assertRaises(BlockingIOError):
                package.install(root, prefix)
        (self.bundle / 'outside').symlink_to(self.executable)
        with self.assertRaises(package.PackageError):
            package.build(self.bundle, self.output, 'linux-x64')

    @unittest.skipUnless(sys.platform == 'linux', 'Linux versioned installer')
    def test_changed_valid_package_during_copy_cannot_activate_under_old_identity(self):
        root = self.make_package()
        prefix = self.root / 'install'
        first = package.install(root, prefix)
        (root / 'app/yt_playlist_downloader').write_bytes(b'intended update')
        intended = self.resign(root)['package_id']
        original = package.copy_tree

        def replace_during_copy(source, target, **kwargs):
            original(source, target, **kwargs)
            (target / 'app/yt_playlist_downloader').write_bytes(b'a different valid package')
            self.resign(target)

        with patch.object(package, 'copy_tree', side_effect=replace_during_copy):
            with self.assertRaises(package.PackageError):
                package.install(root, prefix)
        self.assertEqual(os.readlink(prefix / 'current'), 'releases/' + first)
        self.assertFalse((prefix / 'releases' / intended).exists())
        self.assertFalse(list(prefix.glob('.incoming-*')))

    @unittest.skipUnless(sys.platform == 'linux', 'Linux versioned installer')
    def test_valid_package_under_wrong_directory_identity_cannot_activate(self):
        root = self.make_package()
        prefix = self.root / 'install'
        first = package.install(root, prefix)
        wrong = '0' * 16
        package.copy_tree(root, prefix / 'releases' / wrong)
        with package.installation(prefix) as locked:
            with self.assertRaises(package.PackageError):
                package.activate(locked, wrong)
        self.assertEqual(os.readlink(prefix / 'current'), 'releases/' + first)

    def test_venv_and_external_standalone_alias_are_not_packaged(self):
        source = self.root / 'python'
        source.mkdir()
        (source / 'pyvenv.cfg').write_text('not portable')
        with self.assertRaises(package.PackageError):
            standalone(source, self.root / 'copy')
        (source / 'pyvenv.cfg').unlink()
        (source / 'lib/python3.14').mkdir(parents=True)
        (source / 'lib/python3.14/os.py').write_text('# fictional stdlib')
        if sys.platform == 'linux':
            (source / 'external').symlink_to(self.executable)
            with self.assertRaises(package.PackageError):
                standalone(source, self.root / 'copy')

    def test_standalone_size_limit_is_checked_before_copying(self):
        source = self.root / 'python'
        (source / 'lib/python3.14').mkdir(parents=True)
        (source / 'lib/python3.14/os.py').write_text('# fictional stdlib')
        with patch('scripts.prepare_linux_runtime.MAX_FILE', 1), patch(
                'scripts.prepare_linux_runtime.shutil.copyfile') as copy:
            with self.assertRaises(package.PackageError):
                standalone(source, self.root / 'copy')
            copy.assert_not_called()


if __name__ == '__main__':
    unittest.main()
