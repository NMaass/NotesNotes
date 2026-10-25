#!/usr/bin/env bash
# Runs ResonoteKit's Swift Testing suite on macOS. With full Xcode installed,
# plain `swift test` works; with only the Command Line Tools, Swift Testing lives
# outside the default search paths, so point the compiler and linker at it.
set -euo pipefail
cd "$(dirname "$0")/../Packages/ResonoteKit"

if xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
  DEV=/Library/Developer/CommandLineTools/Library/Developer
  exec swift test \
    -Xswiftc -F"$DEV/Frameworks" \
    -Xlinker -F"$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
    "$@"
fi
exec swift test "$@"
