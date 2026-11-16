#!/bin/sh
# SPDX-FileCopyrightText: 2026 Tsukumo contributors
# SPDX-License-Identifier: GPL-3.0-only
#
# Build phase of Converter.xpc: copies LGPL ffmpeg (Tools/ffmpeg/build.sh) into the
# helper's resources, signed once with the hardened runtime. Without ffmpeg in the cache the
# build goes on: tier 1 simply ends up unavailable.
set -eu
SOURCE="${TSUKUMO_FFMPEG_CACHE:-$HOME/Library/Caches/tsukumo}/ffmpeg"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
if [ ! -x "$SOURCE/ffmpeg" ]; then
  echo "warning: ffmpeg not found in $SOURCE: run Tools/ffmpeg/build.sh for Convert tier 1"
  rm -f "$DEST/ffmpeg"
  exit 0
fi
mkdir -p "$DEST"
# The phase runs on every build, but Xcode does not always redo the helper's
# seal (incremental builds, `clean` that does not remove the product). Every codesign
# produces different bytes: re-signing ffmpeg here would invalidate the seal of
# Converter.xpc. So it is signed only once, in a cache outside the build,
# tied to the source binary and the identity, and the same copy is always copied.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-unsigned}"
SIGNED_DIR="$SOURCE/signed/$IDENTITY"
WANT="$(shasum -a 256 "$SOURCE/ffmpeg" | cut -d' ' -f1)"
if [ ! -x "$SIGNED_DIR/ffmpeg" ] || [ "$(cat "$SIGNED_DIR/source.sha256" 2>/dev/null)" != "$WANT" ]; then
  mkdir -p "$SIGNED_DIR"
  cp "$SOURCE/ffmpeg" "$SIGNED_DIR/ffmpeg.tmp"
  if [ "$IDENTITY" != unsigned ]; then
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$SIGNED_DIR/ffmpeg.tmp"
  fi
  mv "$SIGNED_DIR/ffmpeg.tmp" "$SIGNED_DIR/ffmpeg"
  printf '%s' "$WANT" >"$SIGNED_DIR/source.sha256"
fi
cmp -s "$SIGNED_DIR/ffmpeg" "$DEST/ffmpeg" || cp "$SIGNED_DIR/ffmpeg" "$DEST/ffmpeg"
cp "$SOURCE/BUILDCONF.txt" "$SOURCE/SOURCES.txt" "$DEST/" 2>/dev/null || true
rm -rf "$DEST/ffmpeg-licenses"
cp -R "$SOURCE/licenses" "$DEST/ffmpeg-licenses" 2>/dev/null || true
