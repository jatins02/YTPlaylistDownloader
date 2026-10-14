"""Pure contracts and bounded media operations for the feasibility harness."""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
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
    lists = parse_qs(url.query, keep_blank_values=True).get("list", [])
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
        fields = [record["title"], *record["artists"], *record["featured_artists"],
                  *(record[key] for key in ("album", "version", "reason") if record[key] is not None)]
        if any(re.search(r"[\x00-\x1f\x7f]", value) or not value.strip() for value in fields):
            raise CheckError("AI_FIELDS_INVALID", "Metadata contains blank or invalid text fields.")
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
    if type(budget) is not int or not 32 <= budget <= 255:
        raise CheckError("FILENAME_BUDGET_INVALID", "Filename byte budget must be between 32 and 255.")
    base = unicodedata.normalize("NFC", display_name(metadata))
    base = "".join("-" if c in '/\\:<>"|?*' else c for c in base if not unicodedata.category(c).startswith("C"))
    base = base.strip(" .") or "Untitled"
    if re.fullmatch(r"(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", base):
        base = "_" + base
    suffix = ""
    number = 0
    while True:
        stem = truncate_utf8(base, budget - len(suffix.encode()) - 4) or "Untitled"
        name = stem + suffix + ".mp3"
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
            max_bytes: int = 512 * 1024 * 1024, require_clean_stderr: bool = False) -> bytes:
    """Drain output into temporary files, kill the process group on timeout/quota."""
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        environment = {key: os.environ[key] for key in (
            'PATH', 'HOME', 'LANG', 'LC_ALL', 'SSL_CERT_FILE', 'SSL_CERT_DIR',
            'SYSTEMROOT', 'WINDIR', 'TEMP', 'TMP', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA',
        ) if key in os.environ}
        if scratch is not None:
            environment['TMPDIR'] = str(scratch.resolve())
            environment['DENO_DIR'] = str(scratch.resolve() / '.deno-cache')
        process = subprocess.Popen(args, stdout=output, stderr=errors,
                                   start_new_session=os.name != "nt", env=environment)
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
            if os.name == "nt":
                if process.poll() is None:
                    # yt-dlp can have a codec child. Killing only its parent
                    # leaves that child writing after cancellation/quota failure.
                    try:
                        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       timeout=10, check=False)
                    finally:
                        if process.poll() is None:
                            process.kill()
            else:
                # A successful parent can still leave descendants writing to
                # scratch or the diagnostic files. Retire the group on every exit.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                process.wait()
        if failure:
            raise failure
        # A fast command can finish between polls; apply the same bounds to its
        # final output rather than silently returning a truncated JSON payload.
        if os.fstat(output.fileno()).st_size > 2 * 1024 * 1024 or os.fstat(errors.fileno()).st_size > 2 * 1024 * 1024:
            raise CheckError("TOOL_OUTPUT_LIMIT", "Tool produced excessive diagnostic output.")
        if scratch and disk_bytes(scratch) > max_bytes:
            raise CheckError("DISK_LIMIT", "Feasibility scratch-data limit exceeded.")
        if process.returncode or (require_clean_stderr and os.fstat(errors.fileno()).st_size):
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
    data = json.loads(command([ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)], require_clean_stderr=True))
    duration = float(data["format"]["duration"])
    if not math.isfinite(duration) or duration <= 0 or duration > 601:
        raise CheckError("AUDIO_DURATION_INVALID", "Stage 0 accepts positive audio durations up to 10 minutes.")
    # FFmpeg 6.1 can report decoder-thread errors and still exit zero even with
    # -xerror. At log level error, any diagnostic means strict decoding failed.
    command([ffmpeg, "-nostdin", "-v", "error", "-xerror", "-i", str(path), "-f", "null", "-"],
            timeout=120, require_clean_stderr=True)
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


def build_archive(root: Path, records: list[dict], *, max_bytes: int = 512 * 1024 * 1024) -> Path:
    """Verify in a unique private temporary file, then publish without overwrite."""
    final = root / "playlist.zip"
    if final.exists() or final.is_symlink():
        raise CheckError("EXPORT_EXISTS", "Refusing to overwrite a published export.")
    if not records:
        raise CheckError("EXPORT_EMPTY", "An export must contain at least one track.")
    names = [record["filename"] for record in records]
    if any(not name or Path(name).name != name or "/" in name or "\\" in name for name in names):
        raise CheckError("UNSAFE_ARCHIVE_NAME", "Archive entry is not a portable filename.")
    keys = [unicodedata.normalize("NFC", name).casefold() for name in [*names, "playlist.json"]]
    if len(keys) != len(set(keys)):
        raise CheckError("ZIP_VERIFY_FAILED", "Archive contains colliding entry names.")
    paths = [root / "export" / name for name in names]
    if any(path.is_symlink() or not path.is_file() for path in paths):
        raise CheckError("UNSAFE_ARCHIVE_NAME", "Export inputs must be regular private files.")
    manifest = json.dumps({"synthetic_or_live": records[0]["source_mode"], "tracks": records}, ensure_ascii=False, indent=2, allow_nan=False)
    # ZIP_STORED duplicates the input bytes. Include a conservative allowance for
    # entry headers so conversion passing its quota cannot yield an oversized ZIP.
    projected = disk_bytes(root) + sum(path.stat().st_size for path in paths) + len(manifest.encode("utf-8"))
    projected += 4096 + sum(2 * len(name.encode("utf-8")) + 128 for name in [*names, "playlist.json"])
    if projected > max_bytes:
        raise CheckError("DISK_LIMIT", "Feasibility scratch-data limit exceeded by the archive.")
    descriptor, name = tempfile.mkstemp(prefix="playlist-", suffix=".zip.partial", dir=root)
    os.close(descriptor)
    partial = Path(name)
    try:
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_STORED) as archive:
            for record, path in zip(records, paths, strict=True):
                archive.write(path, arcname=record["filename"])
                if disk_bytes(root) > max_bytes:
                    raise CheckError("DISK_LIMIT", "Feasibility scratch-data limit exceeded.")
            archive.writestr("playlist.json", manifest)
        if disk_bytes(root) > max_bytes:
            raise CheckError("DISK_LIMIT", "Feasibility scratch-data limit exceeded.")
        with zipfile.ZipFile(partial) as archive:
            if archive.namelist() != [*names, "playlist.json"] or archive.testzip():
                raise CheckError("ZIP_VERIFY_FAILED", "Archive entries or checksums are invalid.")
            if archive.read("playlist.json").decode("utf-8") != manifest:
                raise CheckError("ZIP_VERIFY_FAILED", "Archive manifest differs from the frozen records.")
            for record in records:
                digest = hashlib.sha256()
                with archive.open(record["filename"]) as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(chunk)
                if digest.hexdigest() != record["sha256"]:
                    raise CheckError("ZIP_VERIFY_FAILED", "Archive entry checksum differs from the export manifest.")
        try:
            # Same-directory hard linking is atomic and never replaces an existing
            # destination. rename/replace would overwrite a concurrent winner.
            os.link(partial, final)
        except FileExistsError:
            raise CheckError("EXPORT_EXISTS", "Refusing to overwrite a published export.") from None
        except OSError:
            raise CheckError("EXPORT_PUBLISH_FAILED", "Verified export could not be published. Check storage permissions and use a filesystem supporting private hard links.") from None
        return final
    finally:
        partial.unlink(missing_ok=True)
