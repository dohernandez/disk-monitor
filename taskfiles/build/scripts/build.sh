#!/usr/bin/env bash
# Build Disk Monitor.app (task build:app).
#
# Usage: bash taskfiles/build/scripts/build.sh [--test] [--build-dir DIR] [--expect-arch arm64|x86_64]
#   --test         Compile the native test launch modes (tests/TestModes.swift) into
#                  build/test; release builds never contain them. Same as TEST_BUILD=1.
#   --build-dir    Output folder (default build, or build/test with --test). Same as BUILD_DIR.
#                  Relative paths resolve from the repository root.
#   --expect-arch  Fail unless this Mac's architecture matches (CI matrix guard).
# Env: APP_VERSION (default VERSION), APP_BUILD (default 1), BUILD_DIR, TEST_BUILD,
#      SCANNER_SIGNING_SHA1 (signed scanner release only; set by task build:scanner-release).
set -eu
cd "$(dirname "$0")/../../.."
test_build="${TEST_BUILD:-0}"
build_dir="${BUILD_DIR:-}"
expect_arch=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --test) test_build=1 ;;
    --build-dir) [ "$#" -ge 2 ] || { echo "--build-dir needs a folder" >&2; exit 2; }; build_dir="$2"; shift ;;
    --expect-arch) [ "$#" -ge 2 ] || { echo "--expect-arch needs arm64 or x86_64" >&2; exit 2; }; expect_arch="$2"; shift ;;
    -h|--help) sed -n '2,11p' taskfiles/build/scripts/build.sh; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
case "$test_build" in
  0) build_dir="${build_dir:-$PWD/build}"; set -- ;;
  1) build_dir="${build_dir:-$PWD/build/test}"; set -- -D DISK_MONITOR_TESTS tests/TestModes.swift ;;
  *) echo "TEST_BUILD must be 0 or 1" >&2; exit 1 ;;
esac
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
app="$build_dir/Disk Monitor.app"
version="${APP_VERSION:-$(cat VERSION)}"
architecture="$(uname -m)"
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
if [ -n "$expect_arch" ] && [ "$expect_arch" != "$architecture" ]; then echo "Expected $expect_arch, running on $architecture" >&2; exit 1; fi
if [ -e "$app/Contents/Library/Scanner" ]; then
    echo "Obsolete nested scanner layout; use a fresh BUILD_DIR." >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS"
python3 taskfiles/build/scripts/bundle_info.py "$app" "$version" "${APP_BUILD:-1}"
python3 - "$build_dir" <<'PYBUILD'
import json,sys
from pathlib import Path
root = Path(sys.argv[1])
(root / 'empty.modulemap').write_text('// Project-local compatibility overlay.\n')
legacy = Path('/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap')
new = legacy.with_name('bridging.modulemap')
roots = [{'type': 'file', 'name': str(legacy), 'external-contents': str(root / 'empty.modulemap')}] if legacy.exists() and new.exists() else []
(root / 'toolchain-overlay.json').write_text(json.dumps({'version': 0, 'roots': roots}))
PYBUILD
python3 taskfiles/build/scripts/sparkle.py "$build_dir"
xcrun swiftc -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" taskfiles/build/scripts/key_public.swift -o "$build_dir/sparkle/key_public"
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$build_dir/sparkle/LICENSE" "$app/Contents/Resources/SPARKLE-LICENSE"
/usr/bin/ditto "$build_dir/sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
python3 taskfiles/build/scripts/scanner_identity.py "$build_dir"
xcrun swiftc -D DISK_MONITOR -target "$architecture-apple-macos15.0" -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" -module-cache-path "$build_dir/module-cache" -swift-version 5 -O main.swift Updates.swift FolderAccess.swift PrivilegedFolderReader.swift HelperPrototype/BridgeProtocol.swift HelperPrototype/Shared.swift HelperPrototype/RequestState.swift HelperPrototype/RecoveryState.swift HelperPrototype/BundlePolicy.swift "$build_dir/ScannerIdentity.swift" "$@" -F "$build_dir/sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$app/Contents/MacOS/DiskMonitor" -framework Cocoa -framework SwiftUI

if [ -n "${SCANNER_SIGNING_SHA1:-}" ]; then
    host="$app"
    mkdir -p "$host/Contents/MacOS"
    xcrun swiftc -D DISK_MONITOR -target "$architecture-apple-macos15.0" -parse-as-library -swift-version 5 -O -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" -module-cache-path "$build_dir/module-cache" HelperPrototype/Shared.swift HelperPrototype/Measurement.swift HelperPrototype/Helper.swift "$build_dir/ScannerIdentity.swift" -o "$host/Contents/MacOS/Scanner"
    xcrun swiftc -D DISK_MONITOR -target "$architecture-apple-macos15.0" -parse-as-library -swift-version 5 -O -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" -module-cache-path "$build_dir/module-cache" HelperPrototype/Shared.swift HelperPrototype/BridgeProtocol.swift HelperPrototype/Bridge.swift "$build_dir/ScannerIdentity.swift" -framework ServiceManagement -o "$host/Contents/MacOS/ScannerBridge"
    codesign --force --options runtime --timestamp=none --sign "$SCANNER_SIGNING_SHA1" --identifier local.darien.diskmonitor.scanner.service "$host/Contents/MacOS/Scanner"
    codesign --force --options runtime --timestamp=none --sign "$SCANNER_SIGNING_SHA1" --identifier local.darien.diskmonitor.scanner.client "$host/Contents/MacOS/ScannerBridge"
    python3 taskfiles/build/scripts/scanner_constraint.py "$app"
else
    if [ -e "$app/Contents/MacOS/Scanner" ] || [ -e "$app/Contents/MacOS/ScannerBridge" ]; then
        echo "Refusing an unsigned build over a scanner-enabled bundle. Use a fresh BUILD_DIR." >&2
        exit 1
    fi
fi
codesign --force --timestamp=none --sign "${SCANNER_SIGNING_SHA1:--}" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
