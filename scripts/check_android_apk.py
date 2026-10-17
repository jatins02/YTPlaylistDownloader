#!/usr/bin/env python3
"""Inspect uncompressed test-APK files without following links or reading keys.

This checks package completeness and accidental secrets, not signing validity or
phone execution. Use Android's apksigner and actual-device acceptance separately.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import stat
import tempfile
import zipfile

if __package__:
    from .desktop_package import MAX_FILE, MAX_FILES, MAX_TOTAL, PackageError, digest, inventory, relative, safe_name
else:
    from desktop_package import MAX_FILE, MAX_FILES, MAX_TOTAL, PackageError, digest, inventory, relative, safe_name


def check(apk: Path) -> str:
    if apk.is_symlink() or not apk.is_file() or apk.stat().st_size > MAX_FILE:
        raise PackageError('Missing or oversized test APK.')
    with tempfile.TemporaryDirectory(prefix='ytpd-apk-check-') as temporary:
        root = Path(temporary)
        with zipfile.ZipFile(apk) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_FILES or sum(e.file_size for e in entries) > MAX_TOTAL:
                raise PackageError('APK exceeds the file or byte limit.')
            names = set()
            for entry in entries:
                name = relative(entry.filename.rstrip('/') if entry.is_dir() else entry.filename)
                safe_name(Path(name))
                if name in names or entry.flag_bits & 1 or entry.file_size > MAX_FILE:
                    raise PackageError('Duplicate, encrypted or oversized APK entry.')
                names.add(name)
                kind = stat.S_IFMT(entry.external_attr >> 16)
                if kind not in (0, stat.S_IFREG, stat.S_IFDIR) or (
                        kind != 0 and (kind == stat.S_IFDIR) != entry.is_dir()):
                    raise PackageError('APK links and special files are forbidden.')
                target = root / name
                if entry.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(entry) as source, target.open('xb') as destination:
                        shutil.copyfileobj(source, destination)
                    if target.stat().st_size != entry.file_size:
                        raise PackageError('APK entry length mismatch.')
        required = {'AndroidManifest.xml', 'classes.dex', 'assets/flutter_assets/NOTICES.Z',
                    'lib/arm64-v8a/libflutter.so'}
        if not required.issubset(names):
            raise PackageError('Incomplete arm64 Flutter test APK or component notices.')
        inventory(root, windows=True)
    return digest(apk)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    args = parser.parse_args()
    try:
        print('Verified uncompressed foundation APK assets; SHA-256 ' + check(args.apk))
    except (PackageError, OSError, ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, (str(error) if isinstance(error, PackageError) else
                        'Test APK inspection failed safely.') + '\n')


if __name__ == '__main__':
    main()
