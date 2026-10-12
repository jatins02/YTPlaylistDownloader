#!/usr/bin/env python3
"""Install the recorded official SDK into an ignored project-local directory."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    manifest = json.loads((ROOT / "toolchain.json").read_text(encoding="utf-8"))
    sdk = ROOT / ".tools-stage1/flutter"
    if not sdk.exists():
        sdk.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "clone", "--depth", "1", "--branch", manifest["flutter_version"],
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
    subprocess.run([str(flutter), "--version"], check=True)
    print(f"SDK verified. Add this directory to PATH: {sdk / 'bin'}")


if __name__ == "__main__":
    main()
