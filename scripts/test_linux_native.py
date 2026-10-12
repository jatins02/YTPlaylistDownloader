#!/usr/bin/env python3
"""Run the native foundation test in a disposable display, D-Bus and keyring."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main() -> int:
    if sys.platform != "linux":
        raise SystemExit("This helper requires Linux. Use flutter test -d windows on Windows.")
    flutter = shutil.which("flutter")
    if not flutter:
        raise SystemExit("Add the pinned Flutter SDK's bin directory to PATH first.")
    if len(sys.argv) == 2 and sys.argv[1] == "--inside-session":
        subprocess.run(
            ["gnome-keyring-daemon", "--unlock", "--daemonize", "--components=secrets",
             "--control-directory", os.environ["YT_PD_TEST_CONTROL"]],
            input="\n", text=True, check=True,
        )
        try:
            return subprocess.run(
                ["xvfb-run", "-a", flutter, "test", "integration_test/foundation_test.dart", "-d", "linux"],
                cwd=Path(__file__).resolve().parents[1] / "apps/native",
                check=False,
            ).returncode
        finally:
            # GTK may activate the document portal. Unmount its disposable FUSE
            # directory while D-Bus is still alive, before TemporaryDirectory
            # cleanup; disconnected portal mounts otherwise produce ENOTCONN.
            document_mount = str(Path(os.environ["XDG_RUNTIME_DIR"]) / "doc")
            mounts = Path("/proc/self/mountinfo").read_text(encoding="utf-8").splitlines()
            if any(line.split()[4] == document_mount for line in mounts):
                unmount = shutil.which("fusermount3") or shutil.which("fusermount")
                if not unmount:
                    raise SystemExit("Cannot clean up the disposable document-portal mount: install fuse3.")
                subprocess.run([unmount, "-u", document_mount], check=True)
    for executable in ["dbus-run-session", "gnome-keyring-daemon", "xvfb-run", "Xvfb", "xauth"]:
        if not shutil.which(executable):
            raise SystemExit(f"Missing test dependency: {executable}")
    with tempfile.TemporaryDirectory(prefix="ytpd-native-session-") as temporary:
        root = Path(temporary)
        environment = os.environ.copy()
        # Do not unlock or modify the developer's normal keyring or app data.
        for variable, folder in {
            "XDG_DATA_HOME": "data", "XDG_CONFIG_HOME": "config",
            "XDG_CACHE_HOME": "cache", "XDG_RUNTIME_DIR": "runtime",
            "YT_PD_TEST_CONTROL": "keyring-control",
        }.items():
            location = root / folder
            location.mkdir(mode=0o700)
            environment[variable] = str(location)
        environment.pop("GNOME_KEYRING_CONTROL", None)
        environment["GTK_USE_PORTAL"] = "0"
        environment["GIO_USE_VFS"] = "local"
        return subprocess.run(
            ["dbus-run-session", "--", sys.executable, str(Path(__file__).resolve()), "--inside-session"],
            env=environment, check=False,
        ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
