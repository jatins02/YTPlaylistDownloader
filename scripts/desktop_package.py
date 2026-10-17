#!/usr/bin/env python3
"""Build, verify and install private Stage 8 desktop evaluation packages.

No downloads, credentials, application data, privileged installs or automatic
updates. Checksums detect damage; they do not authenticate a download's publisher.
Only run this tool and binaries obtained from a trusted source.
"""
from __future__ import annotations

import argparse
import contextlib
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'package.json'
MAX_FILE = 256 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024
MAX_FILES = 40000
KEY = re.compile(rb'gsk_[A-Za-z0-9_-]{20,256}')
TARGETS = {'linux-x64': 'yt_playlist_downloader',
           'windows-x64': 'yt_playlist_downloader.exe'}
REQUIRED = {
    'linux-x64': ('lib/libapp.so', 'lib/libflutter_linux_gtk.so'),
    'windows-x64': ('data/app.so', 'flutter_windows.dll'),
}


class PackageError(ValueError):
    """A safe, user-facing package failure; never includes file contents."""


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def relative(value: str) -> str:
    if (not isinstance(value, str) or not value or len(value) > 512 or
            '\\' in value or ':' in value or '\x00' in value or
            any(ord(c) < 32 for c in value) or
            PurePosixPath(value).is_absolute() or
            any(p in ('', '.', '..') for p in value.split('/'))):
        raise PackageError('Unsafe package path.')
    for part in value.split('/'):
        if (part.endswith((' ', '.')) or
                re.fullmatch(r'(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', part)):
            raise PackageError('Nonportable package path.')
    return value


def safe_name(path: Path) -> None:
    name = path.name.lower()
    public_ca = path.as_posix().endswith('/certifi/cacert.pem')
    if (name == '.env' or name.startswith('.env.') or
            name.endswith(('.jks', '.keystore', '.p12', '.pfx', '.key')) or
            name.endswith('.pem') and not public_ca or
            name in ('pyvenv.cfg', 'key.properties', 'local.properties', '.git',
                     'drafts.sqlite', '.session.lock') or
            name.endswith(('.private.json', '.private.html'))):
        raise PackageError('Private configuration, key or development environment in package.')


def files(root: Path) -> list[Path]:
    """Never follow a directory link or open dotenv/special files to scan them."""
    if root.is_symlink() or not root.is_dir():
        raise PackageError('Expected a real package directory.')
    found, total = [], 0
    for directory, dirs, names in os.walk(root, followlinks=False):
        for name in dirs:
            path = Path(directory) / name
            safe_name(path)
            if path.is_symlink():
                raise PackageError('Directory links are not allowed in packages.')
        for name in names:
            path = Path(directory) / name
            safe_name(path)
            mode = path.lstat().st_mode
            if not stat.S_ISREG(mode):
                raise PackageError('Only regular files are allowed in packages.')
            size = path.stat().st_size
            if size > MAX_FILE:
                raise PackageError('Package file exceeds the byte limit.')
            total += size
            found.append(path)
            if len(found) > MAX_FILES or total > MAX_TOTAL:
                raise PackageError('Package exceeds the file or byte limit.')
    return sorted(found, key=lambda p: p.relative_to(root).as_posix())


def inventory(root: Path, *, windows: bool = False) -> dict[str, dict]:
    result = {}
    folded = set()
    for path in files(root):
        name = relative(path.relative_to(root).as_posix())
        portable = unicodedata.normalize('NFKC', name).casefold()
        if portable in folded:
            raise PackageError('Case-colliding package paths.')
        folded.add(portable)
        # Retain overlap for a token spanning two chunks. Never print a match.
        with path.open('rb') as stream:
            previous = b''
            while chunk := stream.read(1024 * 1024):
                data = previous + chunk
                if KEY.search(data):
                    raise PackageError('Possible literal API key in package.')
                if re.search(rb'-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]{32,}', data):
                    raise PackageError('Possible private signing key in package.')
                previous = data[-260:]
        if name == MANIFEST:
            continue
        result[name] = {'bytes': path.stat().st_size, 'sha256': digest(path),
                        'executable': not windows and bool(path.stat().st_mode & 0o111)}
    return result


def read_json(path: Path, limit: int = 16 * 1024 * 1024) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise PackageError('Missing or oversized package record.')
    try:
        value = json.loads(path.read_text(encoding='utf-8'))
    except (ValueError, UnicodeError) as error:
        raise PackageError('Invalid package record.') from error
    if not isinstance(value, dict):
        raise PackageError('Invalid package record.')
    return value


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, sort_keys=True, indent=2) + '\n', encoding='utf-8')


def identity(data: dict) -> str:
    encoded = json.dumps(data, sort_keys=True, separators=(',', ':')).encode()
    return hashlib.sha256(encoded).hexdigest()[:16]


def verify(root: Path) -> dict:
    data = read_json(root / MANIFEST)
    expected = {'format', 'channel', 'target', 'version', 'revision', 'source_dirty', 'schema',
                'scope', 'entrypoint', 'toolchain', 'build_environment', 'files', 'package_id'}
    if (set(data) != expected or type(data['format']) is not int or
            data['format'] != 1 or data['channel'] != 'private-evaluation'):
        raise PackageError('Unsupported package format or channel.')
    if (not isinstance(data['target'], str) or data['target'] not in TARGETS or
            not isinstance(data['toolchain'], dict) or data['scope'] not in ('foundation', 'linux-media') or
            type(data['schema']) is not int or data['schema'] < 1 or type(data['source_dirty']) is not bool or
            not isinstance(data['version'], str) or not isinstance(data['revision'], str) or
            not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+', data['version']) or
            not re.fullmatch(r'[a-f0-9]{40}', data['revision'])):
        raise PackageError('Invalid package identity.')
    entrypoint = 'app/' + TARGETS[data['target']]
    if data['entrypoint'] != entrypoint or not (root / entrypoint).is_file():
        raise PackageError('Missing application entrypoint.')
    for name in (*REQUIRED[data['target']], 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z'):
        if not (root / 'app' / name).is_file():
            raise PackageError('Incomplete AOT release bundle or component notices.')
    if not all((root / 'notices' / name).is_file() for name in ('flutter.txt', 'dart.txt')):
        raise PackageError('Flutter/Dart component notices are missing.')
    recorded = data['files']
    if not isinstance(recorded, dict) or not recorded:
        raise PackageError('Missing package inventory.')
    actual = inventory(root, windows=data['target'] == 'windows-x64')
    if actual != recorded:
        raise PackageError('Package files, modes or checksums do not match.')
    unsigned = {k: v for k, v in data.items() if k != 'package_id'}
    if data['package_id'] != identity(unsigned):
        raise PackageError('Package identity does not match its contents.')
    if data['scope'] == 'linux-media':
        if data['target'] != 'linux-x64':
            raise PackageError('Media packaging is currently Linux-only.')
        validate_runtime(root / 'app/runtime', data['toolchain'])
    return data


def validate_runtime(root: Path, pins: dict) -> None:
    files(root)
    manifest = read_json(root / 'media-runtime.json', 8192)
    tools = manifest.get('tools')
    if (set(manifest) != {'format', 'tools'} or type(manifest['format']) is not int or
            manifest['format'] != 1 or not isinstance(tools, dict)):
        raise PackageError('Expected a relocatable runtime manifest.')
    if set(tools) != {'python', 'ffmpeg', 'ffprobe', 'deno'}:
        raise PackageError('Incomplete media runtime.')
    for record in tools.values():
        if not isinstance(record, dict) or set(record) != {'path', 'sha256', 'bytes'}:
            raise PackageError('Invalid runtime tool record.')
        if (type(record['bytes']) is not int or not 0 < record['bytes'] <= MAX_FILE or
                not isinstance(record['sha256'], str) or
                not re.fullmatch('[a-f0-9]{64}', record['sha256'])):
            raise PackageError('Invalid runtime tool integrity record.')
        path = root / relative(record['path'])
        if (path.is_symlink() or not path.is_file() or
                path.stat().st_size != record['bytes'] or digest(path) != record['sha256'] or
                not path.stat().st_mode & 0o111):
            raise PackageError('Runtime tool integrity or executable mode failed.')
    components = read_json(root / 'COMPONENTS.json')
    if components.get('redistribution') != 'unresolved':
        raise PackageError('This evaluation packager cannot certify redistribution rights.')
    declared = components.get('components')
    if not isinstance(declared, dict):
        raise PackageError('Invalid component notice records.')
    versions = pins.get('media_runtime_versions')
    metadata = pins.get('metadata_runtime_versions')
    if (not isinstance(versions, dict) or not isinstance(metadata, dict) or
            not all(isinstance(versions.get(k), str) for k in ('python', 'yt_dlp', 'ejs', 'deno', 'ffmpeg')) or
            not all(isinstance(metadata.get(k), str) for k in ('mutagen', 'pillow'))):
        raise PackageError('Package runtime version pins are incomplete.')
    expected_versions = {'python': versions['python'], 'yt-dlp': versions['yt_dlp'],
                         'yt-dlp-ejs': versions['ejs'], 'deno': versions['deno'],
                         'ffmpeg': versions['ffmpeg'], **metadata}
    for name, version in expected_versions.items():
        record = declared.get(name)
        if not isinstance(record, dict) or record.get('version') != version:
            raise PackageError('Runtime component versions do not match package pins.')
        notices = record.get('notices')
        if not isinstance(notices, list) or not notices:
            raise PackageError('Runtime component version/notices are missing.')
        for notice in notices:
            path = root / relative(notice)
            if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
                raise PackageError('Runtime component notice is missing.')


def copy_tree(source: Path, target: Path, *, durable: bool = False) -> None:
    # Validate before copying. No broad repository/home scans or link following.
    source_files = files(source)
    target.mkdir(parents=True, mode=0o755)
    for path in source_files:
        destination = target / path.relative_to(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        destination.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)
        if durable:
            with destination.open('rb') as stream:
                os.fsync(stream.fileno())
    if durable:
        for directory, _, _ in os.walk(target, topdown=False):
            sync_directory(Path(directory))


def sync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def archive(root: Path, target: str, output: Path) -> None:
    # Archive root is fixed, metadata deterministic, and outputs are no-clobber.
    paths = files(root)
    raw = output.open('xb')
    try:
        _archive(paths, root, target, raw)
        raw.flush()
        os.fsync(raw.fileno())
    except BaseException:
        raw.close()
        output.unlink(missing_ok=True)
        raise
    finally:
        raw.close()


def _archive(paths: list[Path], root: Path, target: str, raw) -> None:
    if target == 'linux-x64':
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as tar:
                for path in paths:
                    info = tarfile.TarInfo('ytpd/' + path.relative_to(root).as_posix())
                    info.size = path.stat().st_size
                    info.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                    with path.open('rb') as source:
                        tar.addfile(info, source)
    else:
        with zipfile.ZipFile(raw, 'w', compression=zipfile.ZIP_DEFLATED) as zip_file:
            for path in paths:
                info = zipfile.ZipInfo('ytpd/' + path.relative_to(root).as_posix(), (1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                with path.open('rb') as source, zip_file.open(info, 'w') as destination:
                    shutil.copyfileobj(source, destination)


def flutter_notice_inputs(target: str) -> dict[str, Path]:
    sdk = ROOT / '.tools-stage1/flutter'
    engine = sdk / 'bin/cache/artifacts/engine'
    result = {'flutter.txt': sdk / 'LICENSE', 'dart.txt': sdk / 'bin/cache/dart-sdk/LICENSE'}
    for directory in (engine / 'common', engine / (target + '-release')):
        licenses = sorted(directory.glob('LICENSE*'))
        if not licenses:
            raise PackageError('Pinned Flutter engine notices are missing; bootstrap/build the target first.')
        for path in licenses:
            result['engine-' + path.name] = path
    return result


def build(bundle: Path, output: Path, target: str, runtime: Path | None = None) -> Path:
    if target not in TARGETS or (runtime is not None and target != 'linux-x64'):
        raise PackageError('Unsupported package target.')
    if output.resolve().is_relative_to(bundle.resolve()) or (
            runtime is not None and output.resolve().is_relative_to(runtime.resolve())):
        raise PackageError('Package output must be outside its inputs.')
    pins = read_json(ROOT / 'toolchain.json')
    version = re.search(r'^version: (\S+)$', (ROOT / 'apps/native/pubspec.yaml').read_text(), re.M)[1]
    revision = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain'], text=True).strip())
    output.mkdir(parents=True, exist_ok=True)
    # Some shared output mounts synthesize ownership/mode bits and ignore chmod.
    # Stage in private native temporary storage so those bits cannot turn every
    # runtime module/notice into an executable in the archived inventory.
    with tempfile.TemporaryDirectory(prefix='ytpd-package-') as temporary:
        root = Path(temporary)
        if sys.platform == 'linux' and (
                root.stat().st_uid != os.geteuid() or root.stat().st_mode & 0o077):
            raise PackageError('Package staging requires owned private temporary storage.')
        copy_tree(bundle, root / 'app')
        for path in files(root / 'app'):
            # The only directly launched Flutter bundle file is its entrypoint;
            # native libraries and assets need read permission, not exec bits.
            path.chmod(0o755 if target == 'linux-x64' and
                       path.relative_to(root / 'app').as_posix() == TARGETS[target] else 0o644)
        if not (root / 'app' / TARGETS[target]).is_file():
            raise PackageError('Build the target release bundle first.')
        if runtime is not None:
            validate_runtime(runtime, pins)
            copy_tree(runtime, root / 'app/runtime')
        shutil.copyfile(Path(__file__), root / 'package_manager.py')
        shutil.copyfile(ROOT / 'docs/STAGE8_GUIDE.md', root / 'INSTALL.md')
        shutil.copyfile(ROOT / 'packaging/COMPONENT_NOTICES.md', root / 'COMPONENT_NOTICES.md')
        (root / 'notices').mkdir()
        for name, source in flutter_notice_inputs(target).items():
            if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
                raise PackageError('Flutter/Dart/engine component notice is missing.')
            shutil.copyfile(source, root / 'notices' / name)
        data = {'format': 1, 'channel': 'private-evaluation', 'target': target,
                'version': version, 'revision': revision, 'source_dirty': dirty, 'schema': pins['sqlite_schema_version'],
                'scope': 'linux-media' if runtime is not None else 'foundation',
                'entrypoint': 'app/' + TARGETS[target], 'toolchain': pins,
                'build_environment': {'os': sys.platform, 'architecture': platform.machine(),
                                      'libc': list(platform.libc_ver())},
                'files': inventory(root, windows=target == 'windows-x64')}
        data['package_id'] = identity(data)
        write_json(root / MANIFEST, data)
        verify(root)
        extension = '.tar.gz' if target == 'linux-x64' else '.zip'
        destination = output / f'ytpd-{version}-{target}-{data["package_id"]}{extension}'
        checksum = destination.with_name(destination.name + '.sha256')
        if checksum.exists():
            raise FileExistsError('Package checksum already exists.')
        archive(root, target, destination)
        checksum_created = False
        try:
            with checksum.open('x', encoding='utf-8') as stream:
                checksum_created = True
                stream.write(digest(destination) + '  ' + destination.name + '\n')
                stream.flush()
                os.fsync(stream.fileno())
        except BaseException:
            destination.unlink()
            if checksum_created:
                checksum.unlink(missing_ok=True)
            raise
        return destination


@contextlib.contextmanager
def installation(prefix: Path):
    if sys.platform != 'linux':
        raise PackageError('Versioned installation currently requires Linux.')
    import fcntl
    prefix = prefix.absolute()
    # Never overwrite an unrelated installation or traverse a prefix symlink.
    if prefix.resolve() != prefix or prefix.is_symlink():
        raise PackageError('Install prefix must not contain symbolic links.')
    prefix.mkdir(parents=True, exist_ok=True, mode=0o700)
    if prefix.stat().st_uid != os.geteuid() or prefix.stat().st_mode & 0o022:
        raise PackageError('Use an owned install prefix without group/other write permission.')
    marker = prefix / '.ytpd-install-v1'
    if not marker.exists() and set(p.name for p in prefix.iterdir()) - {'.install.lock'}:
        raise PackageError('Use an empty install prefix.')
    with os.fdopen(os.open(prefix / '.install.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if marker.is_symlink() or marker.exists() and (
                not marker.is_file() or marker.stat().st_size != 19 or marker.read_text() != 'private-evaluation\n'):
            raise PackageError('Unrecognized install prefix.')
        if not marker.exists():
            if set(p.name for p in prefix.iterdir()) != {'.install.lock'}:
                raise PackageError('Use an empty install prefix.')
            marker.write_text('private-evaluation\n')
        releases = prefix / 'releases'
        if releases.is_symlink():
            raise PackageError('Unsafe releases directory.')
        releases.mkdir(exist_ok=True, mode=0o700)
        if releases.stat().st_uid != os.geteuid() or releases.stat().st_mode & 0o022:
            raise PackageError('Unsafe releases directory permissions.')
        yield prefix


def activate(prefix: Path, package_id: str) -> None:
    if not re.fullmatch('[a-f0-9]{16}', package_id):
        raise PackageError('Invalid installed package ID.')
    candidate = prefix / 'releases' / package_id
    data = verify(candidate)
    if data['target'] != 'linux-x64':
        raise PackageError('Cannot activate another target platform.')
    current = prefix / 'current'
    if current.exists() or current.is_symlink():
        if not current.is_symlink() or not re.fullmatch('releases/[a-f0-9]{16}', os.readlink(current)):
            raise PackageError('Unrecognized active installation.')
        previous = verify(prefix / os.readlink(current))
        if previous['schema'] != data['schema']:
            raise PackageError('Schema-changing updates/rollback need a separately tested data migration/backup route.')
    # One atomic pointer update; never modify old binaries, user data or vault.
    temporary = prefix / ('.current-' + os.urandom(12).hex())
    try:
        temporary.symlink_to('releases/' + package_id)
        os.replace(temporary, current)
        sync_directory(prefix)
    finally:
        temporary.unlink(missing_ok=True)


def install(source: Path, prefix: Path) -> str:
    data = verify(source)
    if data['target'] != 'linux-x64':
        raise PackageError('Use the documented Windows portable install route.')
    with installation(prefix) as prefix:
        target = prefix / 'releases' / data['package_id']
        if target.exists() or target.is_symlink():
            if verify(target) != data:
                raise PackageError('Installed package ID collision.')
        else:
            with tempfile.TemporaryDirectory(prefix='.incoming-', dir=prefix) as temporary:
                staged = Path(temporary) / 'package'
                copy_tree(source, staged, durable=True)
                verify(staged)
                os.rename(staged, target)
                sync_directory(prefix / 'releases')
        activate(prefix, data['package_id'])
    return data['package_id']


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    builder = commands.add_parser('build')
    builder.add_argument('--bundle', type=Path, required=True)
    builder.add_argument('--target', choices=TARGETS, required=True)
    builder.add_argument('--output', type=Path, required=True)
    builder.add_argument('--runtime', type=Path)
    checker = commands.add_parser('verify')
    checker.add_argument('package', type=Path)
    installer = commands.add_parser('install')
    installer.add_argument('package', type=Path)
    installer.add_argument('--prefix', type=Path, required=True)
    rollback = commands.add_parser('activate')
    rollback.add_argument('package_id')
    rollback.add_argument('--prefix', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'build':
            print(build(args.bundle, args.output, args.target, args.runtime))
        elif args.command == 'verify':
            print('Verified private evaluation package ' + verify(args.package)['package_id'])
        elif args.command == 'install':
            print('Activated private evaluation package ' + install(args.package, args.prefix))
        else:
            with installation(args.prefix) as prefix:
                activate(prefix, args.package_id)
            print('Activated verified installed package ' + args.package_id)
    except (PackageError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        # Native exceptions may contain private paths; do not print their values.
        parser.exit(1, (str(error) if isinstance(error, PackageError) else
                        'Package operation failed safely; check inputs, space and permissions.') + '\n')


if __name__ == '__main__':
    main()
