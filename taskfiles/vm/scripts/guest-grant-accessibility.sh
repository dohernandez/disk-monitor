#!/usr/bin/env bash
# Runs INSIDE the test VM, as root (the base image has SIP disabled): grant Accessibility to
# the installed Disk Monitor by writing the VM's system TCC database, as CI runners do.
# The requirement is the app's designated requirement (bundle id + "Disk Monitor Dev" leaf),
# so rebuilds signed with the same VM identity stay granted. Never run this on a real Mac.
# Usage: tart exec -i <vm> /usr/bin/sudo /bin/bash -s < guest-grant-accessibility.sh (golden.sh does this)
set -euo pipefail
APP="/Users/admin/Applications/Disk Monitor.app"
test "$(/usr/bin/csrutil status | grep -c disabled)" = 1 || { echo "SIP enabled: refusing"; exit 3; }
REQ=$(/usr/bin/codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
case "$REQ" in *'certificate leaf'*) ;; *) echo "not signed with a certificate: $REQ"; exit 3;; esac
BIN=$(mktemp); /usr/bin/csreq -r="$REQ" -b "$BIN"; HEX=$(/usr/bin/xxd -p "$BIN" | tr -d '\n'); rm -f "$BIN"
DB="/Library/Application Support/com.apple.TCC/TCC.db"
/usr/bin/sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('kTCCServiceAccessibility', 'local.darien.diskmonitor', 0, 2, 4, 1, X'$HEX', NULL, 0, 'UNUSED', NULL, 0, CAST(strftime('%s','now') AS INTEGER));"
/usr/bin/sqlite3 "$DB" "SELECT service, client, auth_value FROM access WHERE client = 'local.darien.diskmonitor';"
echo "requirement: $REQ"
