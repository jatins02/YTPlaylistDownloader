#!/usr/bin/env python3
"""Prepare an isolated, relocatable Linux evaluation runtime from trusted inputs.

Use a standalone Python distribution, never a venv or the system prefix. This
explicit development command installs pinned offline wheels; the app itself never
downloads runtimes or self-updates. No dotenv or user credentials are read.
"""
from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

if __package__:
    from .desktop_package import MAX_FILE, MAX_FILES, MAX_TOTAL, PackageError, digest, files, read_json, safe_name, validate_runtime, write_json
else:
    from desktop_package import MAX_FILE, MAX_FILES, MAX_TOTAL, PackageError, digest, files, read_json, safe_name, validate_runtime, write_json

ROOT = Path(__file__).resolve().parents[1]


def run(args: list[str], directory: Path, limit: int = 1024 * 1024) -> str:
    # Inputs are explicit trusted binaries. Discard raw native/pip errors.
    environment = {k: v for k, v in os.environ.items()
                   if k in ('PATH', 'LANG', 'LC_ALL', 'SSL_CERT_FILE', 'SSL_CERT_DIR')}
    environment.update(HOME=str(directory), TMPDIR=str(directory),
                       PYTHONDONTWRITEBYTECODE='1')
    if Path(args[0]).name == 'python3':
        # -I ignores PYTHONDONTWRITEBYTECODE. The explicit flag also prevents
        # setup verification from modifying this relocatable installation.
        args = [args[0], '-B', *args[1:]]
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(args, cwd=directory, env=environment, stdin=subprocess.DEVNULL,
                                stdout=output, stderr=subprocess.DEVNULL, timeout=300, check=False)
        if result.returncode or output.tell() > limit:
            raise PackageError('Runtime preparation command failed; check trusted inputs and connectivity.')
        output.seek(0)
        return output.read(limit).decode('utf-8')


def standalone(source: Path, destination: Path) -> None:
    source = source.resolve(strict=True)
    if (source in {Path('/usr'), Path('/usr/local'), Path(sys.base_prefix).resolve(), Path(sys.prefix).resolve()} or
            (source / 'pyvenv.cfg').exists() or not (source / 'lib/python3.14/os.py').is_file()):
        raise PackageError('Supply a complete standalone Python 3.14 installation, not a venv.')
    # Internal file aliases are materialized so the finished runtime has no
    # symlinks. External aliases and directory links never enter the package.
    destination.mkdir()
    count, total = 0, 0
    for directory, dirs, names in os.walk(source, followlinks=False):
        dirs[:] = [d for d in dirs if d not in {'test', 'tests', '__pycache__', 'idlelib', 'turtledemo'}]
        if Path(directory) == source / 'share':
            # No interactive terminal UI is used by the native media workers.
            # The terminal database has case-aliases unsuitable for a portable
            # package; system terminfo remains available to optional stdlib UI.
            dirs[:] = [d for d in dirs if d != 'terminfo']
        for name in dirs:
            safe_name(Path(directory) / name)
            if (Path(directory) / name).is_symlink():
                raise PackageError('Standalone Python contains a directory link.')
        relative = Path(directory).relative_to(source)
        target = destination / relative
        target.mkdir(exist_ok=True)
        for name in names:
            path = Path(directory) / name
            safe_name(path)
            if not path.resolve(strict=True).is_relative_to(source):
                raise PackageError('Standalone Python references external files.')
            if not path.is_file():
                raise PackageError('Standalone Python contains a special file.')
            if path.suffix == '.pyc':
                continue
            size = path.stat().st_size
            count, total = count + 1, total + size
            if size > MAX_FILE or count > MAX_FILES or total > MAX_TOTAL:
                raise PackageError('Standalone Python exceeds the package limits.')
            copied = target / name
            shutil.copyfile(path, copied)
            copied.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)


def prepare(python_home: Path, ffmpeg: Path, ffprobe: Path, deno: Path,
            wheelhouse: Path, deno_license: Path, output: Path) -> None:
    if sys.platform != 'linux' or os.uname().machine != 'x86_64':
        raise PackageError('This runtime is currently Linux x64 only.')
    if output.exists() or output.is_symlink():
        raise PackageError('Choose a new output directory.')
    pins = read_json(ROOT / 'toolchain.json')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.runtime-', dir=output.parent) as temporary:
        work = Path(temporary)
        root = work / 'runtime'
        root.mkdir()
        standalone(python_home, root / 'python')
        binaries = root / 'bin'
        binaries.mkdir()
        for name, source in (('ffmpeg', ffmpeg), ('ffprobe', ffprobe), ('deno', deno)):
            if not source.is_file() or not stat.S_ISREG(source.stat().st_mode):
                raise PackageError('Missing trusted media binary.')
            shutil.copyfile(source, binaries / name)
            (binaries / name).chmod(0o755)
        python = root / 'python/bin/python3'
        if run([str(python), '-I', '-c', 'import sys;print(sys.version.split()[0])'], work).strip() != pins['media_runtime_versions']['python']:
            raise PackageError('Standalone Python does not match the recorded version.')
        run([str(python), '-I', '-m', 'pip', '--isolated', '--disable-pip-version-check',
             'install', '--no-input', '--no-compile', '--only-binary=:all:', '--no-deps',
             '--no-index', '--find-links', str(wheelhouse),
             '-r', str(ROOT / 'requirements-native-runtime.lock')], work)
        run([str(python), '-I', '-m', 'pip', '--isolated', 'check'], work)
        # Wheel self-tests contain public sample signing keys and are not needed
        # by the app. Keep runtime code/notices, not test fixtures or bytecode.
        for directory, dirs, _ in os.walk(root / 'python/lib/python3.14/site-packages'):
            for name in list(dirs):
                if name in {'test', 'tests', 'SelfTest', '__pycache__'}:
                    shutil.rmtree(Path(directory) / name)
                    dirs.remove(name)
        # -B still reads existing caches. Checked-hash caches avoid recompiling
        # the large extractor on every guarded command without modifying the
        # installed package. Virtual source paths contain no builder directory.
        run([str(python), '-I', '-m', 'compileall', '-q', '--invalidation-mode',
             'checked-hash', '-s', str(root), '-p', '/ytpd-runtime',
             str(root / 'python/lib/python3.14')], work)
        versions = json.loads(run([str(python), '-I', '-c',
            'import importlib.metadata,json;print(json.dumps({d.metadata["Name"].lower():d.version for d in importlib.metadata.distributions()}))'], work))
        for name, pin in {'yt-dlp': pins['media_runtime_versions']['yt_dlp'],
                          'yt-dlp-ejs': pins['media_runtime_versions']['ejs'],
                          **pins['metadata_runtime_versions']}.items():
            if versions.get(name) != pin:
                raise PackageError('Installed runtime packages do not match recorded versions.')
        notices = root / 'notices'
        notices.mkdir()
        components = {}
        python_notices = []
        for path in (root / 'python').glob('**/LICENSE*'):
            if 'site-packages' not in path.parts and path.is_file():
                python_notices.append(path.relative_to(root).as_posix())
        if not python_notices:
            raise PackageError('Standalone Python license files are missing.')
        components['python'] = {'version': pins['media_runtime_versions']['python'], 'notices': sorted(python_notices)}
        # Preserve every installed wheel's own license files, not just its name.
        for path in (root / 'python/lib/python3.14/site-packages').glob('*.dist-info'):
            metadata = importlib.metadata.PathDistribution(path)
            name = metadata.metadata['Name'].lower()
            licenses = [p.relative_to(root).as_posix() for p in path.rglob('*')
                        if p.is_file() and ('license' in p.name.lower() or 'copying' in p.name.lower() or 'notice' in p.name.lower())]
            if not licenses:
                raise PackageError('An installed Python component is missing license texts.')
            components[name] = {'version': metadata.version, 'notices': sorted(licenses)}
        deno_version = run([str(binaries / 'deno'), '--version'], work)
        if not deno_version.startswith('deno ' + pins['media_runtime_versions']['deno'] + ' '):
            raise PackageError('Deno version mismatch.')
        if deno_license.is_symlink() or not deno_license.is_file() or not 0 < deno_license.stat().st_size <= 4 * 1024 * 1024:
            raise PackageError('Supply the selected Deno version\'s upstream license text.')
        shutil.copyfile(deno_license, notices / 'deno.txt')
        components['deno'] = {'version': pins['media_runtime_versions']['deno'], 'notices': ['notices/deno.txt']}
        for name in ('ffmpeg', 'ffprobe'):
            version = run([str(binaries / name), '-version'], work)
            if not version.startswith(name + ' version ' + pins['media_runtime_versions'][name] + ' '):
                raise PackageError('Codec version mismatch.')
            (notices / (name + '-build.txt')).write_text(version)
            (notices / (name + '-license.txt')).write_text(run([str(binaries / name), '-L'], work))
        components['ffmpeg'] = {'version': pins['media_runtime_versions']['ffmpeg'],
                                'notices': ['notices/ffmpeg-license.txt', 'notices/ffmpeg-build.txt',
                                            'notices/ffprobe-license.txt', 'notices/ffprobe-build.txt']}
        tools = {name: {'path': path, 'bytes': (root / path).stat().st_size,
                        'sha256': digest(root / path)} for name, path in
                 {'python': 'python/bin/python3', 'ffmpeg': 'bin/ffmpeg',
                  'ffprobe': 'bin/ffprobe', 'deno': 'bin/deno'}.items()}
        write_json(root / 'media-runtime.json', {'format': 1, 'tools': tools})
        write_json(root / 'COMPONENTS.json', {'redistribution': 'unresolved', 'components': components})
        files(root)
        validate_runtime(root, pins)
        os.rename(root, output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('python-home', 'ffmpeg', 'ffprobe', 'deno', 'wheelhouse', 'deno-license', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.python_home.absolute(), args.ffmpeg.absolute(), args.ffprobe.absolute(),
                args.deno.absolute(), args.wheelhouse.absolute(), args.deno_license.absolute(), args.output.absolute())
        print('Prepared private evaluation runtime; public redistribution remains unresolved.')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, (str(error) if isinstance(error, PackageError) else
                        'Runtime preparation failed; check trusted inputs and connectivity.') + '\n')


if __name__ == '__main__':
    main()
