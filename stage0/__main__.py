"""Run with python -m stage0. This is a bounded CLI, not the production app."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.metadata
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import threading
import time
import uuid

from .core import (CheckError, allocate_filename, build_archive, canonical_playlist,
                   checksum, command, disk_bytes, fallback_metadata, probe_and_decode,
                   song_title, tag_and_verify, validate_metadata)

MODULES = {"yt-dlp": "yt_dlp", "yt-dlp-ejs": "yt_dlp_ejs", "groq": "groq", "mutagen": "mutagen", "python-dotenv": "dotenv",
           "Pillow": "PIL", "jsonschema": "jsonschema", "boto3": "boto3", "psutil": "psutil", "requests": "requests"}
TOOLS = {"ffmpeg": "FFMPEG_BIN", "ffprobe": "FFPROBE_BIN", "deno": "DENO_BIN"}


def tool(name: str) -> str:
    configured = os.getenv(TOOLS[name]) or shutil.which(name)
    if configured:
        return configured
    local = Path(__file__).resolve().parents[1] / ".tools-stage0" / "bin" / (name + (".exe" if os.name == "nt" else ""))
    return str(local) if local.is_file() else ""


def preflight() -> dict:
    packages = {}
    for name, module in MODULES.items():
        try:
            packages[name] = importlib.metadata.version(name) if importlib.util.find_spec(module) else None
        except importlib.metadata.PackageNotFoundError:
            packages[name] = None
    tools = {}
    for name in TOOLS:
        executable = tool(name)
        try:
            version = command([executable, "--version" if name == "deno" else "-version"], timeout=10).decode().splitlines()[0] if executable else None
        except (CheckError, OSError):
            version = None
        tools[name] = {"available": bool(version), "version": version}
    return {"python": platform.python_version(), "platform": platform.system(), "machine": platform.machine(),
            "packages": packages, "tools": tools,
            "configuration_present": {key: bool(os.getenv(key)) for key in ["GROQ_API_KEY", "MUSICBRAINZ_CONTACT", "S3_ENDPOINT_URL", "S3_BUCKET", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]}}


def load_project_environment():
    """Do not search parent directories or read the sibling DOT. environment."""
    if importlib.util.find_spec("dotenv"):
        from dotenv import load_dotenv
        load_dotenv(Path(__file__).resolve().parents[1] / ".env", override=False)


class Metrics:
    """Sample the process tree and scratch disk; do not present samples as exact peaks."""
    def __init__(self, root: Path):
        self.root = root
        self.stop = threading.Event()
        self.peak_rss = 0
        self.peak_disk = 0
        self.samples = 0
        self.process_cpu: dict[tuple[int, float], float] = {}
        import psutil
        cpu = psutil.Process().cpu_times()
        self.initial_cpu = cpu.user + cpu.system
        self.started = time.monotonic()
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        import psutil
        current = psutil.Process()
        while not self.stop.is_set():
            memory = 0
            try:
                processes = [current] + current.children(recursive=True)
            except psutil.Error:
                processes = [current]
            for process in processes:
                try:
                    memory += process.memory_info().rss
                    cpu = process.cpu_times()
                    identity = (process.pid, process.create_time())
                    baseline = self.initial_cpu if process.pid == current.pid else 0.0
                    self.process_cpu[identity] = max(self.process_cpu.get(identity, 0), cpu.user + cpu.system - baseline)
                except psutil.Error:
                    pass
            self.peak_rss = max(self.peak_rss, memory)
            self.peak_disk = max(self.peak_disk, disk_bytes(self.root))
            self.samples += 1
            self.stop.wait(0.1)

    def finish(self) -> dict:
        self.stop.set()
        self.thread.join()
        return {"wall_seconds": round(time.monotonic() - self.started, 3),
                "sampled_peak_process_tree_rss_bytes": self.peak_rss,
                "sampled_peak_scratch_bytes": max(self.peak_disk, disk_bytes(self.root)),
                "sampled_process_tree_cpu_seconds": round(sum(self.process_cpu.values()), 3),
                "samples": self.samples, "sampling_interval_seconds": 0.1,
                "limits": "Sampled CPU/RSS may miss short-lived children; payload byte counts exclude protocol overhead."}


def check(report: dict, name: str, fn):
    start = time.monotonic()
    try:
        result = fn()
        report["checks"].append({"name": name, "status": "passed", "seconds": round(time.monotonic() - start, 3), "evidence": result})
        return result
    except Exception as error:
        code = error.code if isinstance(error, CheckError) else type(error).__name__
        message = str(error) if isinstance(error, CheckError) else "Integration failed; raw exception withheld to avoid leaking provider data."
        report["checks"].append({"name": name, "status": "failed", "seconds": round(time.monotonic() - start, 3), "code": code, "message": message})
        return None


def skip(report: dict, name: str, reason: str):
    report["checks"].append({"name": name, "status": "not_run", "reason": reason})


def require_runtime(live: bool, *, with_ai: bool = False, with_artwork: bool = False, with_storage: bool = False):
    names = ["mutagen", "Pillow", "jsonschema", "psutil"]
    if live:
        names += ["yt-dlp", "yt-dlp-ejs"]
    if with_ai:
        names += ["groq"]
    if with_artwork:
        names += ["requests"]
    if with_storage:
        names += ["boto3", "requests"]
    state = preflight()
    missing = [name for name in names if not state["packages"][name]]
    missing += [name for name in (["ffmpeg", "ffprobe", "deno"] if live else ["ffmpeg", "ffprobe"]) if not state["tools"][name]["available"]]
    if missing:
        raise CheckError("RUNTIME_MISSING", "Missing runtime dependencies: " + ", ".join(missing))
    return state


def synthetic_inputs(root: Path) -> tuple[list[dict], dict[str, Path], dict[str, dict], bytes]:
    from PIL import Image
    image = io.BytesIO()
    Image.new("RGB", (128, 128), "lavenderblush").save(image, "JPEG")
    records = []
    files = {}
    metadata = {}
    for index, (frequency, duration) in enumerate([(330, 2.4), (440, 3.2), (550, 4.0)]):
        identity = "synthetic-" + str(index + 1)
        path = root / "source" / (identity + ".mp3")
        command([tool("ffmpeg"), "-nostdin", "-v", "error", "-f", "lavfi", "-i", f"sine=frequency={frequency}:duration={duration}", "-c:a", "libmp3lame", "-b:a", "320k", str(path)], scratch=root)
        records.append({"track_id": identity, "video_id": identity, "title": "Synthetic tone " + str(index + 1), "duration": duration})
        files[identity] = path
        # Deliberately equal formatted names for two different audio files.
        metadata[identity] = {"track_id": identity, "title": "Moonlit Train" if index < 2 else "रात का गीत",
                              "artists": ["Mira Vale"], "featured_artists": ["Jun Park"] if index < 2 else [],
                              "album": "Synthetic Feasibility Fixtures", "version": None, "needs_review": False, "reason": None}
    validate_metadata({"tracks": list(reversed(list(metadata.values())))}, list(files))
    return records, files, metadata, image.getvalue()


def live_inputs(url: str, root: Path, report: dict) -> tuple[list[dict], dict[str, Path]]:
    ytdlp = [sys.executable, "-m", "yt_dlp", "--ignore-config", "--quiet", "--no-warnings", "--socket-timeout", "15", "--retries", "1", "--extractor-retries", "1", "--js-runtimes", "deno:" + tool("deno")]
    playlist = json.loads(command(ytdlp + ["--flat-playlist", "--dump-single-json", "--playlist-end", "11", url], timeout=120, scratch=root))
    entries = playlist.get("entries") or []
    if not 3 <= len(entries) <= 10 or (playlist.get("playlist_count") or 0) > 10:
        raise CheckError("PLAYLIST_TEST_SIZE", "Stage 0 needs a small playlist with 3–10 entries; it will not silently truncate one.")
    tracks = []
    files = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", entry["id"]):
            report["checks"].append({"name": "source_entry_" + str(index + 1), "status": "failed", "code": "SOURCE_UNAVAILABLE", "message": "Playlist item has no accessible video identity."})
            continue
        video = entry["id"]
        if video in files:
            continue
        path = root / "source" / (video + ".mp3")
        def acquire():
            if entry.get("duration") and entry["duration"] > 600:
                raise CheckError("SOURCE_DURATION_LIMIT", "Stage 0 track exceeds 10 minutes.")
            progress = command(ytdlp + ["--no-playlist", "--max-filesize", "50M", "--match-filter", "!is_live & duration <= 600", "--progress", "--newline", "--progress-template", "download:stage0_bytes=%(progress.downloaded_bytes)s", "-f", "bestaudio/best", "-x", "--audio-format", "mp3", "--audio-quality", "320K", "--ffmpeg-location", str(Path(tool("ffmpeg")).parent), "-o", str(root / "source" / (video + ".%(ext)s")), "https://www.youtube.com/watch?v=" + video], timeout=300, scratch=root, max_bytes=256 * 1024 * 1024)
            if not path.exists():
                raise CheckError("SOURCE_SKIPPED", "Source was filtered, over-limit or unavailable.")
            counts = [int(value) for value in re.findall(rb"stage0_bytes=(\d+)", progress)]
            return {"video_id": video, "duration_seconds": probe_and_decode(path, tool("ffmpeg"), tool("ffprobe")), "converted_mp3_bytes": path.stat().st_size,
                    "source_payload_bytes_reported": max(counts) if counts else None,
                    "byte_measurement_note": "Downloader progress maximum; excludes retry traffic and protocol overhead. Null means not reported."}
        evidence = check(report, "source_" + video, acquire)
        if evidence:
            files[video] = path
            title = entry.get("title")
            title = title.strip()[:500] if isinstance(title, str) and title.strip() else "Unknown title"
            uploader = entry.get("uploader")
            uploader = uploader[:200] if isinstance(uploader, str) else ""
            tracks.append({"track_id": video, "video_id": video, "playlist_index": index + 1,
                           "title": title, "uploader": uploader, "duration": evidence["duration_seconds"]})
    if len(tracks) < 3:
        raise CheckError("SOURCE_MINIMUM_FAILED", "Fewer than three distinct tracks downloaded and decoded.")
    return tracks, files


def export_tracks(root: Path, tracks: list[dict], files: dict[str, Path], metadata: dict[str, dict], covers: dict[str, bytes], mode: str) -> dict:
    used: set[str] = set()
    records = []
    for track in tracks:
        identity = track["track_id"]
        meta = metadata[identity]
        filename = allocate_filename(meta, used)
        target = root / "export" / filename
        shutil.copyfile(files[identity], target)
        tags = tag_and_verify(target, meta, covers.get(identity), track["video_id"])
        duration = probe_and_decode(target, tool("ffmpeg"), tool("ffprobe"))
        if abs(duration - track["duration"]) > 0.2:
            raise CheckError("AUDIO_DURATION_CHANGED", "Full-length export duration differs from its acquired audio.")
        snippet = root / "previews" / (identity + ".mp3")
        start = 30 if duration > 30 else 0
        command([tool("ffmpeg"), "-nostdin", "-v", "error", "-ss", str(start), "-i", str(target), "-t", "30", "-c:a", "libmp3lame", "-b:a", "128k", str(snippet)], scratch=root)
        snippet_duration = probe_and_decode(snippet, tool("ffmpeg"), tool("ffprobe"))
        if snippet_duration > 30.2:
            raise CheckError("PREVIEW_DURATION_INVALID", "Preview exceeds its 30-second bound.")
        records.append({"track_id": identity, "source_mode": mode, "filename": filename, "metadata": meta,
                        "duration_seconds": duration, "preview_seconds": snippet_duration,
                        "bytes": target.stat().st_size, "sha256": checksum(target), **tags})
    archive = build_archive(root, records)
    return {"tracks": records, "zip": {"filename": archive.name, "bytes": archive.stat().st_size, "sha256": checksum(archive), "verified": True}}


def run(args) -> Path:
    mode = args.action
    identity = uuid.uuid4().hex
    root = Path(args.output).resolve() / identity
    root.mkdir(parents=True, exist_ok=False)
    if os.name != "nt":
        root.chmod(0o700)
    for subdirectory in ["source", "export", "previews"]:
        (root / subdirectory).mkdir()
    report = {"run_id": identity, "created_at": datetime.now(timezone.utc).isoformat(), "mode": mode,
              "host": {"label": args.host_label, "region": args.host_region, "evidence": "operator-supplied; not independently verified"},
              "stage0_complete": False, "checks": [], "device_tests": {"phone": "not_run", "laptop": "not_run"}}
    runtime = check(report, "runtime", lambda: require_runtime(mode == "live",
        with_ai=getattr(args, "with_ai", False), with_artwork=getattr(args, "with_artwork", False),
        with_storage=args.with_storage))
    metrics = Metrics(root) if runtime else None
    try:
        if runtime:
            if mode == "synthetic":
                generated = check(report, "synthetic_sources", lambda: synthetic_inputs(root))
                # Generated result contains Paths/bytes, so replace its report evidence with safe facts.
                if generated:
                    report["checks"][-1]["evidence"] = {"count": 3, "provider": "local synthetic tones and generated image; no AI or online artwork"}
                    tracks, files, metadata, cover = generated
                    covers = {track["track_id"]: cover for track in tracks}
            else:
                generated = check(report, "playlist_acquisition", lambda: live_inputs(canonical_playlist(args.playlist), root, report))
                if generated:
                    tracks, files = generated
                    report["checks"][-1]["evidence"] = {"distinct_tracks": len(tracks), "mode": "actual YouTube acquisition"}
                    metadata = {track["track_id"]: fallback_metadata(track) for track in tracks}
                    covers = {}
                    if args.with_ai:
                        from .providers import format_with_groq
                        result = check(report, "groq_metadata", lambda: format_with_groq(tracks))
                        if result:
                            metadata, usage = result
                            report["checks"][-1]["evidence"] = usage
                    else:
                        skip(report, "groq_metadata", "Not requested; source-title fallback is not a live AI pass.")
                    if args.with_artwork:
                        from .providers import ArtworkClient
                        client_result = check(report, "artwork_client", ArtworkClient)
                        if client_result:
                            report["checks"][-1]["evidence"] = {"rate_limit_requests_per_second": 1}
                            with client_result:
                                for track in tracks:
                                    meta = metadata[track["track_id"]]
                                    if meta["needs_review"]:
                                        skip(report, "artwork_" + track["track_id"], "Uncertain identity; automatic cover assignment withheld.")
                                        continue
                                    result = check(report, "artwork_" + track["track_id"], lambda meta=meta: client_result.lookup(song_title(meta), meta["artists"], meta["album"], featured_artists=meta["featured_artists"]))
                                    if result:
                                        cover, provenance = result
                                        covers[track["track_id"]] = cover
                                        report["checks"][-1]["evidence"] = {**provenance, "normalized_image_bytes": len(cover)}
                                report["artwork_payload_received_bytes"] = client_result.received_bytes
                                report["artwork_requests"] = client_result.requests
                    else:
                        skip(report, "artwork", "Not requested; no online cover-matching pass.")
            if generated:
                report["source_records"] = tracks
                exported = check(report, "tagged_export", lambda: export_tracks(root, tracks, files, metadata, covers, mode))
                if exported and args.with_storage:
                    from .providers import upload_and_verify
                    artifacts = [root / "playlist.zip"] + [root / "export" / track["filename"] for track in exported["tracks"]]
                    check(report, "storage_delivery", lambda: upload_and_verify(artifacts, identity, root))
                else:
                    skip(report, "storage_delivery", "Not requested or export did not succeed; local ZIP is not hosted delivery evidence.")
    finally:
        if metrics:
            report["metrics"] = metrics.finish()
    report["checks_passed"] = all(item["status"] != "failed" for item in report["checks"])
    report["completion_note"] = "Stage 0 also requires live AI, a known online cover match, independent native Android/iPhone/laptop execution and save evidence, and a viable zero-budget distribution route. Hosted storage is optional."
    path = root / "report.json"
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"report": str(path), "mode": mode, "checks_passed": report["checks_passed"], "stage0_complete": False}))
    return path


def main() -> int:
    load_project_environment()
    parser = argparse.ArgumentParser(description="Bounded Stage 0 checks. No production service or paid resources are created.")
    commands = parser.add_subparsers(dest="action", required=True)
    doctor = commands.add_parser("preflight", help="Report runtime/configuration presence, never secret values")
    doctor.add_argument("--output", default="stage0-runs/preflight.json")
    for action in ["synthetic", "live"]:
        child = commands.add_parser(action)
        child.add_argument("--output", default="stage0-runs")
        child.add_argument("--runs", type=int, choices=range(1, 4), default=1)
        child.add_argument("--host-label", default="local")
        child.add_argument("--host-region", default="unspecified")
        child.add_argument("--with-storage", action="store_true")
        if action == "live":
            child.add_argument("--playlist", required=True)
            child.add_argument("--with-ai", action="store_true")
            child.add_argument("--with-artwork", action="store_true")
    cover = commands.add_parser("cover-check", help="Validate a known title/artist/album against online front artwork")
    cover.add_argument("--title", required=True)
    cover.add_argument("--artist", required=True)
    cover.add_argument("--album", required=True)
    cover.add_argument("--output", default="stage0-runs/known-cover")
    cleanup = commands.add_parser("cleanup-storage", help="Delete only keys recorded for one completed feasibility run")
    cleanup.add_argument("--report", type=Path, required=True)
    ai = commands.add_parser("metadata-check", help="Check live Groq naming against a prior run without downloading again")
    ai.add_argument("--report", type=Path, required=True)
    ai.add_argument("--output", default="stage0-runs")
    args = parser.parse_args()
    try:
        if args.action == "preflight":
            state = preflight()
            path = Path(args.output)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(state, indent=2))
            return 0
        if args.action == "cleanup-storage":
            from .providers import cleanup_uploaded
            print(json.dumps({"deleted_objects": cleanup_uploaded(args.report)}))
            return 0
        if args.action == "metadata-check":
            from .providers import format_with_groq
            previous = json.loads(args.report.read_text())
            sources = previous.get("source_records")
            if not sources:
                exported = next((item["evidence"] for item in previous.get("checks", []) if item["name"] == "tagged_export" and item["status"] == "passed"), None)
                if not exported:
                    raise CheckError("SOURCE_REPORT_INVALID", "The source report has no successful export records.")
                sources = [{"track_id": item["track_id"], "title": item["metadata"]["title"], "duration": item["duration_seconds"]} for item in exported["tracks"]]
            if not 1 <= len(sources) <= 10 or any(not isinstance(item.get("track_id"), str) or not isinstance(item.get("title"), str) or len(item["title"]) > 500 for item in sources):
                raise CheckError("SOURCE_REPORT_INVALID", "The source report exceeds the bounded naming input contract.")
            report = {"mode": "live_ai_only", "stage0_complete": False, "checks": []}
            def naming():
                records, usage = format_with_groq(sources)
                return {"usage": usage, "metadata": records}
            check(report, "groq_metadata", naming)
            root = Path(args.output)
            root.mkdir(parents=True, exist_ok=True)
            path = root / ("ai-" + uuid.uuid4().hex + ".json")
            path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps({"report": str(path), "status": report["checks"][0]["status"]}))
            return 0 if report["checks"][0]["status"] == "passed" else 1
        if args.action == "cover-check":
            from .providers import ArtworkClient
            root = Path(args.output)
            root.mkdir(parents=True, exist_ok=False)
            report = {"mode": "live_known_cover", "stage0_complete": False, "checks": []}
            def known_cover():
                with ArtworkClient() as client:
                    image, provenance = client.lookup(args.title, [args.artist], args.album)
                    (root / "cover.jpg").write_bytes(image)
                    return {**provenance, "received_payload_bytes": client.received_bytes, "requests": client.requests, "cover_sha256": checksum(root / "cover.jpg")}
            check(report, "known_cover_match", known_cover)
            (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({"report": str(root / "report.json"), "status": report["checks"][0]["status"]}))
            return 0 if report["checks"][0]["status"] == "passed" else 1
        failures = 0
        for _ in range(args.runs):
            report = json.loads(run(args).read_text())
            failures += not report["checks_passed"]
        return 1 if failures else 0
    except Exception as error:
        print(json.dumps({"code": error.code if isinstance(error, CheckError) else type(error).__name__,
                          "message": str(error) if isinstance(error, CheckError) else "Check could not run; consult setup instructions. Raw exception withheld."}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
