#!/usr/bin/env python3
"""Launch an unpacked evaluation release in a disposable Linux desktop session.

Startup/SQLite/helper discovery only: no UI gestures, live source, user key,
speaker/chooser or physical-device acceptance is inferred from this smoke check.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

if __package__:
    from .desktop_package import PackageError, verify
    from .test_linux_native import unmount_document_portal
else:
    from desktop_package import PackageError, verify
    from test_linux_native import unmount_document_portal


def launch(package: Path, session: Path) -> None:
    data = verify(package)
    if data['target'] != 'linux-x64':
        raise PackageError('Linux package required.')
    # D-Bus was started by this helper; all storage and the keyring are temporary.
    subprocess.run(
        ['gnome-keyring-daemon', '--unlock', '--daemonize', '--components=secrets',
         '--control-directory', str(session / 'keyring-control')],
        input=b'\n', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True,
    )
    environment = {k: v for k, v in os.environ.items()
                   if k in ('PATH', 'LD_LIBRARY_PATH', 'LANG', 'LC_ALL', 'DBUS_SESSION_BUS_ADDRESS')}
    environment.update({
        'HOME': str(session / 'home'),
        'XDG_DATA_HOME': str(session / 'data'),
        'XDG_CONFIG_HOME': str(session / 'config'),
        'XDG_CACHE_HOME': str(session / 'cache'),
        'XDG_RUNTIME_DIR': str(session / 'run'),
        'GTK_USE_PORTAL': '0', 'GIO_USE_VFS': 'local',
    })
    process = subprocess.Popen(
        ['xvfb-run', '-a', str(package / data['entrypoint'])], cwd=session,
        env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True,
    )
    try:
        deadline, ready = time.monotonic() + 30, False
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise PackageError('The release exited during isolated startup.')
            databases = list((session / 'data').rglob('drafts.sqlite'))
            if len(databases) == 1:
                database = databases[0]
                try:
                    with sqlite3.connect('file:' + quote(str(database)) + '?mode=ro', uri=True, timeout=1) as connection:
                        schema = connection.execute('pragma user_version').fetchone()[0]
                        healthy = connection.execute('pragma quick_check').fetchone()[0] == 'ok'
                    helpers = all((database.parent / name).is_file() for name in
                                  ('process_guard.py', 'metadata_tools.py', 'export_tools.py'))
                    ready = healthy and schema == data['schema'] and (
                        data['scope'] == 'foundation' or helpers)
                    if ready:
                        break
                except sqlite3.Error:
                    pass  # Startup can still be creating/migrating its own DB.
            time.sleep(0.1)
        if not ready:
            raise PackageError('Isolated release storage/runtime discovery did not finish.')
        # Allow asynchronous startup to settle; this is not a UI/media acceptance.
        try:
            process.wait(timeout=3)
            raise PackageError('The release did not remain open after startup.')
        except subprocess.TimeoutExpired:
            pass
    finally:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        unmount_document_portal(session / 'run')
    print('Isolated release startup passed: SQLite schema/integrity and package runtime discovery. '
          'Manual UI, source, audio and device gates remain open.')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('--session', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('Linux execution required.')
    try:
        if args.session is not None:
            launch(args.package.absolute(), args.session)
            return
        for tool in ('dbus-run-session', 'gnome-keyring-daemon', 'xvfb-run', 'Xvfb', 'xauth'):
            if not shutil.which(tool):
                raise PackageError('Install the documented isolated Linux test prerequisites.')
        with tempfile.TemporaryDirectory(prefix='ytpd-package-session-') as temporary:
            root = Path(temporary)
            for name in ('home', 'data', 'config', 'cache', 'run', 'keyring-control'):
                (root / name).mkdir(mode=0o700)
            environment = {k: v for k, v in os.environ.items()
                           if k in ('PATH', 'LD_LIBRARY_PATH', 'LANG', 'LC_ALL')}
            environment.update(HOME=str(root / 'home'), XDG_DATA_HOME=str(root / 'data'),
                               XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                               XDG_RUNTIME_DIR=str(root / 'run'))
            result = subprocess.run(
                ['dbus-run-session', '--', sys.executable, str(Path(__file__).resolve()),
                 str(args.package.absolute()), '--session', str(root)], env=environment, check=False,
            )
            if result.returncode:
                raise PackageError('The isolated release startup check failed.')
    except (PackageError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, (str(error) if isinstance(error, PackageError) else
                        'Isolated package startup could not finish safely.') + '\n')


if __name__ == '__main__':
    main()
