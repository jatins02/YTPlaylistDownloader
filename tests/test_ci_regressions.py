"""Offline regressions for the observed GitHub Actions failures."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from stage0.core import CheckError, command


class CiRegressions(unittest.TestCase):
    def test_strict_command_rejects_zero_exit_errors_without_exposing_diagnostics(self):
        args = [sys.executable, '-I', '-c',
                'import sys;print("private decoder diagnostic",file=sys.stderr);print("output")']
        self.assertEqual(command(args).strip(), b'output')
        with self.assertRaises(CheckError) as raised:
            command(args, require_clean_stderr=True)
        self.assertEqual(raised.exception.code, 'TOOL_FAILED')
        self.assertNotIn('private decoder diagnostic', str(raised.exception))

    @unittest.skipUnless(
        sys.platform == 'linux' and shutil.which('git') and
        (Path(__file__).resolve().parents[1] / 'scripts/bootstrap_flutter.py').is_file(),
        'Native Linux bootstrap helper and Git required; absent from the CLI-only image',
    )
    def test_bootstrap_scopes_download_settings_and_keeps_revision_guard(self):
        from scripts import bootstrap_flutter
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sdk = root / '.tools-stage1/flutter'
            (sdk / 'bin').mkdir(parents=True)
            report = root / 'download-settings.json'
            flutter = sdk / 'bin/flutter'
            flutter.write_text(
                '#!' + sys.executable + '\n'
                'import json,os\nfrom pathlib import Path\n'
                'config=Path(os.environ["CURL_HOME"])/".curlrc"\n'
                'Path(' + repr(str(report)) + ').write_text(json.dumps('
                '{"directory":str(config.parent),"settings":config.read_text()}))\n',
                encoding='utf-8',
            )
            flutter.chmod(0o755)
            subprocess.run(['git', 'init', '-q', str(sdk)], check=True)
            subprocess.run(['git', '-C', str(sdk), 'add', 'bin/flutter'], check=True)
            subprocess.run(['git', '-C', str(sdk), '-c', 'user.name=Fixture',
                            '-c', 'user.email=fixture@example.invalid',
                            'commit', '-qm', 'Synthetic SDK'], check=True)
            revision = subprocess.check_output(
                ['git', '-C', str(sdk), 'rev-parse', 'HEAD'], text=True).strip()
            manifest = root / 'toolchain.json'
            manifest.write_text(json.dumps({'flutter_revision': revision}), encoding='utf-8')
            previous = os.environ.get('CURL_HOME')
            with patch.object(bootstrap_flutter, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                bootstrap_flutter.main()
                result = json.loads(report.read_text())
                self.assertIn('http1.1', result['settings'])
                self.assertIn('retry-all-errors', result['settings'])
                self.assertIn('max-time = 180', result['settings'])
                self.assertFalse(Path(result['directory']).exists())
                self.assertEqual(os.environ.get('CURL_HOME'), previous)
                report.unlink()
                manifest.write_text(json.dumps({'flutter_revision': '0' * 40}), encoding='utf-8')
                with self.assertRaises(SystemExit):
                    bootstrap_flutter.main()
                self.assertFalse(report.exists())
                manifest.write_text(json.dumps({'flutter_revision': revision}), encoding='utf-8')
                flutter.write_text('modified tracked SDK', encoding='utf-8')
                with self.assertRaises(SystemExit):
                    bootstrap_flutter.main()
                self.assertFalse(report.exists())
