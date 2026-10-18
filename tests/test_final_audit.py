"""Real-codec regressions for standalone, local audio validation."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from stage0.core import CheckError, probe_and_decode


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'actual codecs required')
class LocalAudioValidation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='ytpd-audio-boundary-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.ffmpeg, self.ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')

    def generate(self, *arguments):
        subprocess.run([self.ffmpeg, '-nostdin', '-v', 'error', *arguments],
                       check=True, capture_output=True, timeout=15)

    def test_local_hls_cannot_substitute_bytes_from_another_file(self):
        audio = self.root / 'peer.mp3'
        self.generate('-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
                      '-c:a', 'libmp3lame', str(audio))
        playlist = self.root / 'source.m3u8'
        playlist.write_text('#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n'
                            '#EXTINF:2,\n' + audio.as_uri() + '\n#EXT-X-ENDLIST\n')
        with self.assertRaises(CheckError):
            probe_and_decode(playlist, self.ffmpeg, self.ffprobe)

    def test_video_without_audio_is_not_verified_as_a_song(self):
        video = self.root / 'silent.mp4'
        self.generate('-f', 'lavfi', '-i', 'color=c=black:s=16x16:d=1', '-an',
                      '-c:v', 'mpeg4', str(video))
        with self.assertRaises(CheckError):
            probe_and_decode(video, self.ffmpeg, self.ffprobe)


if __name__ == '__main__':
    unittest.main()
