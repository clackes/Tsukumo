<!--
SPDX-FileCopyrightText: 2026 Tsukumo contributors
SPDX-License-Identifier: GPL-3.0-only
-->

# ffmpeg for Convert (tier 1)

Tsukumo ships an ffmpeg executable inside the `Converter.xpc` helper, used only
for the formats that the system APIs do not write: WebP, MP3, FLAC, Opus, WebM, MKV
and animated GIFs from video (DESIGN.md §2.5).

- **License:** LGPL build. `--enable-gpl` and `--enable-nonfree` are never used;
  the external libraries are LGPL (LAME) or BSD (libwebp, Opus, libvpx, SVT-AV1, dav1d).
  The script stops if the build does not turn out to be LGPL or if it depends on
  dynamic libraries outside the system.
- **Reproducible:** `Tools/ffmpeg/build.sh` downloads the sources with pinned SHA-256
  hashes (the same as Homebrew), builds everything statically for arm64 and puts the
  result in `~/Library/Caches/tsukumo/ffmpeg/`. The binary is not committed.
- **In the app:** the build phase of `Converter.xpc` (`Helpers/Converter/embed-ffmpeg.sh`)
  copies the executable, the configuration (`BUILDCONF.txt`), the list of sources
  (`SOURCES.txt`) and the licenses (`ffmpeg-licenses/`) into the helper's resources. Without
  ffmpeg in the cache the build goes on and tier 1 ends up unavailable.
- **Source offer (LGPL):** the exact sources are those listed in
  `SOURCES.txt`, with URL and hash; the script rebuilds them identically.
- **Security:** the helper accepts only an `FFmpegJob` with a closed preset
  (`ConverterKit`): absolute paths, new output in the same folder as
  the input, never `-y`. No arbitrary argument reaches ffmpeg.

Prerequisites: `brew install nasm cmake meson ninja` (pkg-config included).
