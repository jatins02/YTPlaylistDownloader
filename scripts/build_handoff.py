#!/usr/bin/env python3
"""Assemble an offline, private evaluation handoff from a verified package.

Accepts an already unpacked, trusted Stage 8 package, never an untrusted archive.
Does not execute binaries, download dependencies, read credentials, or approve a
public release. The package's original build revision remains authoritative.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import zipfile

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts import desktop_package as package

GUIDES = ('docs/USER_GUIDE.md', 'docs/MAINTENANCE.md', 'docs/STAGE9_GUIDE.md',
          'docs/STAGE8_GUIDE.md', 'docs/STAGE8_RESULTS.json',
          'docs/PROJECT_STATUS.md', 'packaging/COMPONENT_NOTICES.md')


def build(root: Path, output: Path) -> dict:
    """Snapshot and reverify before archiving; publish one no-clobber ZIP.

    Only named guidance and the explicit package are read. Temporary files are
    private and disposable; installed app data, vaults and exports are untouched.
    """
    if output.resolve().is_relative_to(root.resolve()):
        raise package.PackageError('Handoff output must be outside the package.')
    original = package.verify(root)
    if original['source_dirty']:
        raise package.PackageError('Build a clean-source package before handoff.')
    if original['toolchain'] != package.read_json(package.ROOT / 'toolchain.json'):
        raise package.PackageError('Package pins differ from this handoff checkout.')
    with tempfile.TemporaryDirectory(prefix='ytpd-handoff-') as temporary:
        staging = Path(temporary)
        snapshot = staging / 'ytpd'
        package.copy_tree(root, snapshot)
        verified = package.verify(snapshot)
        if verified != original:
            raise package.PackageError('Package changed while creating the handoff.')
        payload = staging / 'handoff'
        payload.mkdir()
        for name in GUIDES:
            package.relative(name)
            source = package.ROOT / name
            if source.is_symlink() or not source.is_file() or source.stat().st_size > 1024 * 1024:
                raise package.PackageError('Missing, linked or oversized handoff guidance.')
            destination = payload / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            destination.chmod(0o644)
        records = package.inventory(payload, windows=True)
        suffix = '.tar.gz' if verified['target'] == 'linux-x64' else '.zip'
        archive = payload / f"ytpd-{verified['version']}-{verified['target']}-{verified['package_id']}{suffix}"
        package.archive(snapshot, verified['target'], archive)
        # The compressed aggregate may exceed the per-component media/package cap.
        # Its contents have already passed the bounded package inventory twice.
        records[archive.name] = {'bytes': archive.stat().st_size,
                                 'sha256': package.digest(archive), 'executable': False}
        report = {
            'format': 1,
            'channel': 'private-evaluation',
            'public_release_approved': False,
            'physical_device_acceptance': 'not assessed by this tool',
            'package_id': verified['package_id'],
            'build_revision': verified['revision'],
            'build_source_dirty': verified['source_dirty'],
            'version': verified['version'],
            'schema': verified['schema'],
            'target': verified['target'],
            'scope': verified['scope'],
            'toolchain': verified['toolchain'],
            'build_environment': verified['build_environment'],
            'package_inventory_files': len(verified['files']),
            'package_archive': archive.name,
            'files': records,
            'checks': ['complete package inventory and executable modes',
                       'snapshot reverified against original package identity',
                       'package and guidance scanned for private files and literal keys'],
            'limitations': ['Checksums do not authenticate the publisher.',
                            'Guides describe current limits; they are not device acceptance evidence.',
                            'Public licensing, signing and platform gates remain in docs/STAGE9_GUIDE.md.'],
        }
        package.write_json(payload / 'handoff.json', report)
        # Hash the report as well as every payload file; this list is not a signature.
        names = sorted([*records, 'handoff.json'])
        (payload / 'SHA256SUMS').write_text(''.join(
            f'{package.digest(payload / name)}  {name}\n' for name in names), encoding='utf-8')
        output.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation preserves any previous delivery, including symlinks.
        raw = output.open('xb')
        try:
            with zipfile.ZipFile(raw, 'w', compression=zipfile.ZIP_STORED) as bundle:
                for name in [*names, 'SHA256SUMS']:
                    bundle.write(payload / name, arcname=name)
            raw.flush()
            os.fsync(raw.fileno())
        except BaseException:
            raw.close()
            output.unlink(missing_ok=True)
            raise
        finally:
            raw.close()
    return {'file': output.name, 'bytes': output.stat().st_size,
            'sha256': package.digest(output), 'package_id': verified['package_id'],
            'build_revision': verified['revision'], 'scope': verified['scope'],
            'public_release_approved': False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True,
                        help='Trusted, unpacked Stage 8 ytpd directory')
    parser.add_argument('--output', type=Path, required=True, help='New handoff ZIP; never overwritten')
    args = parser.parse_args()
    try:
        result = build(args.package, args.output)
    except (package.PackageError, OSError, zipfile.BadZipFile):
        # Never include arbitrary OS filenames, package text or secrets in errors.
        parser.exit(1, 'Handoff failed: verify the package, pins, guidance, free space and unused output path.\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
