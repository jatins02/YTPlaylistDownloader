# Components in private evaluation packages

These packages are development evaluation artifacts, not a public product
release. This document does not grant a license to the application's source.
The project owner has not selected a public distribution license. No developer
credentials, application data, dotenv files or shared API key may be included.

The Flutter build embeds its generated `data/flutter_assets/NOTICES.Z` notices
for the resolved Dart packages. Separate upstream Flutter/Dart SDK and target/
common engine license files are copied from the pinned SDK into `notices/`.
Preserve that complete bundle and
the committed `pubspec.lock`. Native platform libraries (GTK, GLib, libsecret,
SQLite and their dependencies) are system prerequisites, not silently copied
from a development sysroot. Windows also needs the applicable Microsoft Visual
C++ runtime; its installation/redistribution is not proved by a portable ZIP.

Optional Linux media packages include a separate `runtime/COMPONENTS.json`,
exact versions/hashes and verbatim upstream license files under
`runtime/notices/`. The runtime preparer copies only explicit standalone Python,
FFmpeg/ffprobe and Deno inputs; it installs the exact runtime-only Python lock.
It never copies a developer virtual environment or scans a home directory.

| Component | Upstream license / notices to preserve |
| --- | --- |
| CPython and bundled standalone libraries | PSF-2.0 and all additional notices shipped by the selected standalone distribution |
| yt-dlp | Unlicense; preserve installed package license files |
| yt-dlp-ejs | Preserve the installed package's license and solver notices |
| Deno | Version-specific upstream MIT license; complete third-party source/notice collection remains a distribution gate |
| FFmpeg / ffprobe | Actual `-L` output and build configuration; current binary enables GPL and version 3, so do not call it an LGPL-only build |
| Mutagen | GPL-2.0-or-later; preserve installed license text |
| Pillow | HPND and bundled native-library license texts shipped in its wheel |
| Requests, urllib3, certifi, Brotli, charset-normalizer, idna, PyCryptodome, websockets | Preserve each wheel's dist-info license files, including bundled native code notices |

**Public redistribution remains unresolved.** For the actual FFmpeg build,
collect exact corresponding source, patches, build recipe and the sources/
notices required by all statically linked components. A link to the latest
upstream source, a version string or `-L` output alone does not establish that
record. Review the application/component combination before publishing binaries.
The packager intentionally supports only a `private-evaluation` channel and does
not upload artifacts or create a GitHub Release.

Primary references, checked 2026-10-17:
[FFmpeg license/build considerations](https://www.ffmpeg.org/legal.html),
[FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds),
[Python standalone distributions and license metadata](https://docs.astral.sh/python-build-standalone/distributions/),
[Deno source/license](https://github.com/denoland/deno),
[yt-dlp](https://github.com/yt-dlp/yt-dlp).
