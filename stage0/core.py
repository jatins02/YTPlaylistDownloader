"""Pure contracts and bounded media operations for the feasibility harness."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import unicodedata
from urllib.parse import parse_qs, urlsplit
import zipfile


class CheckError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def canonical_playlist(value: str) -> str:
    try:
        url = urlsplit(value.strip())
        port = url.port
    except ValueError:
        raise CheckError("INVALID_PLAYLIST", "Malformed playlist URL.") from None
    allowed = {"youtube.com", "www.youtube.com", "music.youtube.com", "m.youtube.com"}
    lists = parse_qs(url.query).get("list", [])
    if (url.scheme != "https" or url.hostname not in allowed or port not in (None, 443)
            or url.username or url.password or url.path not in ("/playlist", "/watch")
            or len(lists) != 1 or not re.fullmatch(r"[A-Za-z0-9_-]{10,100}", lists[0])
            or lists[0].startswith("RD")):
        raise CheckError("INVALID_PLAYLIST", "Use an HTTPS YouTube playlist URL; mixes are unsupported.")
    return "https://www.youtube.com/playlist?list=" + lists[0]


TRACK_PROPERTIES = {
    "track_id": {"type": "string", "minLength": 1, "maxLength": 100},
    "title": {"type": "string", "minLength": 1, "maxLength": 500},
    "artists": {"type": "array", "maxItems": 20, "items": {"type": "string", "minLength": 1, "maxLength": 200}},
    "featured_artists": {"type": "array", "maxItems": 20, "items": {"type": "string", "minLength": 1, "maxLength": 200}},
    "album": {"type": ["string", "null"], "maxLength": 500},
    "version": {"type": ["string", "null"], "maxLength": 200},
    "needs_review": {"type": "boolean"},
    "reason": {"type": ["string", "null"], "maxLength": 500},
}
METADATA_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["tracks"],
    "properties": {"tracks": {"type": "array", "maxItems": 10, "items": {
        "type": "object", "additionalProperties": False,
        "properties": TRACK_PROPERTIES, "required": list(TRACK_PROPERTIES),
    }}},
}


def validate_metadata(payload: dict, expected_ids: list[str]) -> dict[str, dict]:
    from jsonschema import Draft202012Validator
    if list(Draft202012Validator(METADATA_SCHEMA).iter_errors(payload)):
        raise CheckError("AI_SCHEMA_INVALID", "Metadata response does not match the schema.")
    records = payload["tracks"]
    ids = [item["track_id"] for item in records]
    if len(ids) != len(set(ids)) or set(ids) != set(expected_ids) or len(expected_ids) != len(set(expected_ids)):
        raise CheckError("AI_IDS_INVALID", "Metadata response has missing, extra or duplicate track IDs.")
    for record in records:
        if not record["title"].strip() or any(not name.strip() for name in record["artists"] + record["featured_artists"]):
            raise CheckError("AI_FIELDS_INVALID", "Metadata contains blank semantic fields.")
        if not record["artists"] and not record["needs_review"]:
            raise CheckError("AI_UNCERTAINTY_INVALID", "Unknown artists must be marked for review.")
    return {item["track_id"]: item for item in records}


def fallback_metadata(track: dict) -> dict:
    return {
        "track_id": track["track_id"], "title": track["title"],
        "artists": [], "featured_artists": [], "album": None, "version": None,
        "needs_review": True, "reason": "Original source title retained; artist needs review.",
    }


def song_title(metadata: dict) -> str:
    title = metadata["title"].strip()
    version = (metadata.get("version") or "").strip()
    if version and version.casefold() not in title.casefold():
        title += " (" + version + ")"
    return title


def display_name(metadata: dict) -> str:
    artists = ", ".join(metadata["artists"]) or "Unknown Artist"
    value = song_title(metadata) + " - " + artists
    if metadata["featured_artists"]:
        value += " - " + ", ".join(metadata["featured_artists"])
    return value


def truncate_utf8(value: str, budget: int) -> str:
    return value.encode("utf-8")[:budget].decode("utf-8", errors="ignore").rstrip(" .")


def allocate_filename(metadata: dict, used: set[str], budget: int = 180) -> str:
    base = unicodedata.normalize("NFC", display_name(metadata))
    base = "".join("-" if c in '/\\:<>"|?*' else c for c in base if not unicodedata.category(c).startswith("C"))
    base = base.strip(" .") or "Untitled"
    if re.fullmatch(r"(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", base):
        base = "_" + base
    suffix = ""
    number = 0
    while True:
        name = truncate_utf8(base, budget - len(suffix.encode()) - 4) + suffix + ".mp3"
        key = unicodedata.normalize("NFC", name).casefold()
        if key not in used:
            used.add(key)
            return name
        number += 1
        identity = hashlib.sha256(metadata["track_id"].encode()).hexdigest()[:8]
        suffix = " [" + identity + ("-" + str(number) if number > 1 else "") + "]"


def checksum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def disk_bytes(root: Path) -> int:
    total = 0
    for path in root.rglob("*"):
        try:
            if path.is_file():
                total += path.stat().st_size
        except FileNotFoundError:
            pass
    return total


def command(args: list[str], *, timeout: int = 120, scratch: Path | None = None,
            max_bytes: int = 512 * 1024 * 1024) -> bytes:
    """Drain output into temporary files, kill the process group on timeout/quota."""
    import tempfile
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(args, stdout=output, stderr=errors, start_new_session=os.name != "nt")
        start = time.monotonic()
        failure = None
        try:
            while process.poll() is None:
                if time.monotonic() - start > timeout:
                    failure = CheckError("TOOL_TIMEOUT", "Media command exceeded its deadline.")
                    break
                if scratch and disk_bytes(scratch) > max_bytes:
                    failure = CheckError("DISK_LIMIT", "Feasibility scratch-data limit exceeded.")
                    break
                if output.tell() > 2 * 1024 * 1024 or errors.tell() > 2 * 1024 * 1024:
                    failure = CheckError("TOOL_OUTPUT_LIMIT", "Tool produced excessive diagnostic output.")
                    break
                time.sleep(0.05)
        finally:
            if process.poll() is None:
                if os.name == "nt":
                    process.kill()
                else:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                process.wait()
        if failure:
            raise failure
        if scratch and disk_bytes(scratch) > max_bytes:
            raise CheckError("DISK_LIMIT", "Feasibility scratch-data limit exceeded.")
        if process.returncode:
            errors.seek(0)
            diagnostic = errors.read(16384).decode(errors="replace").lower()
            # Store categories, never raw output containing source/signed URLs.
            if "429" in diagnostic or "confirm you" in diagnostic or "bot" in diagnostic:
                code = "SOURCE_BLOCKED"
            elif "resolve" in diagnostic or "connection" in diagnostic:
                code = "NETWORK_UNAVAILABLE"
            else:
                code = "TOOL_FAILED"
            raise CheckError(code, "Tool failed; raw provider output was withheld to avoid exposing credentials or URLs.")
        output.seek(0)
        return output.read(2 * 1024 * 1024)


def probe_and_decode(path: Path, ffmpeg: str, ffprobe: str) -> float:
    data = json.loads(command([ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)]))
    duration = float(data["format"]["duration"])
    if duration <= 0 or duration > 601:
        raise CheckError("AUDIO_DURATION_INVALID", "Stage 0 accepts positive audio durations up to 10 minutes.")
    command([ffmpeg, "-nostdin", "-v", "error", "-i", str(path), "-f", "null", "-"], timeout=120)
    return duration


def tag_and_verify(path: Path, metadata: dict, cover: bytes | None, source_id: str) -> dict:
    from mutagen.id3 import APIC, ID3, TALB, TIT2, TPE1, TXXX, WOAS
    tags = ID3()
    artists = metadata["artists"] or ["Unknown Artist"]
    tags.add(TIT2(encoding=3, text=song_title(metadata)))
    tags.add(TPE1(encoding=3, text=", ".join(artists)))
    if metadata["album"]:
        tags.add(TALB(encoding=3, text=metadata["album"]))
    if metadata["featured_artists"]:
        tags.add(TXXX(encoding=3, desc="FEATURED_ARTISTS", text=", ".join(metadata["featured_artists"])))
    tags.add(TXXX(encoding=3, desc="SOURCE_VIDEO_ID", text=source_id))
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", source_id):
        tags.add(WOAS(url="https://www.youtube.com/watch?v=" + source_id))
    if cover:
        tags.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Front cover", data=cover))
    tags.save(path, v2_version=3)
    actual = ID3(path)
    if str(actual.get("TIT2")) != song_title(metadata) or str(actual.get("TPE1")) != ", ".join(artists):
        raise CheckError("TAG_VERIFY_FAILED", "Title or artist did not survive ID3 readback.")
    for description, expected in [("FEATURED_ARTISTS", ", ".join(metadata["featured_artists"])), ("SOURCE_VIDEO_ID", source_id)]:
        frame = actual.get("TXXX:" + description)
        if (str(frame) if frame else "") != expected:
            raise CheckError("TAG_VERIFY_FAILED", "Custom metadata did not survive ID3 readback.")
    if metadata["album"] and str(actual.get("TALB")) != metadata["album"]:
        raise CheckError("TAG_VERIFY_FAILED", "Album did not survive ID3 readback.")
    if cover and (not actual.getall("APIC") or actual.getall("APIC")[0].data != cover):
        raise CheckError("COVER_VERIFY_FAILED", "Embedded cover did not survive ID3 readback.")
    return {"id3_version": list(actual.version), "cover_embedded": bool(cover), "tags_verified": True}


def build_archive(root: Path, records: list[dict]) -> Path:
    """Write privately, verify manifest and every entry, then publish by rename."""
    partial = root / "playlist.zip.partial"
    final = root / "playlist.zip"
    if final.exists():
        raise CheckError("EXPORT_EXISTS", "Refusing to overwrite a published export.")
    manifest = json.dumps({"synthetic_or_live": records[0]["source_mode"], "tracks": records}, ensure_ascii=False, indent=2)
    with zipfile.ZipFile(partial, "w", zipfile.ZIP_STORED) as archive:
        for record in records:
            name = record["filename"]
            if Path(name).name != name or "/" in name or "\\" in name:
                raise CheckError("UNSAFE_ARCHIVE_NAME", "Archive entry is not a portable filename.")
            archive.write(root / "export" / name, arcname=name)
        archive.writestr("playlist.json", manifest)
    with zipfile.ZipFile(partial) as archive:
        names = archive.namelist()
        if len(names) != len(set(name.casefold() for name in names)) or archive.testzip():
            raise CheckError("ZIP_VERIFY_FAILED", "Archive is corrupt or has colliding entries.")
        for record in records:
            digest = hashlib.sha256()
            with archive.open(record["filename"]) as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != record["sha256"]:
                raise CheckError("ZIP_VERIFY_FAILED", "Archive entry checksum differs from the export manifest.")
    partial.replace(final)
    return final
