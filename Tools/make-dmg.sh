#!/bin/sh
# SPDX-FileCopyrightText: 2026 Tsukumo contributors
# SPDX-License-Identifier: GPL-3.0-only
#
# Creates the installer DMG: window with background, the app on the left, the
# Applications folder on the right and the arrow in between.
#
# Usage: Tools/make-dmg.sh [Tsukumo.app] [output.dmg]
#   Without arguments it builds the Release configuration and writes
#   build/Tsukumo-<version>.dmg.
#
# The window layout is set by the Finder via AppleScript: the first
# time macOS asks to allow the terminal to control the Finder. If it is
# denied (or in CI, with no graphical session) the DMG is still created, just without
# background and positions.
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Caches/tsukumo/DerivedData}"
VOLUME="Tsukumo"

APP="${1:-}"
if [ -z "$APP" ]; then
  (cd App && xcodegen generate --quiet)
  xcodebuild -project App/Tsukumo.xcodeproj -scheme Tsukumo -configuration Release \
    -derivedDataPath "$DERIVED_DATA" -quiet build
  APP="$DERIVED_DATA/Build/Products/Release/Tsukumo.app"
fi
[ -d "$APP" ] || { echo "App not found: $APP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="${2:-$ROOT/build/Tsukumo-$VERSION.dmg}"
mkdir -p "$(dirname "$OUT")"

# All the work in a temporary folder outside the repo: in a synced
# folder extended attributes break the signature of the copied app.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tsukumo-dmg.XXXXXX")"
MOUNT="$WORK/mount"
cleanup() {
  [ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background" "$MOUNT"
ditto "$APP" "$STAGE/Tsukumo.app"
ln -s /Applications "$STAGE/Applications"
swift Tools/dmg/make-background.swift "$WORK/bg" 2>/dev/null
tiffutil -cathidpicheck "$WORK/bg/background.png" "$WORK/bg/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
cp App/Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MOUNT" -quiet

# Volume icon (SetFile is part of the Xcode command line tools).
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$MOUNT" || true; fi

# Measures shared with Tools/dmg/make-background.swift.
layout() {
  osascript <<APPLESCRIPT
tell application "Finder"
  set dmg to (POSIX file "$MOUNT" as alias)
  open dmg
  set win to container window of dmg
  set current view of win to icon view
  set toolbar visible of win to false
  set statusbar visible of win to false
  set bounds of win to {200, 120, 860, 568}
  set opts to icon view options of win
  set arrangement of opts to not arranged
  set icon size of opts to 128
  set text size of opts to 13
  set shows item info of opts to false
  set shows icon preview of opts to false
  set background picture of opts to (POSIX file "$MOUNT/.background/background.tiff" as alias)
  set position of item "Tsukumo.app" of dmg to {175, 200}
  set position of item "Applications" of dmg to {485, 200}
  -- Anyone who shows hidden files in Finder would see them scattered over the
  -- background (and they would shift the view origin): they are placed below, out of sight.
  try
    set position of item ".background" of dmg to {175, 760}
  end try
  try
    set position of item ".VolumeIcon.icns" of dmg to {330, 760}
  end try
  try
    set position of item ".fseventsd" of dmg to {485, 760}
  end try
  update dmg without registering applications
  delay 1
  close win
end tell
APPLESCRIPT
}
if layout >/dev/null 2>"$WORK/layout.log"; then
  LAYOUT=ok
else
  LAYOUT=missing
  echo "Warning: Finder did not set up the window ($(tr '\n' ' ' <"$WORK/layout.log"))." >&2
  echo "The DMG works, but without background and positions. Allow the terminal to control Finder and try again." >&2
fi

sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$OUT"

# Sign the DMG only if an identity is given (Developer ID on release).
if [ -n "${DMG_SIGN_IDENTITY:-}" ]; then
  codesign --sign "$DMG_SIGN_IDENTITY" --timestamp "$OUT"
fi

printf 'DMG ready (%s): %s\n' "$LAYOUT" "$OUT"
