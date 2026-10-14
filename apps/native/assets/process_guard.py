"""Linux tool supervisor. No shell, provider logic or credential access."""
from __future__ import annotations
import ctypes
import os
import signal
import resource
import subprocess
import sys

child: subprocess.Popen | None = None


def kill_children() -> None:
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def stop(_signum: int, _frame: object) -> None:
    kill_children()
    os._exit(143)


def main() -> int:
    global child
    if sys.platform != 'linux' or len(sys.argv) < 4:
        return 126
    try:
        limit = int(sys.argv[1])
        if not 1 <= limit <= 1024 * 1024 * 1024:
            return 126
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
    except (ValueError, OSError):
        return 126
    parent = os.getppid()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    libc.prctl.restype = ctypes.c_int
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
        return 126
    if parent == 1 or os.getppid() != parent:
        return 143
    # Defer termination across the spawn/assignment gap. This supervisor is
    # single-threaded; restore the child's signal mask before its exec.
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    try:
        child = subprocess.Popen(sys.argv[2:], shell=False, start_new_session=True,
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, mask))
    except OSError:
        return 126
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
    try:
        result = child.wait()
        return result if result >= 0 else 128 - result
    finally:
        # Even successful commands cannot leave descendants holding pipes/files.
        kill_children()


if __name__ == '__main__':
    raise SystemExit(main())
