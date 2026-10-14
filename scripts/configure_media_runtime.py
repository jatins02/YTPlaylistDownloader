#!/usr/bin/env python3
"""Record this project's existing pinned media tools, without reading .env.

No downloads, system package installation or external provider calls. Native
startup independently validates recorded runtime versions before enabling it.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', type=Path, default=ROOT / '.venv-stage0/bin/python')
    parser.add_argument('--ffmpeg', type=Path, default=ROOT / '.tools-stage0/bin/ffmpeg')
    parser.add_argument('--ffprobe', type=Path, default=ROOT / '.tools-stage0/bin/ffprobe')
    parser.add_argument('--deno', type=Path, default=ROOT / '.tools-stage0/bin/deno')
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('The Stage 3 process adapter is currently proven only on Linux.')
    # Keep the venv invocation path: resolving its Python symlink would bypass
    # the venv packages and accidentally select the system interpreter.
    paths = {key: str(getattr(args, key).absolute()) for key in ['python','ffmpeg','ffprobe','deno']}
    if not all(Path(value).is_file() for value in paths.values()):
        parser.error('Tools are missing. Follow STAGE0_GUIDE.md or provide explicit installed paths.')
    target = ROOT / '.tools-stage3/media-runtime.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(paths, indent=2) + '\n', encoding='utf-8')
    target.chmod(0o600)
    print('Local manifest created. Set YTPD_MEDIA_RUNTIME to: ' + str(target))


if __name__ == '__main__':
    main()
