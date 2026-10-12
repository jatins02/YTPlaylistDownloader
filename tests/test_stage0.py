"""Contract tests plus actual FFmpeg/ID3/ZIP integration using generated audio."""
from copy import deepcopy
import io
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from stage0.core import (CheckError, allocate_filename, build_archive, canonical_playlist,
                        checksum, display_name, validate_metadata)
from stage0.providers import normalize_image, validate_artwork_url
from stage0.__main__ import export_tracks, preflight, synthetic_inputs, tool


def meta(identity="track-a", title="Moonlit Train"):
    return {"track_id": identity, "title": title, "artists": ["Mira Vale"],
            "featured_artists": [], "album": None, "version": None,
            "needs_review": False, "reason": None}


class PlaylistTests(unittest.TestCase):
    def test_supported_urls_are_reconstructed(self):
        for host in ["www.youtube.com", "music.youtube.com", "m.youtube.com"]:
            self.assertEqual(canonical_playlist(f"https://{host}/watch?v=ignored&list=PL1234567890&other=ignored"),
                             "https://www.youtube.com/playlist?list=PL1234567890")

    def test_invalid_and_private_targets_rejected(self):
        for value in ["http://youtube.com/playlist?list=PL1234567890", "https://youtube.com.evil.example/playlist?list=PL1234567890",
                      "https://user:password@youtube.com/playlist?list=PL1234567890", "https://127.0.0.1/playlist?list=PL1234567890",
                      "https://youtube.com:8080/playlist?list=PL1234567890", "https://youtube.com/playlist?list=RD1234567890",
                      "https://youtube.com/playlist?list=PL1234567890&list=PLabcdefghij", "https://youtube.com/playlist?list=short"]:
            with self.subTest(value=value), self.assertRaises(CheckError):
                canonical_playlist(value)


class MetadataTests(unittest.TestCase):
    def test_reordered_records_are_mapped_by_id(self):
        result = validate_metadata({"tracks": [meta("b", "Second"), meta("a", "First")]}, ["a", "b"])
        self.assertEqual(result["a"]["title"], "First")

    def test_missing_extra_duplicate_or_blank_records_fail(self):
        cases = [[meta("a")], [meta("a"), meta("b"), meta("c")], [meta("a"), meta("a")],
                 [meta("a", "   "), meta("b")]]
        for records in cases:
            with self.subTest(records=records), self.assertRaises(CheckError):
                validate_metadata({"tracks": records}, ["a", "b"])

    def test_unknown_artist_requires_review(self):
        record = meta()
        record["artists"] = []
        with self.assertRaises(CheckError):
            validate_metadata({"tracks": [record]}, ["track-a"])
        record["needs_review"] = True
        self.assertIn("track-a", validate_metadata({"tracks": [record]}, ["track-a"]))

    def test_song_first_and_no_empty_feature_separator(self):
        self.assertEqual(display_name(meta()), "Moonlit Train - Mira Vale")
        record = meta()
        record["featured_artists"] = ["Jun Park"]
        self.assertEqual(display_name(record), "Moonlit Train - Mira Vale - Jun Park")

    def test_version_is_preserved_in_the_exported_song_name(self):
        record = meta()
        record["version"] = "Slowed + Reverbed"
        self.assertEqual(display_name(record), "Moonlit Train (Slowed + Reverbed) - Mira Vale")
        record["title"] = "Moonlit Train (Slowed + Reverbed)"
        self.assertEqual(display_name(record).count("Slowed + Reverbed"), 1)


class FilenameTests(unittest.TestCase):
    def test_duplicate_casefold_and_unicode_names_are_distinct(self):
        used = set()
        names = [allocate_filename(meta("a", "Café"), used), allocate_filename(meta("b", "CAFE\u0301"), used)]
        self.assertEqual(len({name.casefold() for name in names}), 2)
        self.assertIn("[", names[1])

    def test_unicode_byte_budget_and_portable_paths(self):
        used = set()
        for title in ["../bad\\name:with?*chars\x00", "🎵" * 300, "  .  "]:
            name = allocate_filename(meta(title=title), used)
            self.assertLessEqual(len(name.encode()), 180)
            self.assertFalse(any(char in name for char in '/\\:<>"|?*\x00'))
            self.assertEqual(Path(name).name, name)
            self.assertTrue(name.endswith(".mp3"))


class ArtworkTests(unittest.TestCase):
    def test_untrusted_host_or_private_address_is_rejected(self):
        local = lambda *args, **kwargs: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443))]
        with self.assertRaises(CheckError):
            validate_artwork_url("https://coverartarchive.org/image.jpg", resolver=local)
        with self.assertRaises(CheckError):
            validate_artwork_url("https://evil.example/image.jpg", resolver=local)

    def test_public_trusted_address_is_allowed(self):
        public = lambda *args, **kwargs: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("8.8.8.8", 443))]
        validate_artwork_url("https://archive.org/image.jpg", resolver=public)

    def test_image_normalizes_and_invalid_payload_fails(self):
        from PIL import Image
        data = io.BytesIO()
        Image.new("RGBA", (1200, 600)).save(data, "PNG")
        normalized = normalize_image(data.getvalue())
        with Image.open(io.BytesIO(normalized)) as image:
            self.assertEqual(image.format, "JPEG")
            self.assertEqual(image.size, (1000, 500))
        with self.assertRaises(CheckError):
            normalize_image(b"not an image")


class EvidenceTests(unittest.TestCase):
    def test_preflight_never_serializes_secret_values(self):
        with patch.dict(os.environ, {"GROQ_API_KEY": "DO_NOT_SERIALIZE_THIS_SENTINEL"}):
            result = preflight()
        self.assertTrue(result["configuration_present"]["GROQ_API_KEY"])
        self.assertNotIn("DO_NOT_SERIALIZE_THIS_SENTINEL", json.dumps(result))


@unittest.skipUnless(tool("ffmpeg") and tool("ffprobe"), "Actual FFmpeg/ffprobe required for media integration")
class MediaIntegrationTests(unittest.TestCase):
    def test_real_tags_covers_full_audio_and_unique_zip_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["source", "export", "previews"]:
                (root / name).mkdir()
            tracks, files, metadata, cover = synthetic_inputs(root)
            result = export_tracks(root, tracks, files, metadata, {t["track_id"]: cover for t in tracks}, "synthetic")
            self.assertEqual(len(result["tracks"]), 3)
            self.assertEqual(len({t["filename"].casefold() for t in result["tracks"]}), 3)
            self.assertEqual(len({t["sha256"] for t in result["tracks"]}), 3)
            self.assertTrue(all(t["cover_embedded"] and t["tags_verified"] for t in result["tracks"]))
            with zipfile.ZipFile(root / "playlist.zip") as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(len(archive.namelist()), 4)
                self.assertEqual([t["track_id"] for t in json.loads(archive.read("playlist.json"))["tracks"]], [t["track_id"] for t in tracks])

    def test_checksum_mismatch_never_publishes_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "export").mkdir()
            (root / "export" / "one.mp3").write_bytes(b"different bytes")
            with self.assertRaises(CheckError):
                build_archive(root, [{"source_mode": "synthetic", "filename": "one.mp3", "sha256": "0" * 64}])
            self.assertFalse((root / "playlist.zip").exists())


if __name__ == "__main__":
    unittest.main()
