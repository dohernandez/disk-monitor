#!/bin/sh
set -eu
cd "$(dirname "$0")"
build_dir="${BUILD_DIR:-$PWD/build}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
app="$build_dir/Disk Monitor.app"
version="${APP_VERSION:-$(cat VERSION)}"
architecture="$(uname -m)"
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
if [ -e "$app/Contents/Library/Scanner" ]; then
    echo "Obsolete nested scanner layout; use a fresh BUILD_DIR." >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS"
python3 scripts/bundle_info.py "$app" "$version" "${APP_BUILD:-1}"
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
python3 scripts/sparkle.py "$build_dir"
xcrun swiftc -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" scripts/key_public.swift -o "$build_dir/sparkle/key_public"
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$build_dir/sparkle/LICENSE" "$app/Contents/Resources/SPARKLE-LICENSE"
/usr/bin/ditto "$build_dir/sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
python3 scripts/scanner_identity.py "$build_dir"
xcrun swiftc -D DISK_MONITOR -target "$architecture-apple-macos15.0" -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" -module-cache-path "$build_dir/module-cache" -swift-version 5 -O main.swift Updates.swift FolderAccess.swift PrivilegedFolderReader.swift HelperPrototype/BridgeProtocol.swift HelperPrototype/Shared.swift HelperPrototype/RequestState.swift HelperPrototype/RecoveryState.swift HelperPrototype/BundlePolicy.swift "$build_dir/ScannerIdentity.swift" -F "$build_dir/sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$app/Contents/MacOS/DiskMonitor" -framework Cocoa -framework SwiftUI

if [ -n "${SCANNER_SIGNING_SHA1:-}" ]; then
    host="$app"
    mkdir -p "$host/Contents/MacOS"
    xcrun swiftc -D DISK_MONITOR -target "$architecture-apple-macos15.0" -parse-as-library -swift-version 5 -O -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" -module-cache-path "$build_dir/module-cache" HelperPrototype/Shared.swift HelperPrototype/Measurement.swift HelperPrototype/Helper.swift "$build_dir/ScannerIdentity.swift" -o "$host/Contents/MacOS/Scanner"
    xcrun swiftc -D DISK_MONITOR -target "$architecture-apple-macos15.0" -parse-as-library -swift-version 5 -O -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" -module-cache-path "$build_dir/module-cache" HelperPrototype/Shared.swift HelperPrototype/BridgeProtocol.swift HelperPrototype/Bridge.swift "$build_dir/ScannerIdentity.swift" -framework ServiceManagement -o "$host/Contents/MacOS/ScannerBridge"
    codesign --force --options runtime --timestamp=none --sign "$SCANNER_SIGNING_SHA1" --identifier local.darien.diskmonitor.scanner.service "$host/Contents/MacOS/Scanner"
    codesign --force --options runtime --timestamp=none --sign "$SCANNER_SIGNING_SHA1" --identifier local.darien.diskmonitor.scanner.client "$host/Contents/MacOS/ScannerBridge"
else
    if [ -e "$app/Contents/MacOS/Scanner" ] || [ -e "$app/Contents/MacOS/ScannerBridge" ]; then
        echo "Refusing an unsigned build over a scanner-enabled bundle. Use a fresh BUILD_DIR." >&2
        exit 1
    fi
fi
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
