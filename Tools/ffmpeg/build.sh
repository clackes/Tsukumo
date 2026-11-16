#!/bin/sh
# SPDX-FileCopyrightText: 2026 Tsukumo contributors
# SPDX-License-Identifier: GPL-3.0-only
#
# Reproducible ffmpeg build for Convert tier 1 (DESIGN.md §2.5, §8.3):
# static arm64 executable, LGPL license (never --enable-gpl or --enable-nonfree),
# without network or capture devices. External libraries are all BSD or LGPL.
# Sources downloaded with pinned SHA-256 hashes (the same as Homebrew).
#
# Usage: Tools/ffmpeg/build.sh   →   $HOME/Library/Caches/tsukumo/ffmpeg/ffmpeg
# Requires: nasm cmake meson ninja pkg-config (brew install nasm cmake meson ninja)
set -eu

FFMPEG_VERSION=9.0.2
CACHE="${TSUKUMO_FFMPEG_CACHE:-$HOME/Library/Caches/tsukumo}"
WORK="$CACHE/ffmpeg-build"
SRC="$WORK/src"
PREFIX="$WORK/prefix"
OUT="$CACHE/ffmpeg"
JOBS=$(sysctl -n hw.ncpu)

export MACOSX_DEPLOYMENT_TARGET=26.0
export CFLAGS="-arch arm64 -mmacosx-version-min=26.0 -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=26.0"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

# name|url|sha256
SOURCES="
ffmpeg|https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz|8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
libwebp|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz|e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
lame|https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz|3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
opus|https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz|6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
libvpx|https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz|1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a
svtav1|https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.3.0/SVT-AV1-v4.3.0.tar.bz2|9223ce06e6172ad41357ed23b3b00f036e03794b86b0e20ea9ccb3f648b8955d
dav1d|https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2|2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011
"

step() { printf '\n==> %s\n' "$1"; }

fetch() {
  name=$1 url=$2 sum=$3
  archive="$WORK/dl/$(basename "$url")"
  mkdir -p "$WORK/dl"
  [ -f "$archive" ] || curl -fL --retry 3 -o "$archive" "$url"
  actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
  if [ "$actual" != "$sum" ]; then
    echo "Wrong SHA-256 for $name: $actual" >&2
    rm -f "$archive"
    exit 1
  fi
  rm -rf "$SRC/$name" && mkdir -p "$SRC/$name"
  tar -xf "$archive" -C "$SRC/$name" --strip-components 1
}

rm -rf "$PREFIX" && mkdir -p "$SRC" "$PREFIX"
echo "$SOURCES" | while IFS='|' read -r name url sum; do
  [ -n "$name" ] || continue
  step "source $name"
  fetch "$name" "$url" "$sum"
done

step "libwebp (BSD)"
cmake -S "$SRC/libwebp" -B "$SRC/libwebp/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
  -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
  -DWEBP_BUILD_EXTRAS=OFF
cmake --build "$SRC/libwebp/build" && cmake --install "$SRC/libwebp/build"

step "lame (LGPL)"
(cd "$SRC/lame" && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend \
  --disable-decoder --host=aarch64-apple-darwin && make -j"$JOBS" && make install)

step "opus (BSD)"
(cd "$SRC/opus" && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-doc \
  --disable-extra-programs --host=aarch64-apple-darwin && make -j"$JOBS" && make install)

step "libvpx (BSD)"
(cd "$SRC/libvpx" && ./configure --prefix="$PREFIX" --target=arm64-darwin23-gcc --disable-shared --enable-static \
  --enable-pic --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth \
  && make -j"$JOBS" && make install)

step "SVT-AV1 (BSD)"
cmake -S "$SRC/svtav1" -B "$SRC/svtav1/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF \
  -DBUILD_TESTING=OFF
cmake --build "$SRC/svtav1/build" && cmake --install "$SRC/svtav1/build"

step "dav1d (BSD)"
meson setup "$SRC/dav1d/build" "$SRC/dav1d" --prefix="$PREFIX" --libdir=lib --buildtype=release \
  --default-library=static -Denable_tools=false -Denable_tests=false
ninja -C "$SRC/dav1d/build" install

step "ffmpeg $FFMPEG_VERSION (LGPL)"
(cd "$SRC/ffmpeg" && ./configure --prefix="$PREFIX" --arch=arm64 --cc=clang \
  --extra-cflags="$CFLAGS -I$PREFIX/include" --extra-ldflags="$LDFLAGS -L$PREFIX/lib" \
  --pkg-config-flags=--static --disable-shared --enable-static \
  --disable-autodetect --disable-network --disable-indevs --disable-outdevs --disable-ffplay --disable-ffprobe \
  --disable-doc --disable-debug \
  --enable-zlib --enable-bzlib --enable-videotoolbox --enable-audiotoolbox \
  --enable-libwebp --enable-libmp3lame --enable-libopus --enable-libvpx --enable-libsvtav1 --enable-libdav1d \
  && make -j"$JOBS")

step "verify"
BIN="$SRC/ffmpeg/ffmpeg"
"$BIN" -hide_banner -L | grep -q "GNU Lesser General Public" || { echo "ffmpeg is not LGPL" >&2; exit 1; }
if "$BIN" -hide_banner -buildconf | grep -E -q -- "--enable-(gpl|nonfree)"; then
  echo "GPL or nonfree configuration" >&2
  exit 1
fi
if otool -L "$BIN" | tail -n +2 | grep -v -E "^\s+/(usr/lib|System/Library)/" | grep -q .; then
  echo "dynamic dependencies outside the system:" >&2
  otool -L "$BIN" >&2
  exit 1
fi

rm -rf "$OUT" && mkdir -p "$OUT/licenses"
cp "$BIN" "$OUT/ffmpeg"
# Licenses to ship with the executable (LGPL: text and source offer).
cp "$SRC/ffmpeg/COPYING.LGPLv2.1" "$OUT/licenses/ffmpeg-LGPL-2.1.txt"
cp "$SRC/ffmpeg/LICENSE.md" "$OUT/licenses/ffmpeg-LICENSE.md"
cp "$SRC/lame/COPYING" "$OUT/licenses/lame-LGPL.txt"
cp "$SRC/libwebp/COPYING" "$OUT/licenses/libwebp-BSD.txt"
cp "$SRC/opus/COPYING" "$OUT/licenses/opus-BSD.txt"
cp "$SRC/libvpx/LICENSE" "$OUT/licenses/libvpx-BSD.txt"
cp "$SRC/svtav1/LICENSE.md" "$OUT/licenses/svt-av1-BSD.md"
cp "$SRC/dav1d/COPYING" "$OUT/licenses/dav1d-BSD.txt"
"$BIN" -hide_banner -buildconf > "$OUT/BUILDCONF.txt"
echo "$SOURCES" > "$OUT/SOURCES.txt"
printf '\nLGPL ffmpeg ready: %s (%s)\n' "$OUT/ffmpeg" "$(du -h "$OUT/ffmpeg" | cut -f1)"
