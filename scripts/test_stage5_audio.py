#!/usr/bin/env python3
"""Opt-in Linux review acceptance with a disposable local audio output server.

Uses the installed official PulseAudio executable (or an explicit extracted
binary). Never changes the desktop server, records a microphone or calls a live
source/provider. The Flutter test captures only this private synthetic sink.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pulse-binary', default=shutil.which('pulseaudio'))
    parser.add_argument('--module-directory', type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux' or not args.pulse_binary:
        parser.error('Linux and an official PulseAudio executable are required.')
    manifest = os.environ.get('STAGE3_TEST_RUNTIME')
    if not manifest or not Path(manifest).is_file():
        parser.error('Set STAGE3_TEST_RUNTIME to the pinned project media manifest.')
    executable = str(Path(args.pulse_binary).resolve(strict=True))
    version = subprocess.run([executable, '--version'], capture_output=True, text=True, check=True)
    if version.stdout.strip() != 'pulseaudio 17.0':
        parser.error('This acceptance setup is recorded for PulseAudio 17.0.')
    project = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='ytpd-stage5-audio-') as temporary:
        root = Path(temporary)
        socket = root / 'native'
        environment = {name: os.environ[name] for name in ('PATH', 'HOME', 'LANG', 'LC_ALL', 'LD_LIBRARY_PATH') if name in os.environ}
        for variable in ('PULSE_RUNTIME_PATH', 'PULSE_STATE_PATH', 'PULSE_CONFIG_PATH'):
            directory = root / variable.lower()
            directory.mkdir(mode=0o700)
            environment[variable] = str(directory)
        command = [executable, '--daemonize=no', '--exit-idle-time=-1', '--disable-shm=yes',
                   '--use-pid-file=no', '--log-target=stderr', '-n']
        if args.module_directory:
            modules = str(args.module_directory.resolve(strict=True))
            command += ['--dl-search-path=' + modules]
            environment['LD_LIBRARY_PATH'] = os.pathsep.join(filter(None, (modules, environment.get('LD_LIBRARY_PATH'))))
        # Anonymous access is confined to a socket inside this mode-0700 test
        # directory; no TCP listener or change to the user's server is made.
        command += ['-L', f'module-native-protocol-unix socket={socket} auth-anonymous=1',
                    '-L', 'module-null-sink sink_name=ytpd_stage5 rate=44100 channels=2']
        with (root / 'server.log').open('wb') as log:
            server = subprocess.Popen(['dbus-run-session', '--', *command], env=environment, stdout=log, stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic() + 10
                while not socket.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError('The isolated audio test server could not start.')
                    time.sleep(0.05)
                child = os.environ.copy()
                child['YTPD_AUDIO_SOCKET'] = str(socket)
                return subprocess.run([sys.executable, str(project / 'scripts/test_linux_native.py'),
                                       '--test', 'review_test.dart'], cwd=project, env=child, check=False).returncode
            finally:
                try:
                    os.killpg(server.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(server.pid, signal.SIGKILL)
                    server.wait(timeout=5)


if __name__ == '__main__':
    raise SystemExit(main())
