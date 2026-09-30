#!/usr/bin/env bash
# Copy a built Disk Monitor.app into the test VM and re-sign it there with the VM-only
# "Disk Monitor Dev" identity. Keeps the production name and bundle id; in the VM there is
# no real app whose permission row it could share.
# Usage: install-app.sh <vm> <path/to/Disk Monitor.app>
set -euo pipefail
VM="$1"; APP="$2"; TART="${TART:-$HOME/.local/bin/tart}"
DEST=/Users/admin/Applications
"$TART" exec "$VM" /bin/mkdir -p "$DEST"
# Move any previous copy aside (the VM clone is disposable) instead of deleting it.
"$TART" exec "$VM" /bin/sh -c "test ! -e '$DEST/Disk Monitor.app' || /bin/mv '$DEST/Disk Monitor.app' \"\$TMPDIR/old-app-\$(date +%s)\""
tar -C "$(dirname "$APP")" -cf - "$(basename "$APP")" | "$TART" exec -i "$VM" /usr/bin/tar -xf - -C "$DEST"
"$TART" exec -i "$VM" /bin/bash -s <<G
set -eu
K=\$HOME/Library/Keychains/login.keychain-db
security unlock-keychain -p admin "\$K"
ID=\$(security find-identity -p codesigning "\$K" | awk '/"Disk Monitor Dev"/ {print \$2; exit}')
test -n "\$ID" || { echo "no Disk Monitor Dev identity; run guest-signing-cert.sh"; exit 3; }
APP="$DEST/Disk Monitor.app"
/usr/bin/codesign --force --deep --timestamp=none --sign "\$ID" "\$APP"
/usr/bin/codesign --verify --deep --strict "\$APP"
/usr/bin/codesign -d -r- "\$APP" 2>&1 | grep designated
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "\$APP/Contents/Info.plist"
G
