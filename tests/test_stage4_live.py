"""Credential and opt-in boundaries of the development acceptance launcher."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'stage4_live', Path(__file__).resolve().parents[1] / 'scripts/test_stage4_live.py')
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class LiveLauncherTests(unittest.TestCase):
    def run_launcher(self, args, key=None):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(launcher, 'ROOT', Path(directory)), \
                patch('sys.argv', ['test_stage4_live.py', *args]), \
                patch.dict(launcher.os.environ, {'UNRELATED_SECRET': 'synthetic-secret'}, clear=True), \
                patch('dotenv.dotenv_values', return_value={'GROQ_API_KEY': key} if key else {}), \
                patch.object(launcher.subprocess, 'run') as run, \
                contextlib.redirect_stderr(io.StringIO()):
            run.return_value.returncode = 0
            with self.assertRaises(SystemExit) as error:
                launcher.main()
            return error.exception.code, run

    def test_every_mode_requires_live_opt_in(self):
        code, run = self.run_launcher(['--artwork-only'])
        self.assertEqual(code, 2)
        run.assert_not_called()

    def test_artwork_only_needs_no_key_and_sends_no_credentials(self):
        code, run = self.run_launcher(['--live', '--artwork-only'], 'synthetic-key')
        self.assertEqual(code, 0)
        call = run.call_args
        self.assertIn('--artwork-only', call.args[0])
        payload = json.loads(call.kwargs['input'])
        self.assertNotIn('key', payload)
        self.assertNotIn('tracks', payload)
        self.assertNotIn('UNRELATED_SECRET', call.kwargs['env'])

    def test_naming_key_goes_only_to_stdin_and_missing_key_stops(self):
        code, run = self.run_launcher(['--live'])
        self.assertNotEqual(code, 0)
        run.assert_not_called()
        code, run = self.run_launcher(['--live'], 'synthetic-key')
        self.assertEqual(code, 0)
        call = run.call_args
        self.assertEqual(json.loads(call.kwargs['input'])['key'], 'synthetic-key')
        self.assertNotIn('synthetic-key', str(call.args))
        self.assertNotIn('synthetic-key', str(call.kwargs['env']))


if __name__ == '__main__':
    unittest.main()
