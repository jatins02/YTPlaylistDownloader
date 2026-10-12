#!/usr/bin/env python3
"""Check the native release bundle for accidentally included dotenv/API keys."""
from __future__ import annotations

from pathlib import Path
import re
import sys

KEY = re.compile(rb"gsk_[A-Za-z0-9_-]{20,256}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python scripts/check_native_bundle.py <release-bundle-directory>")
    root = Path(sys.argv[1])
    if not root.is_dir():
        raise SystemExit("Release bundle is missing; compile the native app first.")
    count = 0
    for file in root.rglob("*"):
        if not file.is_file():
            continue
        count += 1
        if file.name == ".env" or file.name.startswith(".env."):
            raise SystemExit(f"Unexpected dotenv asset: {file.relative_to(root)}")
        # Retain overlap so a token spanning a chunk boundary is still found.
        with file.open("rb") as stream:
            previous = b""
            while chunk := stream.read(1024 * 1024):
                data = previous + chunk
                if KEY.search(data):
                    raise SystemExit(f"Possible literal API key in: {file.relative_to(root)}")
                previous = data[-260:]
    if count == 0:
        raise SystemExit("Release bundle is empty.")
    print(f"Checked {count} release files: no dotenv asset or literal Groq API key found.")


if __name__ == "__main__":
    main()
