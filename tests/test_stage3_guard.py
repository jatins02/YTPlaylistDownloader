"""Actual Linux crash/cancellation guarantees for the bundled supervisor."""
from __future__ import annotations
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

GUARD = Path(__file__).resolve().parents[1] / 'apps/native/assets/process_guard.py'


@unittest.skipUnless(sys.platform == 'linux', 'Linux-specific supervisor; no other-platform claim')
class ProcessGuardTests(unittest.TestCase):
    def test_parent_crash_stops_descendant_writes(self) -> None:
        with tempfile.TemporaryDirectory(prefix='ytpd-parent-death-') as temporary:
            root=Path(temporary)
            writer=root/'writer.py'
            writer.write_text('import time\nfrom pathlib import Path\np=Path("ticks")\nwhile True:\n p.write_text(str(time.monotonic()))\n time.sleep(.02)\n')
            owner=root/'owner.py'
            owner.write_text('import subprocess,sys,time\nsubprocess.Popen(sys.argv[1:])\nprint("ready",flush=True)\ntime.sleep(30)\n')
            process=subprocess.Popen([sys.executable,str(owner),sys.executable,'-I',str(GUARD),'1048576',sys.executable,str(writer)],
                cwd=root,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,start_new_session=True)
            try:
                self.assertEqual(process.stdout.readline().strip(),'ready')
                deadline=time.monotonic()+4
                while not (root/'ticks').exists() and time.monotonic()<deadline: time.sleep(.02)
                self.assertTrue((root/'ticks').exists())
                os.kill(process.pid,signal.SIGKILL);process.wait(timeout=3)
                time.sleep(.15);before=(root/'ticks').read_text()
                time.sleep(.15);self.assertEqual((root/'ticks').read_text(),before)
            finally:
                if process.poll() is None: os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=3)
                process.stdout.close()

    def test_success_does_not_leave_a_descendant_holding_the_pipe(self) -> None:
        result=subprocess.run([sys.executable,'-I',str(GUARD),'1048576',sys.executable,'-c',
            'import subprocess,sys;subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"]);print("done")'],
            capture_output=True,text=True,timeout=4,check=True)
        self.assertEqual(result.stdout.strip(),'done')
