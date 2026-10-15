#!/usr/bin/env python3
"""Explicit opt-in native provider proof using only this project's development key."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='Opt in to Groq and public artwork requests')
    parser.add_argument('--artwork-only', action='store_true', help='Check public artwork and MP3 readback without a Groq key')
    parser.add_argument('--sources', type=Path, help='JSON list of 1–10 bounded source records (stable track_id/title)')
    args = parser.parse_args()
    if not args.live:
        parser.error('Live provider calls require --live.')
    if args.artwork_only and args.sources:
        parser.error('--sources applies to naming; omit it for --artwork-only.')
    from dotenv import dotenv_values
    env_file = ROOT / '.env'
    if env_file.is_symlink() or (env_file.is_file() and env_file.stat().st_size > 8192):
        raise SystemExit('Refusing an unsafe project dotenv file.')
    settings = dotenv_values(env_file)
    key = os.environ.get('GROQ_API_KEY') or settings.get('GROQ_API_KEY')
    if not key and not args.artwork_only:
        raise SystemExit('No development Groq key configured in this project. Do not paste credentials into chat.')
    sources = [{'track_id': 'known-original', 'title': 'Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers'},
               {'track_id': 'known-modified', 'title': 'Daft Punk - Get Lucky (Slowed + Reverb)'},
               {'track_id': 'unknown-fictional', 'title': 'Unidentified recording qzxv987654'}]
    if args.sources:
        if args.sources.stat().st_size > 65536:
            parser.error('Source fixture exceeds the input bound.')
        sources = json.loads(args.sources.read_text(encoding='utf-8'))
    environment = {name: value for name, value in os.environ.items()
                   if name in {'PATH', 'HOME', 'LANG', 'LC_ALL', 'SSL_CERT_FILE', 'SSL_CERT_DIR',
                               'YTPD_MEDIA_RUNTIME', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0'}}
    payload = {'model': settings.get('GROQ_MODEL') or 'openai/gpt-oss-120b'}
    if not args.artwork_only:
        payload.update(key=key, tracks=sources)
    arguments = ['--live', *(['--artwork-only'] if args.artwork_only else [])]
    # stdin only: no key in argv, child environment, temporary files or reports.
    result = subprocess.run([str(ROOT / '.tools-stage1/flutter/bin/dart'), 'run',
                             'tool/enrichment_live.dart', *arguments], input=json.dumps(payload), text=True,
                            cwd=ROOT / 'apps/native', env=environment, timeout=300, check=False)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
