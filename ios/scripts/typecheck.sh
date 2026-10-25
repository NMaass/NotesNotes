#!/usr/bin/env bash
# Typechecks every iOS target without Xcode or a simulator.
#
# The macOS SDK ships the Mac Catalyst (iOSSupport) builds of UIKit, SwiftUI,
# WidgetKit, AppIntents, MediaPlayer, ShazamKit, and MusicKit, so compiling for
# `arm64-apple-ios26.0-macabi` catches nearly every error an iOS build would.
# APIs marked unavailable on Mac Catalyst are the exception: guard those with
# `#if !targetEnvironment(macCatalyst)` only when an error proves it is needed.
#
# Usage: ios/scripts/typecheck.sh [kit|app|widgets|share|all]   (default: all)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_SELECTION="${1:-all}"

if [[ -n "${SDK_PATH:-}" ]]; then
  SDK="$SDK_PATH"
elif xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
else
  SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
fi
TRIPLE="arm64-apple-ios26.0-macabi"
BUILD="${TMPDIR:-/tmp}/resonote-typecheck"
mkdir -p "$BUILD"

COMMON=(
  -target "$TRIPLE"
  -sdk "$SDK"
  -F "$SDK/System/iOSSupport/System/Library/Frameworks"
  -I "$SDK/System/iOSSupport/usr/lib/swift"
  -swift-version 6
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature InferIsolatedConformances
)

swift_files() {
  local dir
  for dir in "$@"; do
    if [[ -d "$dir" ]]; then find "$dir" -name '*.swift' -not -path '*/Tests/*' -print0; fi
  done | xargs -0 -n1 echo | sort
}

build_kit() {
  echo "▸ ResonoteKit"
  local files
  files=$(swift_files "$ROOT/Packages/ResonoteKit/Sources")
  # shellcheck disable=SC2086
  swiftc "${COMMON[@]}" -parse-as-library -module-name ResonoteKit \
    -emit-module -emit-module-path "$BUILD/ResonoteKit.swiftmodule" \
    -o "$BUILD/ResonoteKit.o" -c -wmo $files
}

check_target() {
  local name="$1"; shift
  local files
  files=$(swift_files "$@" "$ROOT/Shared")
  if [[ -z "$files" ]]; then
    echo "▸ $name (no sources yet)"
    return
  fi
  echo "▸ $name"
  local extension_flag="-DRESONOTE_APP"
  if [[ "$name" != "Resonote" ]]; then extension_flag="-application-extension"; fi
  # shellcheck disable=SC2086
  swiftc "${COMMON[@]}" "$extension_flag" -typecheck -parse-as-library -module-name "$name" \
    -default-isolation MainActor -I "$BUILD" $files
}

case "$TARGET_SELECTION" in
  kit) build_kit ;;
  app) build_kit; check_target Resonote "$ROOT/Resonote" "$ROOT/SharedIntents" ;;
  widgets) build_kit; check_target ResonoteWidgets "$ROOT/ResonoteWidgets" "$ROOT/SharedIntents" ;;
  share) build_kit; check_target ResonoteShare "$ROOT/ResonoteShare" ;;
  all)
    build_kit
    check_target Resonote "$ROOT/Resonote" "$ROOT/SharedIntents"
    check_target ResonoteWidgets "$ROOT/ResonoteWidgets" "$ROOT/SharedIntents"
    check_target ResonoteShare "$ROOT/ResonoteShare"
    ;;
  *) echo "unknown target: $TARGET_SELECTION" >&2; exit 2 ;;
esac
echo "✓ typecheck passed ($TARGET_SELECTION)"
