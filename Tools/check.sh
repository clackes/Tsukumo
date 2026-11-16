#!/bin/sh
# SPDX-FileCopyrightText: 2026 Tsukumo contributors
# SPDX-License-Identifier: GPL-3.0-only
#
# Deterministic Phase 0a checks: lint, licenses, tests, app build,
# manifest (§3.8) and Mach-O analysis of zero cost (§4.2).
# Usage: Tools/check.sh            (stable local signing; ad-hoc signing in CI)
set -eu

cd "$(dirname "$0")/.."
# Build products live outside the repo: in a synced folder
# (Documents/iCloud) extended attributes make codesign fail.
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Caches/tsukumo/DerivedData}"
PACKAGES="Packages/Core Packages/DesignSystem Packages/Bridges Packages/Modules/Monitor Packages/Modules/MenuBar Packages/Modules/Snap Packages/Modules/Clack Packages/Modules/Island Packages/Modules/Convert Packages/Modules/Duo Packages/Modules/Switcher Packages/Modules/Sound"

step() { printf '\n==> %s\n' "$1"; }

step "swift-format lint"
xcrun swift-format lint --strict --recursive App/Sources Packages

step "SwiftLint"
swiftlint lint --strict --quiet

step "REUSE"
reuse lint --quiet

for package in $PACKAGES; do
  step "swift test: $package"
  swift test --package-path "$package" --quiet
done

step "XcodeGen"
(cd App && xcodegen generate --quiet)

step "xcodebuild"
if [ "${CI:-false}" = "true" ]; then
  # Runners do not have the maintainer's local certificate: ad-hoc signing in CI.
  xcodebuild -project App/Tsukumo.xcodeproj -scheme Tsukumo -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual -quiet build
else
  xcodebuild -project App/Tsukumo.xcodeproj -scheme Tsukumo -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" -quiet build
fi

APP="$DERIVED_DATA/Build/Products/Debug/Tsukumo.app"

step "manifest-check"
Tools/manifest-check/manifest-check "$APP"

step "zero-cost: Mach-O analysis"
Tools/zero-cost/macho-check "$APP"

printf '\nAll green. App: %s\n' "$APP"
