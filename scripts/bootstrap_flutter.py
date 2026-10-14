#!/usr/bin/env python3
"""Install the recorded official SDK into an ignored project-local directory."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    manifest = json.loads((ROOT / "toolchain.json").read_text(encoding="utf-8"))
    sdk = ROOT / ".tools-stage1/flutter"
    if not sdk.exists():
        sdk.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "clone", "--config", "core.longpaths=true", "--depth", "1", "--branch", manifest["flutter_version"],
             "https://github.com/flutter/flutter.git", str(sdk)], check=True,
        )
    revision = subprocess.check_output(["git", "-C", str(sdk), "rev-parse", "HEAD"], text=True).strip()
    if revision != manifest["flutter_revision"]:
        raise SystemExit("Existing SDK does not match toolchain.json. Move it aside before retrying.")
    changes = subprocess.check_output(
        ["git", "-C", str(sdk), "status", "--porcelain", "--untracked-files=no"], text=True,
    ).strip()
    if changes:
        raise SystemExit("Existing SDK has modified tracked files. Use a clean pinned SDK before building.")
    flutter = sdk / "bin" / ("flutter.bat" if sys.platform == "win32" else "flutter")
    if sys.platform == "linux":
        # Flutter's SDK downloader retries HTTP statuses, but curl does not
        # normally retry an interrupted HTTP/2 stream (exit 92). Scope these
        # settings to this bootstrap, leaving the pinned SDK and user's curl
        # configuration untouched.
        with tempfile.TemporaryDirectory(prefix="ytpd-flutter-curl-") as directory:
            Path(directory, ".curlrc").write_text(
                "http1.1\nretry-all-errors\nconnect-timeout = 30\nmax-time = 180\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment["CURL_HOME"] = directory
            subprocess.run([str(flutter), "--version"], check=True, env=environment)
    else:
        subprocess.run([str(flutter), "--version"], check=True)
    print(f"SDK verified. Add this directory to PATH: {sdk / 'bin'}")


if __name__ == "__main__":
    main()
